## Isvik Native 协议适配器
##
## 对应 Master Prompt §20.5.1(P0 Isvik Native API)与 §20.5.9(`/api/v1/`)。
##
## ---
##
## ## 它为什么是第一个实现
##
## Native 协议的 JSON 就是 `UnifiedInferenceRequest` 的直接序列化形式。
## 这带来两个实际好处:
##
## 1. **它是往返无损的**,因此可以用它来验证统一模型本身是否表达完备 ——
##    如果某个字段无法往返,说明统一模型有漏洞,而不是某个协议的特殊性。
## 2. **它是其它 Adapter 的参照实现**。Anthropic / OpenAI 的 Adapter 只需
##    关注「自己与 Native 形状的差异」。
##
## ---
##
## ## 字段命名
##
## 统一使用 snake_case,与 §20.5.3 给出的字段名(`response_format`、
## `tool_choice`)以及 settings.json 的风格保持一致。

import std/[json, options, strutils, tables]

import isvik/core/errors
import isvik/core/inference
import isvik/core/inference_events
import isvik/core/protocol
import isvik/core/tools

type
  NativeAdapter* = ref object of ProtocolAdapter
    ## Isvik Native 协议适配器。

const
  NativeProtocolName* = "isvik-native"
  NativeApiVersion* = "/api/v1"

proc newNativeAdapter*(): NativeAdapter = NativeAdapter()

method protocolName*(a: NativeAdapter): string = NativeProtocolName
method apiVersion*(a: NativeAdapter): string = NativeApiVersion

method capabilities*(a: NativeAdapter): set[ProtocolCapability] =
  ## Native 协议是统一模型的直接映射,因此声明支持全部能力。
  ##
  ## 注意:这里声明的是**协议层**能否表达这些能力,不代表当前的模型或
  ## Backend 一定能执行。运行时能力由 Core 与 Backend 各自判断并报错。
  {pcStreaming, pcToolCalling, pcStructuredOutput, pcReasoning,
   pcMultiTurn, pcSingleInput, pcCancellation}

# ---------------------------------------------------------------------------
# JSON 读取辅助
# ---------------------------------------------------------------------------

proc jsonKindName(kind: JsonNodeKind): string =
  case kind
  of JString: "string"
  of JInt: "integer"
  of JFloat: "float"
  of JBool: "boolean"
  of JObject: "object"
  of JArray: "array"
  of JNull: "null"

proc rejectType(field, expected: string, got: JsonNodeKind) {.noreturn.} =
  ## 字段类型错误一律报 INVALID_PARAMETER,并指明字段名与期望类型。
  ##
  ## 与配置模块相同的原则:**缺失**字段可以用默认值,
  ## 但字段**存在而类型错误**必须报错,静默忽略等于篡改调用方的意图。
  raiseIsvikError(
    ecInvalidParameter,
    "Invalid field type in request",
    "field=" & field & " expected=" & expected & " got=" & jsonKindName(got)
  )

proc readStr(node: JsonNode, key, field, fallback: string): string =
  if node == nil or not node.hasKey(key):
    return fallback
  let v = node[key]
  if v.kind != JString:
    rejectType(field, "string", v.kind)
  v.getStr

proc readBoolField(node: JsonNode, key, field: string, fallback: bool): bool =
  if node == nil or not node.hasKey(key):
    return fallback
  let v = node[key]
  if v.kind != JBool:
    rejectType(field, "boolean", v.kind)
  v.getBool

proc readOptInt(node: JsonNode, key, field: string): Option[int] =
  if node == nil or not node.hasKey(key) or node[key].kind == JNull:
    return none(int)
  let v = node[key]
  if v.kind != JInt:
    rejectType(field, "integer", v.kind)
  some(v.getInt)

proc readOptFloat(node: JsonNode, key, field: string): Option[float] =
  if node == nil or not node.hasKey(key) or node[key].kind == JNull:
    return none(float)
  let v = node[key]
  # 整数字面量对浮点参数是合法输入(temperature: 1 等价于 1.0)。
  if v.kind notin {JFloat, JInt}:
    rejectType(field, "number", v.kind)
  some(v.getFloat)

proc readObj(node: JsonNode, key, field: string): JsonNode =
  if node == nil or not node.hasKey(key) or node[key].kind == JNull:
    return nil
  let v = node[key]
  if v.kind != JObject:
    rejectType(field, "object", v.kind)
  v

proc readArr(node: JsonNode, key, field: string): JsonNode =
  if node == nil or not node.hasKey(key) or node[key].kind == JNull:
    return nil
  let v = node[key]
  if v.kind != JArray:
    rejectType(field, "array", v.kind)
  v

proc parseEnumField[T: enum](node: JsonNode, key, field: string,
                             fallback: T): T =
  ## 从字符串解析枚举。取值不在集合内时报错并列出全部合法取值。
  if node == nil or not node.hasKey(key):
    return fallback
  let v = node[key]
  if v.kind != JString:
    rejectType(field, "string", v.kind)
  let wanted = v.getStr
  for candidate in T:
    if $candidate == wanted:
      return candidate
  var allowed: seq[string] = @[]
  for candidate in T:
    allowed.add($candidate)
  raiseIsvikError(
    ecInvalidParameter,
    "Invalid enum value in request",
    "field=" & field & " allowed=" & allowed.join(",") & " got=" & wanted
  )

# ---------------------------------------------------------------------------
# 请求解析:Native JSON → Unified
# ---------------------------------------------------------------------------

proc parseToolCall(node: JsonNode, field: string): ToolCall =
  if node.kind != JObject:
    rejectType(field, "object", node.kind)
  result = initToolCall(
    id = readStr(node, "id", field & ".id", ""),
    name = readStr(node, "name", field & ".name", ""),
    argumentsText = readStr(node, "arguments_text", field & ".arguments_text", "")
  )
  if node.hasKey("arguments") and node["arguments"].kind != JNull:
    result.arguments = node["arguments"]

proc parseToolResult(node: JsonNode, field: string): ToolResult =
  if node.kind != JObject:
    rejectType(field, "object", node.kind)
  initToolResult(
    toolCallId = readStr(node, "tool_call_id", field & ".tool_call_id", ""),
    content = readStr(node, "content", field & ".content", ""),
    isError = readBoolField(node, "is_error", field & ".is_error", false)
  )

proc parseContentPart(node: JsonNode, field: string): ContentPart =
  if node.kind != JObject:
    rejectType(field, "object", node.kind)

  let partType = readStr(node, "type", field & ".type", "text")
  case partType
  of "text":
    textPart(readStr(node, "text", field & ".text", ""))
  of "reasoning":
    reasoningPart(readStr(node, "text", field & ".text", ""))
  of "tool_use":
    let callNode = readObj(node, "tool_call", field & ".tool_call")
    if callNode == nil:
      raiseIsvikError(
        ecInvalidRequest,
        "Content part of type 'tool_use' requires a tool_call object",
        "field=" & field
      )
    toolUsePart(parseToolCall(callNode, field & ".tool_call"))
  of "tool_result":
    let resNode = readObj(node, "tool_result", field & ".tool_result")
    if resNode == nil:
      raiseIsvikError(
        ecInvalidRequest,
        "Content part of type 'tool_result' requires a tool_result object",
        "field=" & field
      )
    toolResultPart(parseToolResult(resNode, field & ".tool_result"))
  else:
    # 未知的片段类型不静默丢弃:客户端显然想表达某种内容,
    # 忽略它会让请求语义悄悄改变(§20.5.13 第 12 条)。
    raiseIsvikError(
      ecNotImplemented,
      "Unsupported content part type",
      "field=" & field & " type=" & partType
    )

proc parseMessage(node: JsonNode, field: string): Message =
  if node.kind != JObject:
    rejectType(field, "object", node.kind)

  result.role = parseEnumField(node, "role", field & ".role", mrUser)
  result.content = @[]

  # 允许两种写法:content 为字符串(便捷形式)或片段数组(完整形式)。
  if node.hasKey("content") and node["content"].kind == JString:
    result.content.add(textPart(node["content"].getStr))
    return

  let arr = readArr(node, "content", field & ".content")
  if arr != nil:
    # 注意:必须用显式索引遍历 JArray。
    # `for i, x in jsonNode` 会匹配 std/json 的 pairs() 迭代器,
    # 而 pairs() 只支持 JObject —— 对 JArray 会在运行时触发
    # 「pairs() can not iterate a JsonNode of kind JArray」断言失败。
    # 这种写法能通过编译(i 被推断为 string),因此必须靠测试发现。
    for i in 0 ..< arr.len:
      result.content.add(parseContentPart(arr[i],
                                          field & ".content[" & $i & "]"))

proc parseParameters(node: JsonNode): InferenceParameters =
  result = initInferenceParameters()
  if node == nil:
    return

  result.maxTokens = readOptInt(node, "max_tokens", "parameters.max_tokens")
  result.temperature = readOptFloat(node, "temperature", "parameters.temperature")
  result.topP = readOptFloat(node, "top_p", "parameters.top_p")
  result.topK = readOptInt(node, "top_k", "parameters.top_k")
  result.seed = readOptInt(node, "seed", "parameters.seed")
  result.presencePenalty = readOptFloat(node, "presence_penalty",
                                        "parameters.presence_penalty")
  result.frequencyPenalty = readOptFloat(node, "frequency_penalty",
                                         "parameters.frequency_penalty")

  let stops = readArr(node, "stop_sequences", "parameters.stop_sequences")
  if stops != nil:
    for i in 0 ..< stops.len:
      let item = stops[i]
      if item.kind != JString:
        rejectType("parameters.stop_sequences[" & $i & "]", "string", item.kind)
      result.stopSequences.add(item.getStr)

proc parseToolDefinition(node: JsonNode, field: string): ToolDefinition =
  if node.kind != JObject:
    rejectType(field, "object", node.kind)
  initToolDefinition(
    name = readStr(node, "name", field & ".name", ""),
    description = readStr(node, "description", field & ".description", ""),
    inputSchema = readObj(node, "input_schema", field & ".input_schema")
  )

proc parseToolChoice(node: JsonNode): ToolChoice =
  if node == nil:
    return autoToolChoice()
  result.kind = parseEnumField(node, "kind", "tool_choice.kind", tckAuto)
  result.name = readStr(node, "name", "tool_choice.name", "")

proc parseResponseFormat(node: JsonNode): ResponseFormat =
  if node == nil:
    return textFormat()

  let kind = parseEnumField(node, "kind", "response_format.kind", rfkText)
  case kind
  of rfkText: textFormat()
  of rfkJsonObject: jsonObjectFormat()
  of rfkJsonSchema:
    let schema = readObj(node, "schema", "response_format.schema")
    if schema == nil:
      raiseIsvikError(
        ecInvalidRequest,
        "response_format 'json_schema' requires a schema object",
        "field=response_format.schema"
      )
    jsonSchemaFormat(
      readStr(node, "name", "response_format.name", ""),
      schema
    )

method parseRequest*(a: NativeAdapter,
                    body: JsonNode): UnifiedInferenceRequest =
  if body == nil or body.kind != JObject:
    raiseIsvikError(
      ecInvalidRequest,
      "Request body must be a JSON object",
      "got=" & (if body == nil: "nothing" else: jsonKindName(body.kind))
    )

  result = initUnifiedInferenceRequest(readStr(body, "model", "model", ""))
  result.input = readStr(body, "input", "input", "")
  result.device = readStr(body, "device", "device", "")
  result.stream = readBoolField(body, "stream", "stream", false)
  result.parameters = parseParameters(readObj(body, "parameters", "parameters"))
  result.toolChoice = parseToolChoice(readObj(body, "tool_choice", "tool_choice"))
  result.responseFormat = parseResponseFormat(
    readObj(body, "response_format", "response_format"))

  let messages = readArr(body, "messages", "messages")
  if messages != nil:
    for i in 0 ..< messages.len:
      result.messages.add(parseMessage(messages[i], "messages[" & $i & "]"))

  let toolsArr = readArr(body, "tools", "tools")
  if toolsArr != nil:
    for i in 0 ..< toolsArr.len:
      result.tools.add(parseToolDefinition(toolsArr[i], "tools[" & $i & "]"))

  let meta = readObj(body, "metadata", "metadata")
  if meta != nil:
    for key, value in meta:
      if value.kind != JString:
        rejectType("metadata." & key, "string", value.kind)
      result.metadata[key] = value.getStr

  # 请求形状与取值的完整校验放在最后,一次性给出问题。
  result.requireValid()

# ---------------------------------------------------------------------------
# 请求序列化:Unified → Native JSON
# ---------------------------------------------------------------------------

proc toJsonNode*(params: InferenceParameters): JsonNode =
  ## 只输出**已指定**的参数。
  ##
  ## 这是往返无损的关键:如果把未指定的参数补成默认值输出,
  ## 再解析回来时「未指定」就变成了「显式指定」,语义已经改变。
  result = newJObject()
  if params.maxTokens.isSome: result["max_tokens"] = %params.maxTokens.get
  if params.temperature.isSome: result["temperature"] = %params.temperature.get
  if params.topP.isSome: result["top_p"] = %params.topP.get
  if params.topK.isSome: result["top_k"] = %params.topK.get
  if params.seed.isSome: result["seed"] = %params.seed.get
  if params.presencePenalty.isSome:
    result["presence_penalty"] = %params.presencePenalty.get
  if params.frequencyPenalty.isSome:
    result["frequency_penalty"] = %params.frequencyPenalty.get
  if params.stopSequences.len > 0:
    var arr = newJArray()
    for s in params.stopSequences:
      arr.add(%s)
    result["stop_sequences"] = arr

proc toJsonNode*(format: ResponseFormat): JsonNode =
  result = %*{"kind": $format.kind}
  if format.kind == rfkJsonSchema:
    result["name"] = %format.schemaName
    result["schema"] = format.schema

proc toJsonNode*(msg: Message): JsonNode =
  var contentArray = newJArray()
  for part in msg.content:
    contentArray.add(part.toJsonNode())
  %*{"role": $msg.role, "content": contentArray}

proc toJsonNode*(req: UnifiedInferenceRequest): JsonNode =
  ## 统一请求的 Native JSON 表示。
  ##
  ## 只输出非默认值的字段,保持输出简洁并保证往返无损。
  result = %*{"model": req.model}

  if req.messages.len > 0:
    var arr = newJArray()
    for msg in req.messages:
      arr.add(msg.toJsonNode())
    result["messages"] = arr

  if req.input.len > 0:
    result["input"] = %req.input
  if req.device.len > 0:
    result["device"] = %req.device
  if req.stream:
    result["stream"] = %true

  let paramsNode = req.parameters.toJsonNode()
  if paramsNode.len > 0:
    result["parameters"] = paramsNode

  if req.tools.len > 0:
    var arr = newJArray()
    for tool in req.tools:
      arr.add(tool.toJsonNode())
    result["tools"] = arr

  if req.toolChoice.kind != tckAuto:
    result["tool_choice"] = req.toolChoice.toJsonNode()

  if req.responseFormat.kind != rfkText:
    result["response_format"] = req.responseFormat.toJsonNode()

  if req.metadata.len > 0:
    var meta = newJObject()
    for key, value in req.metadata:
      meta[key] = %value
    result["metadata"] = meta

# ---------------------------------------------------------------------------
# 响应方向
# ---------------------------------------------------------------------------

method formatResult*(a: NativeAdapter, res: UnifiedInferenceResult): JsonNode =
  ## Native 的非流式响应就是统一结果本身。
  res.toJsonNode()

method formatEvent*(a: NativeAdapter,
                    e: InferenceEvent): seq[ProtocolStreamChunk] =
  ## Native 流直接转发统一事件,每条事件一个块。
  ##
  ## 事件名与 `type` 字段一致,使客户端既可用 SSE 的 event 分派,
  ## 也可只解析 data 内容。
  result = @[initChunk($e.kind, e.toJsonNode())]
  if e.isTerminal:
    result.add(doneChunk())

method formatError*(a: NativeAdapter, code: IsvikErrorCode,
                    message: string): JsonNode =
  ## 采用 §22 规定的错误响应形状,与 CLI / GUI 使用的形状一致。
  errorJson(code, message)
