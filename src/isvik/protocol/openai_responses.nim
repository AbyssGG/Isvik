## OpenAI Responses API Adapter(§20.5.1 P0)
##
## ---
##
## ## 与 Chat Completions 的差异
##
## Responses 不是 Chat Completions 换个路径,形状是重新设计过的:
##
## ```text
## 请求   input          字符串 或 条目数组(不是 messages)
##        instructions   顶层字段(不是一条 system 消息)
##        max_output_tokens
##
## 响应   output         条目数组:message / function_call ...
##        output_text    便利字段,把所有文本拼起来
##        status         completed / incomplete
##        usage          input_tokens / output_tokens / total_tokens
##
## 流式   具名事件       response.output_text.delta 等
## ```
##
## §20.5.1 把它列为 P0,理由是现代 Agent 客户端优先接这个接口。
##
## ---
##
## ## 三处刻意的取舍
##
## - **`instructions` 转成第一条 system 消息。** 与 Anthropic 的顶层 `system`
##   同一处理方式:差异在 Adapter 边界消化,Core 只看到一种形式(§20.5.3)。
## - **`status` 如实反映终止原因。** 被 max_output_tokens 截断时是
##   `incomplete` 并带 `incomplete_details.reason = "max_output_tokens"`,
##   不报 `completed` —— 后者会让客户端把半截回答当成完整回答。
## - **不实现 `store` / `previous_response_id`。** 那需要服务端保存会话状态,
##   而本服务是无状态的。请求这两个字段会得到 NOT_IMPLEMENTED,
##   而不是被静默忽略后让客户端以为多轮上下文已经保留。

import std/[json, strutils, times]

import isvik/core/errors
import isvik/core/tools
import isvik/core/inference
import isvik/core/inference_events
import isvik/core/protocol
import isvik/protocol/json_read

const
  OpenAiResponsesProtocolName* = "openai-responses"
  OpenAiResponsesApiVersion* = "/v1"
  OpenAiResponsesObject* = "response"
  OpenAiResponsesIdPrefix* = "resp_"
  OpenAiResponsesMessageIdPrefix* = "msg_"

type
  OpenAiResponsesAdapter* = ref object of ProtocolAdapter

proc newOpenAiResponsesAdapter*(): OpenAiResponsesAdapter =
  new(result)

method protocolName*(a: OpenAiResponsesAdapter): string =
  OpenAiResponsesProtocolName

method apiVersion*(a: OpenAiResponsesAdapter): string =
  OpenAiResponsesApiVersion

method capabilities*(a: OpenAiResponsesAdapter): set[ProtocolCapability] =
  ## 含 `pcSingleInput`:Responses 的 `input` 可以是一个裸字符串,
  ## 那正是「单条原始输入」这一能力。
  ##
  ## 不含 `pcStructuredOutput`:`text.format` 未接入解码。
  {pcStreaming, pcMultiTurn, pcSingleInput, pcCancellation, pcToolCalling}

# ---------------------------------------------------------------------------
# 请求:Responses → Unified
# ---------------------------------------------------------------------------

proc parseRole(value, field: string): MessageRole =
  case value
  of "system", "developer": mrSystem
  of "user": mrUser
  of "assistant": mrAssistant
  of "tool": mrTool
  else:
    raiseIsvikError(
      ecInvalidParameter,
      "Unknown message role",
      "field=" & field & " got=" & value
    )

proc parseContent(node: JsonNode, field: string): seq[ContentPart] =
  ## Responses 的内容片段类型名与 Chat Completions 不同:
  ## `input_text` / `output_text`,而不是 `text`。两者都接受。
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
    if item.kind == JString:
      result.add(textPart(item.getStr))
      continue
    if item.kind != JObject:
      rejectType(itemField, "object or string", item.kind)
    let kind = readStr(item, "type", itemField & ".type", "input_text")
    case kind
    of "input_text", "output_text", "text":
      result.add(textPart(readStr(item, "text", itemField & ".text", "")))
    else:
      raiseIsvikError(
        ecNotImplemented,
        "Only text content parts are supported",
        "field=" & itemField & " type=" & kind
      )

proc parseInput(body: JsonNode, messages: var seq[Message]) =
  ## `input` 既可以是一个裸字符串,也可以是条目数组。
  ##
  ## 裸字符串按一条 user 消息处理:统一模型里 `input` 与 `messages` 二者取一,
  ## 而把它当 user 消息能让后续路径只有一条(不必为单输入再写一遍编排)。
  if not body.hasKey("input") or body["input"].kind == JNull:
    raiseIsvikError(
      ecInvalidRequest,
      "Field input is required",
      "field=input"
    )
  let node = body["input"]
  if node.kind == JString:
    let text = node.getStr
    if text.strip().len == 0:
      raiseIsvikError(
        ecInvalidRequest,
        "Field input must not be empty",
        "field=input"
      )
    messages.add(textMessage(mrUser, text))
    return
  if node.kind != JArray:
    rejectType("input", "string or array", node.kind)
  if node.len == 0:
    raiseIsvikError(
      ecInvalidRequest,
      "Field input must not be empty",
      "field=input"
    )

  for i in 0 ..< node.len:
    let item = node[i]
    let field = "input[" & $i & "]"
    if item.kind != JObject:
      rejectType(field, "object", item.kind)
    let itemType = readStr(item, "type", field & ".type", "message")
    case itemType
    of "message":
      let role = parseRole(
        readRequiredStr(item, "role", field & ".role"), field & ".role")
      var content: seq[ContentPart] = @[]
      if item.hasKey("content"):
        content = parseContent(item["content"], field & ".content")
      if content.len == 0:
        raiseIsvikError(
          ecInvalidRequest,
          "Message content must not be empty",
          "field=" & field & ".content"
        )
      messages.add(initMessage(role, content))
    of "function_call":
      # 客户端回传上一轮模型发起的调用。`arguments` 在 Responses 里是
      # **字符串**,与 Chat Completions 一致。
      let arguments = readStr(item, "arguments", field & ".arguments", "{}")
      messages.add(initMessage(mrAssistant, @[toolUsePart(initToolCall(
        readRequiredStr(item, "call_id", field & ".call_id"),
        readRequiredStr(item, "name", field & ".name"),
        arguments))]))
    of "function_call_output":
      messages.add(initMessage(mrTool, @[toolResultPart(initToolResult(
        readRequiredStr(item, "call_id", field & ".call_id"),
        readStr(item, "output", field & ".output", "")))]))
    else:
      raiseIsvikError(
        ecNotImplemented,
        "Unsupported input item type",
        "field=" & field & " type=" & itemType
      )

proc parseTools(body: JsonNode): seq[ToolDefinition] =
  ## Responses 的工具是**扁平**的:`{"type":"function","name":...}`,
  ## 没有 Chat Completions 那层 `function` 包装。
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
    result.add(initToolDefinition(
      readRequiredStr(item, "name", field & ".name"),
      readStr(item, "description", field & ".description", ""),
      readObj(item, "parameters", field & ".parameters")
    ))

proc parseToolChoice(body: JsonNode): ToolChoice =
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
        "field=tool_choice got=" & node.getStr
      )
  if node.kind != JObject:
    rejectType("tool_choice", "string or object", node.kind)
  # 对象形式在 Responses 里同样是扁平的:`{"type":"function","name":...}`。
  specificToolChoice(readRequiredStr(node, "name", "tool_choice.name"))

proc parseTextFormat(body: JsonNode): ResponseFormat =
  ## Responses 把结构化输出放在 `text.format` 里,而 Chat Completions 放在顶层
  ## `response_format`。同一件事两种位置,差异在这里消化。
  ##
  ## 另一处差异:`name` 与 `schema` 在 Responses 里是**扁平**的
  ## (`text.format.name` / `text.format.schema`),没有 Chat Completions 那层
  ## `json_schema` 包装。
  ##
  ## **必须解析,即使解码层还不支持。** 不解析等于让 `requiredCapabilities`
  ## 看不到 `pcStructuredOutput`,请求被当成普通文本处理并返回 200 ——
  ## 客户端要的是 JSON,拿到的是散文,而且没有任何报错。
  if not body.hasKey("text") or body["text"].kind == JNull:
    return textFormat()
  let textNode = body["text"]
  if textNode.kind != JObject:
    rejectType("text", "object", textNode.kind)
  let node = readObj(textNode, "format", "text.format")
  if node == nil:
    return textFormat()
  let kind = readStr(node, "type", "text.format.type", "text")
  case kind
  of "text": textFormat()
  of "json_object": jsonObjectFormat()
  of "json_schema":
    let schema = readObj(node, "schema", "text.format.schema")
    if schema == nil:
      raiseIsvikError(
        ecInvalidRequest,
        "text.format 'json_schema' requires a schema object",
        "field=text.format.schema"
      )
    jsonSchemaFormat(readStr(node, "name", "text.format.name", ""), schema)
  else:
    raiseIsvikError(
      ecInvalidParameter,
      "Unknown text.format type",
      "field=text.format.type got=" & kind &
        " allowed=text,json_object,json_schema"
    )

proc rejectStatefulFields(body: JsonNode) =
  ## 拒绝需要服务端保存会话状态的字段。
  ##
  ## 静默忽略 `previous_response_id` 最危险:客户端会以为上一轮的上下文还在,
  ## 而模型实际上什么都不记得 —— 症状是「模型突然失忆」,极难归因到这里。
  for field in ["previous_response_id", "store"]:
    if body.hasKey(field) and body[field].kind != JNull:
      if field == "store" and body[field].kind == JBool and
          not body[field].getBool:
        # `store: false` 与无状态实现一致,可以接受。
        continue
      raiseIsvikError(
        ecNotImplemented,
        "Server-side conversation state is not implemented",
        "field=" & field
      )

method parseRequest*(a: OpenAiResponsesAdapter,
                     body: JsonNode): UnifiedInferenceRequest =
  requireObject(body, "OpenAI responses request")
  rejectStatefulFields(body)

  result = initUnifiedInferenceRequest(
    readRequiredStr(body, "model", "model"))
  result.stream = readBoolField(body, "stream", "stream", false)

  # `instructions` 是顶层字段,转成第一条 system 消息 ——
  # 与 Anthropic 的顶层 system 同一处理方式。
  let instructions = readStr(body, "instructions", "instructions", "")
  if instructions.strip().len > 0:
    result.messages.add(textMessage(mrSystem, instructions))

  parseInput(body, result.messages)

  result.parameters.maxTokens = readOptInt(body, "max_output_tokens",
                                           "max_output_tokens")
  result.parameters.temperature = readOptFloat(body, "temperature",
                                               "temperature")
  result.parameters.topP = readOptFloat(body, "top_p", "top_p")
  result.tools = parseTools(body)
  result.toolChoice = parseToolChoice(body)
  result.responseFormat = parseTextFormat(body)

  result.requireValid()
  a.requireSupportedRequest(result)

# ---------------------------------------------------------------------------
# 响应:Unified → Responses
# ---------------------------------------------------------------------------

proc generatedId*(): string =
  OpenAiResponsesIdPrefix & $int64(epochTime() * 1_000_000.0)

proc statusFor*(reason: StopReason): string =
  ## 终止原因 → Responses 的 `status`。
  ##
  ## 只有自然结束才是 `completed`。被截断、被取消、出错都不是完成 ——
  ## 报 completed 会让客户端把半截回答当成完整回答。
  case reason
  of srEndTurn, srStopSequence, srToolUse: "completed"
  of srMaxTokens: "incomplete"
  of srCancelled: "cancelled"
  of srError: "failed"
  of srUnspecified: "incomplete"

proc incompleteDetails*(reason: StopReason): JsonNode =
  ## `status` 为 incomplete 时说明原因;否则返回 JSON null。
  case reason
  of srMaxTokens: %*{"reason": "max_output_tokens"}
  of srUnspecified: %*{"reason": "unknown"}
  else: newJNull()

proc usageJson*(usage: Usage): JsonNode =
  ## Responses 的用量字段名与 Chat Completions 不同。
  %*{
    "input_tokens": usage.inputTokens,
    "output_tokens": usage.outputTokens,
    "total_tokens": usage.totalTokens
  }

proc outputItems*(res: UnifiedInferenceResult): JsonNode =
  ## 构造 `output` 数组。
  ##
  ## 文本与工具调用是**并列的条目**,不是嵌套关系:一次响应可以既说一句话
  ## 又发起一个调用。
  result = newJArray()
  let text = res.content.plainText()
  if text.len > 0:
    result.add(%*{
      "type": "message",
      "id": OpenAiResponsesMessageIdPrefix & "0",
      "role": "assistant",
      "status": "completed",
      "content": [
        {"type": "output_text", "text": text, "annotations": newJArray()}
      ]
    })
  for part in res.content:
    if part.kind != cpkToolUse:
      continue
    let call = part.toolCall
    result.add(%*{
      "type": "function_call",
      "id": "fc_" & call.id,
      "call_id": call.id,
      "name": call.name,
      # 与 Chat Completions 一致:arguments 是字符串。
      "arguments": (if call.argumentsText.len > 0: call.argumentsText
                    else: $call.argumentsObject()),
      "status": "completed"
    })

method formatResult*(a: OpenAiResponsesAdapter,
                     res: UnifiedInferenceResult): JsonNode =
  result = %*{
    "id": generatedId(),
    "object": OpenAiResponsesObject,
    "created_at": int64(epochTime()),
    "status": statusFor(res.stopReason),
    "model": res.model,
    "output": outputItems(res),
    # `output_text` 是官方的便利字段:把所有文本条目拼起来。
    "output_text": res.content.plainText(),
    "usage": usageJson(res.usage),
    "incomplete_details": incompleteDetails(res.stopReason)
  }
  if res.device.len > 0:
    # 实际设备不是官方字段,但隐瞒它等于让调用方无法知道推理跑在哪里(§27)。
    result["isvik"] = %*{"device": res.device}

method formatError*(a: OpenAiResponsesAdapter, code: IsvikErrorCode,
                    message: string): JsonNode =
  let status = a.httpStatusFor(code)
  let errorType =
    if status == 401: "authentication_error"
    elif status >= 500: "server_error"
    else: "invalid_request_error"
  %*{
    "error": {
      "message": message,
      "type": errorType,
      "code": $code,
      "param": newJNull()
    }
  }

# ---------------------------------------------------------------------------
# 流式:具名事件
# ---------------------------------------------------------------------------

proc responseEvent(name: string, payload: JsonNode): ProtocolStreamChunk =
  var data = payload
  data["type"] = %name
  initChunk(name, data)

method formatEvent*(a: OpenAiResponsesAdapter,
                    e: InferenceEvent): seq[ProtocolStreamChunk] =
  case e.kind
  of iekInferenceStarted:
    result = @[
      responseEvent("response.created", %*{
        "response": {
          "id": generatedId(),
          "object": OpenAiResponsesObject,
          "status": "in_progress",
          "model": e.startedModel,
          "output": newJArray()
        }
      }),
      responseEvent("response.output_item.added", %*{
        "output_index": 0,
        "item": {
          "type": "message",
          "id": OpenAiResponsesMessageIdPrefix & "0",
          "role": "assistant",
          "status": "in_progress",
          "content": newJArray()
        }
      })
    ]
  of iekContentDelta:
    result = @[responseEvent("response.output_text.delta", %*{
      "output_index": 0,
      "content_index": 0,
      "delta": e.textDelta
    })]
  of iekReasoningDelta:
    # Responses 有 reasoning 条目,但那属于 reasoning 模型的专有输出,
    # 本管线并不产生它。丢弃而不是塞进 output_text 污染正文。
    result = noChunks()
  of iekToolCallStarted:
    result = @[responseEvent("response.output_item.added", %*{
      "output_index": 1,
      "item": {
        "type": "function_call",
        "id": "fc_" & e.toolCallId,
        "call_id": e.toolCallId,
        "name": e.toolName,
        "arguments": "",
        "status": "in_progress"
      }
    })]
  of iekToolCallDelta:
    result = @[responseEvent("response.function_call_arguments.delta", %*{
      "output_index": 1,
      "item_id": "fc_" & e.toolCallId,
      "delta": e.argumentsDelta
    })]
  of iekUsageUpdated:
    # usage 随 response.completed 一起发,官方流里没有单独的 usage 事件。
    result = noChunks()
  of iekInferenceCompleted:
    result = @[
      responseEvent("response.output_item.done", %*{
        "output_index": 0,
        "item": {
          "type": "message",
          "id": OpenAiResponsesMessageIdPrefix & "0",
          "role": "assistant",
          "status": "completed"
        }
      }),
      responseEvent("response.completed", %*{
        "response": {
          "id": generatedId(),
          "object": OpenAiResponsesObject,
          "status": statusFor(e.finalResult.stopReason),
          "model": e.finalResult.model,
          "output": outputItems(e.finalResult),
          "output_text": e.finalResult.content.plainText(),
          "usage": usageJson(e.finalResult.usage),
          "incomplete_details": incompleteDetails(e.finalResult.stopReason)
        }
      }),
      doneChunk()
    ]
  of iekInferenceCancelled:
    # 取消有专门的事件名,不复用 completed —— 后者会把中断说成完成。
    result = @[
      responseEvent("response.incomplete", %*{
        "response": {
          "status": "cancelled",
          "incomplete_details": %*{"reason": "cancelled"}
        }
      }),
      doneChunk()
    ]
  of iekInferenceError:
    result = @[
      responseEvent("response.failed", %*{
        "response": {
          "status": "failed",
          "error": a.formatError(e.errorCode, e.errorMessage)["error"]
        }
      }),
      doneChunk()
    ]
