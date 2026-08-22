## OpenAI Chat Completions Adapter(§20.5.1 P0)
##
## ---
##
## ## 边界
##
## ```text
## 做:  /v1/chat/completions 的请求解析与响应构造
##      SSE 数据块的**内容**(不含 `data:` 前缀,那属于传输层)
##      finish_reason 与 usage 的如实映射
##
## 不做: 推理、模型编译、设备选择        §20.5.11
##       为了兼容而伪造字段              见下
## ```
##
## ---
##
## ## 声明的能力就是真正实现的能力
##
## `tools` 已接入解码(提示词方案,见 `inference/tool_calling`),因此声明
## `pcToolCalling`。`response_format` 尚未接入,因此**不声明**
## `pcStructuredOutput`。原因是 §20.5.13 第 12 条:声明了却不实现比不声明更糟 ——
## 客户端会按声明去用,然后得到静默错误的结果。
##
## 不声明的直接好处是 `requireSupportedRequest` 会在**入口**就返回
## NOT_IMPLEMENTED,而不是让请求跑到解码层才失败。
##
## **但「不声明」只有在字段被解析出来时才生效。** `requiredCapabilities` 是
## 从统一请求推导的,不看原始 JSON:`response_format` 若不被 `parseRequest`
## 读进 `responseFormat`,入口校验根本不知道客户端要结构化输出,请求会被当成
## 普通文本处理并返回 200。这个洞曾真实存在(真机实测 `response_format:
## {"type":"json_object"}` 返回 200 而不是 501),修法是照常解析、
## 靠能力声明拒绝。
##
## ---
##
## ## 流式块的身份字段由传输层补齐
##
## OpenAI 的每个 chunk 都带 `id` / `created` / `model`。但 `formatEvent` 只收到
## 一条事件,除 `InferenceStarted` 与 `InferenceCompleted` 外都不携带模型名,
## 更不可能知道本次请求的 id。
##
## 这里的取舍是**让 Adapter 保持无状态**:它不缓存「当前流是哪个请求」,
## 因此同一个实例可以安全地服务并发的多个流。缺失的身份字段由 HTTP 层用
## `withStreamIdentity` 一次性补齐 —— 那一层本来就持有请求上下文。
##
## 反面做法是让 Adapter 记住 streamModel/streamId:两个并发流会互相覆盖
## 对方的状态,而症状是「偶尔有个请求的 model 字段是别人的」。

import std/[json, options, tables, times]

import isvik/core/errors
import isvik/core/tools
import isvik/core/inference
import isvik/core/inference_events
import isvik/core/protocol
import isvik/protocol/json_read

const
  OpenAiChatProtocolName* = "openai-chat"
  OpenAiChatApiVersion* = "/v1"
  OpenAiChatObject* = "chat.completion"
  OpenAiChatChunkObject* = "chat.completion.chunk"
  OpenAiChatIdPrefix* = "chatcmpl-"

type
  OpenAiChatAdapter* = ref object of ProtocolAdapter

proc newOpenAiChatAdapter*(): OpenAiChatAdapter =
  new(result)

method protocolName*(a: OpenAiChatAdapter): string = OpenAiChatProtocolName

method apiVersion*(a: OpenAiChatAdapter): string = OpenAiChatApiVersion

method capabilities*(a: OpenAiChatAdapter): set[ProtocolCapability] =
  ## 只声明真正实现了的能力。
  ##
  ## `pcToolCalling` 已包含:解码层通过提示词方案接入了工具调用
  ## (见 `inference/tool_calling`)。`response_format` 仍未接入解码,
  ## 因此不声明 `pcStructuredOutput` —— 让入口校验替我们拒掉,
  ## 而不是跑到一半失败。
  {pcStreaming, pcMultiTurn, pcCancellation, pcToolCalling}

# ---------------------------------------------------------------------------
# 请求:OpenAI → Unified
# ---------------------------------------------------------------------------

proc parseRole(value, field: string): MessageRole =
  ## OpenAI 的角色集合比统一模型少一个 `developer` 的历史别名。
  ##
  ## `developer` 是 OpenAI 后来给 system 起的新名字,两者语义相同,
  ## 因此显式接受它而不是报错。
  case value
  of "system", "developer": mrSystem
  of "user": mrUser
  of "assistant": mrAssistant
  of "tool", "function": mrTool
  else:
    raiseIsvikError(
      ecInvalidParameter,
      "Unknown message role",
      "field=" & field & " got=" & value &
        " allowed=system,developer,user,assistant,tool"
    )

proc parseContent(node: JsonNode, field: string): seq[ContentPart] =
  ## OpenAI 的 content 可以是字符串,也可以是片段数组。
  ##
  ## 数组里出现非 text 片段(image_url 之类)时抛 NOT_IMPLEMENTED:
  ## 多模态未接入,静默丢掉图片会让客户端以为模型「看过了但没看懂」。
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
    if kind != "text":
      raiseIsvikError(
        ecNotImplemented,
        "Only text content parts are supported",
        "field=" & itemField & " type=" & kind
      )
    result.add(textPart(readStr(item, "text", itemField & ".text", "")))

proc parseTools(body: JsonNode): seq[ToolDefinition] =
  ## OpenAI 把工具包在 `{"type": "function", "function": {...}}` 里。
  ##
  ## 非 function 类型(retrieval / code_interpreter 之类)抛 NOT_IMPLEMENTED:
  ## 静默跳过会让客户端以为工具已注册,而模型从没见过它。
  result = @[]
  let tools = readArr(body, "tools", "tools")
  if tools == nil:
    return
  for i in 0 ..< tools.len:
    let item = tools[i]
    let field = "tools[" & $i & "]"
    if item.kind != JObject:
      rejectType(field, "object", item.kind)
    let kind = readStr(item, "type", field & ".type", "function")
    if kind != "function":
      raiseIsvikError(
        ecNotImplemented,
        "Only function tools are supported",
        "field=" & field & " type=" & kind
      )
    let fn = readObj(item, "function", field & ".function")
    if fn == nil:
      raiseIsvikError(
        ecInvalidRequest,
        "Function tool requires a function object",
        "field=" & field & ".function"
      )
    result.add(initToolDefinition(
      readRequiredStr(fn, "name", field & ".function.name"),
      readStr(fn, "description", field & ".function.description", ""),
      readObj(fn, "parameters", field & ".function.parameters")
    ))

proc parseToolChoice(body: JsonNode): ToolChoice =
  ## `tool_choice` 可以是字符串,也可以是 `{"type":"function",...}` 对象。
  if not body.hasKey("tool_choice") or body["tool_choice"].kind == JNull:
    return autoToolChoice()
  let node = body["tool_choice"]
  if node.kind == JString:
    case node.getStr
    of "auto": return autoToolChoice()
    of "none": return noToolChoice()
    of "required": return requiredToolChoice()
    else:
      raiseIsvikError(
        ecInvalidParameter,
        "Unknown tool_choice value",
        "field=tool_choice got=" & node.getStr &
          " allowed=auto,none,required or an object"
      )
  if node.kind != JObject:
    rejectType("tool_choice", "string or object", node.kind)
  let fn = readObj(node, "function", "tool_choice.function")
  if fn == nil:
    raiseIsvikError(
      ecInvalidRequest,
      "Object tool_choice requires a function object",
      "field=tool_choice.function"
    )
  specificToolChoice(
    readRequiredStr(fn, "name", "tool_choice.function.name"))

proc parseResponseFormat(body: JsonNode): ResponseFormat =
  ## `response_format` → §20.5.6 的统一 `ResponseFormat`。
  ##
  ## **必须解析,即使解码层还不支持。** 不解析等于让 `requiredCapabilities`
  ## 看不到 `pcStructuredOutput`,于是入口校验放行,请求被当成普通文本处理并
  ## 返回 200 —— 客户端要的是 JSON,拿到的是散文,而且没有任何报错。
  ## 解析出来之后,因为本 Adapter 不声明 `pcStructuredOutput`,
  ## `requireSupportedRequest` 会在入口报 NOT_IMPLEMENTED。
  ##
  ## `{"type": "text"}` 是默认值,不构成结构化输出需求,照常放行。
  if not body.hasKey("response_format") or
      body["response_format"].kind == JNull:
    return textFormat()
  let node = body["response_format"]
  if node.kind != JObject:
    rejectType("response_format", "object", node.kind)
  let kind = readStr(node, "type", "response_format.type", "text")
  case kind
  of "text": textFormat()
  of "json_object": jsonObjectFormat()
  of "json_schema":
    let spec = readObj(node, "json_schema", "response_format.json_schema")
    if spec == nil:
      raiseIsvikError(
        ecInvalidRequest,
        "response_format 'json_schema' requires a json_schema object",
        "field=response_format.json_schema"
      )
    let schema = readObj(spec, "schema", "response_format.json_schema.schema")
    if schema == nil:
      raiseIsvikError(
        ecInvalidRequest,
        "response_format 'json_schema' requires a schema object",
        "field=response_format.json_schema.schema"
      )
    jsonSchemaFormat(
      readStr(spec, "name", "response_format.json_schema.name", ""),
      schema)
  else:
    raiseIsvikError(
      ecInvalidParameter,
      "Unknown response_format type",
      "field=response_format.type got=" & kind &
        " allowed=text,json_object,json_schema"
    )

method parseRequest*(a: OpenAiChatAdapter,
                     body: JsonNode): UnifiedInferenceRequest =
  requireObject(body, "OpenAI chat completion request")

  result = initUnifiedInferenceRequest(
    readRequiredStr(body, "model", "model"))
  result.stream = readBoolField(body, "stream", "stream", false)

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

    # assistant 的 `content` 可以是 null 而只带 `tool_calls` —— 那是工具循环
    # 的第二轮:客户端把模型上一次的调用原样回传。
    let calls = readArr(node, "tool_calls", field & ".tool_calls")
    if calls != nil:
      for j in 0 ..< calls.len:
        let item = calls[j]
        let callField = field & ".tool_calls[" & $j & "]"
        if item.kind != JObject:
          rejectType(callField, "object", item.kind)
        let fn = readObj(item, "function", callField & ".function")
        if fn == nil:
          raiseIsvikError(
            ecInvalidRequest,
            "Tool call requires a function object",
            "field=" & callField & ".function"
          )
        content.add(toolUsePart(initToolCall(
          readRequiredStr(item, "id", callField & ".id"),
          readRequiredStr(fn, "name", callField & ".function.name"),
          # OpenAI 的 arguments 是**字符串**,原样保留;解析交给统一模型。
          readStr(fn, "arguments", callField & ".function.arguments", "{}"))))

    if role == mrTool:
      # 工具结果:`tool_call_id` 是它与调用的唯一对应依据,缺了就无法关联。
      let text = content.plainText()
      content = @[toolResultPart(initToolResult(
        readRequiredStr(node, "tool_call_id", field & ".tool_call_id"),
        text))]

    if content.len == 0:
      raiseIsvikError(
        ecInvalidRequest,
        "Message must provide content or tool_calls",
        "field=" & field
      )
    result.messages.add(initMessage(role, content))

  # `max_completion_tokens` 是新名字,`max_tokens` 是旧名字。新名字优先。
  let newLimit = readOptInt(body, "max_completion_tokens",
                            "max_completion_tokens")
  result.parameters.maxTokens =
    if newLimit.isSome: newLimit
    else: readOptInt(body, "max_tokens", "max_tokens")

  result.parameters.temperature = readOptFloat(body, "temperature",
                                               "temperature")
  result.parameters.topP = readOptFloat(body, "top_p", "top_p")
  result.parameters.seed = readOptInt(body, "seed", "seed")
  result.parameters.presencePenalty = readOptFloat(body, "presence_penalty",
                                                   "presence_penalty")
  result.parameters.frequencyPenalty = readOptFloat(body, "frequency_penalty",
                                                     "frequency_penalty")
  result.parameters.stopSequences = readStrSeq(body, "stop", "stop")
  # OpenAI 协议没有 top_k,也没有设备字段。device 保持为空,由服务端继承
  # settings.default_device；不去发明一个非标准字段来填它。

  result.tools = parseTools(body)
  result.toolChoice = parseToolChoice(body)
  result.responseFormat = parseResponseFormat(body)

  if body.hasKey("user"):
    # 透传但不参与推理语义:它是调用方的终端用户标识。
    result.metadata["openai_user"] = readStr(body, "user", "user", "")

  result.requireValid()
  a.requireSupportedRequest(result)

# ---------------------------------------------------------------------------
# 响应:Unified → OpenAI
# ---------------------------------------------------------------------------

proc finishReason*(reason: StopReason): JsonNode =
  ## 终止原因 → OpenAI 的 `finish_reason`。
  ##
  ## `cancelled` / `error` / `unspecified` 映射为 **null**,而不是硬凑成
  ## `"stop"`。OpenAI 用 null 表示「这一条还没正常结束」,这恰好是事实;
  ## 说成 "stop" 会让客户端把被中断的半截回答当成完整回答。
  case reason
  of srEndTurn: %"stop"
  of srStopSequence: %"stop"
  of srMaxTokens: %"length"
  of srToolUse: %"tool_calls"
  of srCancelled, srError, srUnspecified: newJNull()

proc usageJson*(usage: Usage): JsonNode =
  %*{
    "prompt_tokens": usage.inputTokens,
    "completion_tokens": usage.outputTokens,
    "total_tokens": usage.totalTokens
  }

proc generatedId*(): string =
  ## 生成一个响应 id。
  ##
  ## 只用于满足协议形状;不承诺全局唯一,也不用它做任何业务判断。
  OpenAiChatIdPrefix & $int64(epochTime() * 1_000_000.0)

proc toolCallsJson*(parts: seq[ContentPart]): JsonNode =
  ## 把工具调用片段转成 OpenAI 的 `tool_calls` 数组。没有调用时返回 nil。
  ##
  ## `arguments` 是**字符串**而不是对象 —— 这是 OpenAI 的约定,
  ## 不是笔误:它允许参数在流式过程中逐片累积。
  var calls = newJArray()
  for part in parts:
    if part.kind != cpkToolUse:
      continue
    let call = part.toolCall
    let arguments =
      if call.argumentsText.len > 0: call.argumentsText
      elif call.arguments != nil: $call.arguments
      else: "{}"
    calls.add(%*{
      "id": call.id,
      "type": "function",
      "function": {"name": call.name, "arguments": arguments}
    })
  if calls.len == 0: nil else: calls

method formatResult*(a: OpenAiChatAdapter,
                     res: UnifiedInferenceResult): JsonNode =
  let text = res.content.plainText()
  let calls = toolCallsJson(res.content)

  var message = %*{"role": "assistant"}
  # 只有“纯工具调用且无正文”时 content 才是 null。普通回答即使模型立即
  # EOS，也必须保留字符串类型；一些 OpenAI 兼容客户端会把无 tool_calls 的
  # `content:null` 直接判定为 provider returned empty content。
  message["content"] =
    if text.len > 0: %text
    elif calls != nil: newJNull()
    else: %""
  if calls != nil:
    message["tool_calls"] = calls

  result = %*{
    "id": generatedId(),
    "object": OpenAiChatObject,
    "created": int64(epochTime()),
    "model": res.model,
    "choices": [
      %*{
        "index": 0,
        "message": message,
        "finish_reason": finishReason(res.stopReason)
      }
    ],
    "usage": usageJson(res.usage)
  }
  # 实际设备不是 OpenAI 的字段,但隐瞒它就等于让调用方无法知道推理跑在哪里
  # (§27)。放在自有命名空间下,不与官方字段冲突。
  if res.device.len > 0:
    result["isvik"] = %*{"device": res.device}

proc deltaChunk(delta: JsonNode, finish: JsonNode): JsonNode =
  %*{
    "object": OpenAiChatChunkObject,
    "choices": [
      %*{"index": 0, "delta": delta, "finish_reason": finish}
    ]
  }

method formatEvent*(a: OpenAiChatAdapter,
                    e: InferenceEvent): seq[ProtocolStreamChunk] =
  case e.kind
  of iekInferenceStarted:
    # OpenAI 的首个块只带角色,正文从下一块开始。
    var chunk = deltaChunk(%*{"role": "assistant"}, newJNull())
    chunk["model"] = %e.startedModel
    result = @[initChunk("", chunk)]
  of iekContentDelta:
    result = @[initChunk("", deltaChunk(%*{"content": e.textDelta},
                                        newJNull()))]
  of iekReasoningDelta:
    # Chat Completions 没有推理字段。塞进 content 会污染正文,
    # 因此显式丢弃而不是「顺手放进去」。
    result = noChunks()
  of iekToolCallStarted:
    # 首个工具块带 index / id / name,后续只补 arguments 增量。
    result = @[initChunk("", deltaChunk(%*{
      "tool_calls": [
        {
          "index": 0,
          "id": e.toolCallId,
          "type": "function",
          "function": {"name": e.toolName, "arguments": ""}
        }
      ]
    }, newJNull()))]
  of iekToolCallDelta:
    # 参数增量块**不重复** id 与 name:OpenAI 的客户端按 index 累积,
    # 重复发送会让某些 SDK 把它当成第二次调用。
    result = @[initChunk("", deltaChunk(%*{
      "tool_calls": [
        {"index": 0, "function": {"arguments": e.argumentsDelta}}
      ]
    }, newJNull()))]
  of iekUsageUpdated:
    # 官方仅在 stream_options.include_usage 时才发 usage 块;
    # 该选项未实现,故不发。
    result = noChunks()
  of iekInferenceCompleted:
    var chunk = deltaChunk(newJObject(),
                           finishReason(e.finalResult.stopReason))
    chunk["model"] = %e.finalResult.model
    result = @[initChunk("", chunk), doneChunk()]
  of iekInferenceCancelled:
    # 取消是正常结局。给出 null finish_reason 并结束流,不伪造 "stop"。
    result = @[initChunk("", deltaChunk(newJObject(), newJNull())),
               doneChunk()]
  of iekInferenceError:
    result = @[initChunk("", a.formatError(e.errorCode, e.errorMessage)),
               doneChunk()]

method formatError*(a: OpenAiChatAdapter, code: IsvikErrorCode,
                    message: string): JsonNode =
  ## OpenAI 的错误形状:`{"error": {...}}`。
  ##
  ## `type` 用 4xx/5xx 粗分,`code` 用 Isvik 的稳定错误码 —— 保留后者使
  ## 客户端能拿到比 OpenAI 通用类别更精确的原因。detail 不出现在这里(§22)。
  let status = a.httpStatusFor(code)
  let errorType =
    if status == 401: "authentication_error"
    elif status >= 500: "server_error"
    else: "invalid_request_error"
  result = %*{
    "error": {
      "message": message,
      "type": errorType,
      "code": $code,
      "param": newJNull()
    }
  }

proc withStreamIdentity*(chunk: ProtocolStreamChunk, id: string,
                         created: int64, model: string):
    ProtocolStreamChunk =
  ## 给流式块补齐 `id` / `created` / `model`。
  ##
  ## 由 HTTP 层调用:那一层持有请求上下文,而 Adapter 刻意保持无状态,
  ## 以免并发的两个流互相覆盖对方的身份字段。已存在的 `model` 不被覆盖 ——
  ## 事件自带的值来自实际推理,比调用方请求的名字更可信。
  result = chunk
  if result.data == nil or result.data.kind != JObject:
    return
  if not result.data.hasKey("id"):
    result.data["id"] = %id
  if not result.data.hasKey("created"):
    result.data["created"] = %created
  if not result.data.hasKey("model") and model.len > 0:
    result.data["model"] = %model
