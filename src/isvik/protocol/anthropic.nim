## Anthropic Messages Adapter(§20.5.1 P0)
##
## ---
##
## ## 与 OpenAI Adapter 的三处结构性差异
##
## ```text
## system        顶层独立字段,不是一条 role=system 的消息
## max_tokens    **必填**,不是可选项
## 流式事件      有具名事件(message_start / content_block_delta / ...),
##               而 OpenAI 只有一种 chunk
## ```
##
## 这三点正是 §20.5.3 存在的理由:差异在 Adapter 边界上被消化,
## Core 只看到一种请求形式。
##
## ---
##
## ## 事件序列必须完整
##
## Anthropic 的客户端按状态机解析流:
##
## ```text
## message_start
##   content_block_start
##     content_block_delta ...
##   content_block_stop
## message_delta      (stop_reason 与 usage 在这里)
## message_stop
## ```
##
## 少发一个 `content_block_start`,官方 SDK 会直接抛错而不是容错 ——
## 因此 `InferenceStarted` 一次返回两个块,`InferenceCompleted` 一次返回三个。
## 这正是 `formatEvent` 返回 `seq` 而不是单个块的原因。
##
## ---
##
## ## 声明的能力就是真正实现的能力
##
## 与 OpenAI Adapter 同理:不声明 tools 与 structured output。

import std/[json, options, strutils, times]

import isvik/core/errors
import isvik/core/tools
import isvik/core/inference
import isvik/core/inference_events
import isvik/core/protocol
import isvik/protocol/json_read

const
  AnthropicProtocolName* = "anthropic"
  AnthropicApiVersion* = "/v1"
  AnthropicMessageIdPrefix* = "msg_"
  AnthropicOverloadedStatus* = 529
    ## Anthropic 特有:服务过载。规范的默认映射没有这一档。

type
  AnthropicAdapter* = ref object of ProtocolAdapter

proc newAnthropicAdapter*(): AnthropicAdapter =
  new(result)

method protocolName*(a: AnthropicAdapter): string = AnthropicProtocolName

method apiVersion*(a: AnthropicAdapter): string = AnthropicApiVersion

method capabilities*(a: AnthropicAdapter): set[ProtocolCapability] =
  ## 含 `pcReasoning`:本协议有 thinking 块与 thinking_delta,推理内容能
  ## **双向**如实表达 —— 请求里能带,响应里能单独输出。
  ##
  ## 这与 OpenAI Chat Adapter 的取舍不同:那边没有对应字段,推理内容只能
  ## 丢弃,因此不声明该能力。
  ##
  ## 含 `pcToolCalling`:解码层已通过提示词方案接入
  ## (见 `inference/tool_calling`)。仍不含 `pcStructuredOutput`。
  {pcStreaming, pcMultiTurn, pcCancellation, pcReasoning, pcToolCalling}

# ---------------------------------------------------------------------------
# 请求:Anthropic → Unified
# ---------------------------------------------------------------------------

proc parseRole(value, field: string): MessageRole =
  ## Anthropic 的 messages 只允许 user 与 assistant。
  ##
  ## system 不在这里 —— 它是顶层字段。若客户端把 system 塞进 messages,
  ## 报错而不是接受:接受会让「system 该放哪」出现两种写法,
  ## 而其中一种在官方 API 上是无效的。
  case value
  of "user": mrUser
  of "assistant": mrAssistant
  else:
    raiseIsvikError(
      ecInvalidParameter,
      "Anthropic messages only allow the user and assistant roles;" &
        " system is a top-level field",
      "field=" & field & " got=" & value
    )

proc parseContent(node: JsonNode, field: string): seq[ContentPart] =
  ## content 可以是字符串,也可以是块数组。
  result = @[]
  if node == nil or node.kind == JNull:
    return
  if node.kind == JString:
    result.add(textPart(node.getStr))
    return
  if node.kind != JArray:
    rejectType(field, "string or array", node.kind)
  for i in 0 ..< node.len:
    let item = node[i]
    let itemField = field & "[" & $i & "]"
    if item.kind != JObject:
      rejectType(itemField, "object", item.kind)
    let kind = readStr(item, "type", itemField & ".type", "text")
    case kind
    of "text":
      result.add(textPart(readStr(item, "text", itemField & ".text", "")))
    of "thinking":
      # 客户端回传上一轮的思考内容。它属于 reasoning,不能混进正文。
      result.add(reasoningPart(
        readStr(item, "thinking", itemField & ".thinking", "")))
    of "tool_use":
      # 客户端回传上一轮 assistant 发起的调用。参数在 Anthropic 里是
      # **对象**(OpenAI 是字符串),两者的差异在这里被消化。
      let arguments =
        if item.hasKey("input"): item["input"] else: newJObject()
      if arguments.kind != JObject:
        rejectType(itemField & ".input", "object", arguments.kind)
      result.add(toolUsePart(initToolCall(
        readRequiredStr(item, "id", itemField & ".id"),
        readRequiredStr(item, "name", itemField & ".name"),
        $arguments, arguments)))
    of "tool_result":
      result.add(toolResultPart(initToolResult(
        readRequiredStr(item, "tool_use_id", itemField & ".tool_use_id"),
        # content 可以是字符串或块数组;取其文本即可,工具结果不需要结构。
        (if item.hasKey("content") and item["content"].kind == JString:
           item["content"].getStr
         elif item.hasKey("content"):
           $item["content"]
         else: ""),
        readBoolField(item, "is_error", itemField & ".is_error", false))))
    else:
      raiseIsvikError(
        ecNotImplemented,
        "Only text, thinking, tool_use and tool_result blocks are supported",
        "field=" & itemField & " type=" & kind
      )

proc parseSystem(body: JsonNode): string =
  ## 顶层 system 可以是字符串或文本块数组。
  result = ""
  if not body.hasKey("system") or body["system"].kind == JNull:
    return
  let node = body["system"]
  if node.kind == JString:
    return node.getStr
  if node.kind != JArray:
    rejectType("system", "string or array", node.kind)
  var parts: seq[string] = @[]
  for i in 0 ..< node.len:
    let item = node[i]
    let field = "system[" & $i & "]"
    if item.kind != JObject:
      rejectType(field, "object", item.kind)
    parts.add(readStr(item, "text", field & ".text", ""))
  result = parts.join("")

proc parseTools(body: JsonNode): seq[ToolDefinition] =
  ## Anthropic 的工具是**扁平**的:name / description / input_schema 直接在
  ## 对象上,没有 OpenAI 那层 `function` 包装。
  result = @[]
  let tools = readArr(body, "tools", "tools")
  if tools == nil:
    return
  for i in 0 ..< tools.len:
    let item = tools[i]
    let field = "tools[" & $i & "]"
    if item.kind != JObject:
      rejectType(field, "object", item.kind)
    result.add(initToolDefinition(
      readRequiredStr(item, "name", field & ".name"),
      readStr(item, "description", field & ".description", ""),
      readObj(item, "input_schema", field & ".input_schema")
    ))

proc parseToolChoice(body: JsonNode): ToolChoice =
  ## Anthropic 的 `tool_choice` 始终是对象:`{"type": "auto|any|tool|none"}`。
  ##
  ## 注意 `any` 对应统一模型的 `required`,`tool` 对应 `specific` ——
  ## 命名不同但语义一一对应,差异在这里消化。
  if not body.hasKey("tool_choice") or body["tool_choice"].kind == JNull:
    return autoToolChoice()
  let node = body["tool_choice"]
  if node.kind != JObject:
    rejectType("tool_choice", "object", node.kind)
  let kind = readRequiredStr(node, "type", "tool_choice.type")
  case kind
  of "auto": autoToolChoice()
  of "none": noToolChoice()
  of "any": requiredToolChoice()
  of "tool":
    specificToolChoice(readRequiredStr(node, "name", "tool_choice.name"))
  else:
    raiseIsvikError(
      ecInvalidParameter,
      "Unknown tool_choice type",
      "field=tool_choice.type got=" & kind & " allowed=auto,any,tool,none"
    )

method parseRequest*(a: AnthropicAdapter,
                     body: JsonNode): UnifiedInferenceRequest =
  requireObject(body, "Anthropic messages request")

  result = initUnifiedInferenceRequest(
    readRequiredStr(body, "model", "model"))
  result.stream = readBoolField(body, "stream", "stream", false)

  # system 是顶层字段,转成统一模型里的第一条 system 消息。
  let system = parseSystem(body)
  if system.strip().len > 0:
    result.messages.add(textMessage(mrSystem, system))

  let messages = readArr(body, "messages", "messages")
  if messages == nil or messages.len == 0:
    raiseIsvikError(
      ecInvalidRequest,
      "Request must provide at least one message",
      "field=messages"
    )
  for i in 0 ..< messages.len:
    let node = messages[i]
    let field = "messages[" & $i & "]"
    if node.kind != JObject:
      rejectType(field, "object", node.kind)
    let role = parseRole(
      readRequiredStr(node, "role", field & ".role"), field & ".role")
    var content: seq[ContentPart] = @[]
    if node.hasKey("content"):
      content = parseContent(node["content"], field & ".content")
    if content.len == 0:
      raiseIsvikError(
        ecInvalidRequest,
        "Message content must not be empty",
        "field=" & field & ".content"
      )
    result.messages.add(initMessage(role, content))

  # max_tokens 在 Anthropic 是**必填**。缺失时报错而不是替客户端选一个 ——
  # 选错会让回答被截断,而客户端以为模型就是那么答的。
  let maxTokens = readOptInt(body, "max_tokens", "max_tokens")
  if maxTokens.isNone:
    raiseIsvikError(
      ecInvalidRequest,
      "Field max_tokens is required by the Anthropic messages API",
      "field=max_tokens"
    )
  result.parameters.maxTokens = maxTokens

  result.parameters.temperature = readOptFloat(body, "temperature",
                                               "temperature")
  result.parameters.topP = readOptFloat(body, "top_p", "top_p")
  result.parameters.topK = readOptInt(body, "top_k", "top_k")
  result.parameters.stopSequences = readStrSeq(body, "stop_sequences",
                                               "stop_sequences")
  # Anthropic 没有 seed,也没有 presence/frequency penalty,更没有设备字段。
  # device 保持为空并由服务端继承 settings.default_device；不发明非标准字段。

  result.tools = parseTools(body)
  result.toolChoice = parseToolChoice(body)

  result.requireValid()
  a.requireSupportedRequest(result)

# ---------------------------------------------------------------------------
# 响应:Unified → Anthropic
# ---------------------------------------------------------------------------

proc stopReasonJson*(reason: StopReason): JsonNode =
  ## 终止原因 → Anthropic 的 `stop_reason`。
  ##
  ## `cancelled` / `error` / `unspecified` 映射为 **null**:官方用 null 表示
  ## 「尚未结束」,而这三种情况恰恰是没有正常结束。凑成 `end_turn` 会让
  ## 被中断的半截回答看起来是完整的。
  case reason
  of srEndTurn: %"end_turn"
  of srMaxTokens: %"max_tokens"
  of srStopSequence: %"stop_sequence"
  of srToolUse: %"tool_use"
  of srCancelled, srError, srUnspecified: newJNull()

proc usageJson*(usage: Usage): JsonNode =
  ## Anthropic 只报输入与输出,没有 total —— 与统一模型一致。
  %*{
    "input_tokens": usage.inputTokens,
    "output_tokens": usage.outputTokens
  }

proc generatedId*(): string =
  AnthropicMessageIdPrefix & $int64(epochTime() * 1_000_000.0)

method formatResult*(a: AnthropicAdapter,
                     res: UnifiedInferenceResult): JsonNode =
  var blocks = newJArray()
  let text = res.content.plainText()
  if text.len > 0:
    blocks.add(%*{"type": "text", "text": text})
  for part in res.content:
    if part.kind != cpkToolUse:
      continue
    let call = part.toolCall
    blocks.add(%*{
      "type": "tool_use",
      "id": call.id,
      "name": call.name,
      # `input` 是**对象**,不是字符串 —— 与 OpenAI 的 arguments 相反。
      "input": call.argumentsObject()
    })

  result = %*{
    "id": generatedId(),
    "type": "message",
    "role": "assistant",
    "model": res.model,
    "content": blocks,
    "stop_reason": stopReasonJson(res.stopReason),
    "stop_sequence": newJNull(),
    "usage": usageJson(res.usage)
  }
  if res.device.len > 0:
    # 实际设备不是官方字段,但隐瞒它等于让调用方无法知道推理跑在哪里(§27)。
    result["isvik"] = %*{"device": res.device}

method formatError*(a: AnthropicAdapter, code: IsvikErrorCode,
                    message: string): JsonNode =
  ## Anthropic 的错误形状:`{"type":"error","error":{...}}`。
  let status = a.httpStatusFor(code)
  let kind =
    case status
    of 400: "invalid_request_error"
    of 401: "authentication_error"
    of 404: "not_found_error"
    of 429: "rate_limit_error"
    of 501: "not_implemented_error"
    of 529: "overloaded_error"
    else:
      if status >= 500: "api_error" else: "invalid_request_error"
  result = %*{
    "type": "error",
    "error": {
      "type": kind,
      "message": message,
      "code": $code
    }
  }

method httpStatusFor*(a: AnthropicAdapter, code: IsvikErrorCode): int =
  ## 设备/Backend 不可用映射到 Anthropic 特有的 529 overloaded。
  ##
  ## 默认映射给的是 503。对 Anthropic 客户端而言 529 才是「稍后重试」的
  ## 标准信号,它们据此做退避;503 会被当成一般性故障。
  case code
  of ecDeviceNotAvailable, ecNpuNotAvailable, ecGpuNotAvailable,
     ecBackendNotAvailable: AnthropicOverloadedStatus
  else: defaultHttpStatusFor(code)

# ---------------------------------------------------------------------------
# 流式:具名事件
# ---------------------------------------------------------------------------

proc messageStartChunk(model: string): ProtocolStreamChunk =
  initChunk("message_start", %*{
    "type": "message_start",
    "message": {
      "id": generatedId(),
      "type": "message",
      "role": "assistant",
      "model": model,
      "content": newJArray(),
      "stop_reason": newJNull(),
      "stop_sequence": newJNull(),
      "usage": usageJson(Usage(inputTokens: 0, outputTokens: 0))
    }
  })

proc contentBlockStartChunk(): ProtocolStreamChunk =
  initChunk("content_block_start", %*{
    "type": "content_block_start",
    "index": 0,
    "content_block": {"type": "text", "text": ""}
  })

proc textDeltaChunk(text: string): ProtocolStreamChunk =
  initChunk("content_block_delta", %*{
    "type": "content_block_delta",
    "index": 0,
    "delta": {"type": "text_delta", "text": text}
  })

proc thinkingDeltaChunk(text: string): ProtocolStreamChunk =
  initChunk("content_block_delta", %*{
    "type": "content_block_delta",
    "index": 0,
    "delta": {"type": "thinking_delta", "thinking": text}
  })

proc contentBlockStopChunk(index: int = 0): ProtocolStreamChunk =
  initChunk("content_block_stop", %*{
    "type": "content_block_stop",
    "index": index
  })

proc messageDeltaChunk(reason: StopReason, usage: Usage):
    ProtocolStreamChunk =
  initChunk("message_delta", %*{
    "type": "message_delta",
    "delta": {
      "stop_reason": stopReasonJson(reason),
      "stop_sequence": newJNull()
    },
    "usage": usageJson(usage)
  })

proc messageStopChunk(): ProtocolStreamChunk =
  initChunk("message_stop", %*{"type": "message_stop"})

method formatEvent*(a: AnthropicAdapter,
                    e: InferenceEvent): seq[ProtocolStreamChunk] =
  case e.kind
  of iekInferenceStarted:
    # 官方 SDK 按状态机解析:缺少 content_block_start 会直接抛错。
    result = @[messageStartChunk(e.startedModel), contentBlockStartChunk()]
  of iekContentDelta:
    result = @[textDeltaChunk(e.textDelta)]
  of iekReasoningDelta:
    # Anthropic 有 thinking_delta,因此推理内容能如实单独输出,
    # 不必像 OpenAI Chat 那样丢弃。
    result = @[thinkingDeltaChunk(e.textDelta)]
  of iekToolCallStarted:
    # 工具调用是**另一个** content block:先关掉正在进行的文本块,
    # 再以 index 1 开一个 tool_use 块。少了 content_block_stop,
    # 官方 SDK 的状态机会认为文本块还没结束。
    result = @[
      contentBlockStopChunk(),
      initChunk("content_block_start", %*{
        "type": "content_block_start",
        "index": 1,
        "content_block": {
          "type": "tool_use",
          "id": e.toolCallId,
          "name": e.toolName,
          "input": newJObject()
        }
      })
    ]
  of iekToolCallDelta:
    # 参数以 input_json_delta 增量到达,载荷是**字符串片段**而不是对象。
    result = @[initChunk("content_block_delta", %*{
      "type": "content_block_delta",
      "index": 1,
      "delta": {"type": "input_json_delta", "partial_json": e.argumentsDelta}
    })]
  of iekUsageUpdated:
    # usage 随 message_delta 一起发,不单独发一个块 ——
    # 官方流里没有「只带 usage」的事件。
    result = noChunks()
  of iekInferenceCompleted:
    # tool_use 打开的是 block 1，不能再把 block 0 关闭第二次。最终结果持有
    # 已提取的工具调用，因此无须给无状态 Adapter 增加跨请求可变状态。
    let finalBlockIndex =
      if e.finalResult.content.toolCalls().len > 0: 1 else: 0
    result = @[
      contentBlockStopChunk(finalBlockIndex),
      messageDeltaChunk(e.finalResult.stopReason, e.finalResult.usage),
      messageStopChunk()
    ]
  of iekInferenceCancelled:
    # 取消也要把状态机收干净,否则客户端会一直等 message_stop。
    result = @[
      contentBlockStopChunk(),
      messageDeltaChunk(srCancelled, Usage(inputTokens: 0, outputTokens: 0)),
      messageStopChunk()
    ]
  of iekInferenceError:
    result = @[initChunk("error", a.formatError(e.errorCode, e.errorMessage)),
               messageStopChunk()]
