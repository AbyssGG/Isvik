## 统一 Tool Calling 模型
##
## 对应 Master Prompt §20.5.5:
##
## ```text
## External Tool Format
##         ↓
##  Protocol Adapter
##         ↓
##   Isvik Tool Model     ← 本模块
##         ↓
##     Isvik Core
## ```
##
## §20.5.5 明确要求 Tool Calling 是 **Isvik 的统一能力**,
## 而不是 Anthropic-only 或 OpenAI-only 的功能。因此工具的定义、调用、
## 参数、结果都用同一套内部类型表示,各协议只负责在边界上做转换。
##
## 本模块只依赖 std 与 core/errors。

import std/[json, options, strutils, sets]

import isvik/core/errors

type
  ToolDefinition* = object
    ## 工具声明(§20.5.5 Tool Definition)。
    name*: string
      ## 工具名。同一请求内必须唯一,模型依据它决定调用哪个工具。
    description*: string
      ## 面向模型的说明。质量直接影响模型是否正确选用工具。
    inputSchema*: JsonNode
      ## 参数的 JSON Schema。可以为 nil(表示无参数)。
      ##
      ## 有意保持为 JsonNode 而不是强类型 Schema 结构:JSON Schema 规范庞大且
      ## 各家支持的子集不同,把它建模成 Nim 类型会在每次遇到新关键字时返工。
      ## Isvik 只做结构性校验并原样传递。

  ToolCall* = object
    ## 模型发起的一次工具调用(§20.5.5 Tool Call / Tool Arguments)。
    id*: string
      ## 调用标识。工具结果通过它关联回本次调用。
      ## 并发调用多个工具时,这是唯一的对应依据。
    name*: string
    arguments*: JsonNode
      ## 已解析的参数。流式场景下在累积完成前可能为 nil。
    argumentsText*: string
      ## 参数的原始文本。
      ##
      ## 同时保留文本与解析结果是有意的:流式工具调用的参数是逐片到达的
      ## (§20.5.5 Streaming Tool Call),中途无法解析成合法 JSON,
      ## 必须先累积文本,结束时再解析。丢掉原文就无法累积。

  ToolResult* = object
    ## 工具执行结果(§20.5.5 Tool Result)。
    toolCallId*: string
      ## 对应的 ToolCall.id。
    content*: string
      ## 结果内容。统一为字符串:工具返回的可能是 JSON、纯文本或错误说明,
      ## 由调用方决定如何解释。
    isError*: bool
      ## 该结果是否表示工具执行失败(§20.5.5 Error Handling)。
      ##
      ## 工具失败**不等于**推理失败:模型通常需要看到错误内容以便重试或改用
      ## 其它工具。因此这里用标记位表达,而不是抛 IsvikError 中断推理。

  ToolChoiceKind* = enum
    ## 工具选择策略。Anthropic 与 OpenAI 都有等价概念。
    tckAuto = "auto"
      ## 由模型自行决定是否调用工具。
    tckNone = "none"
      ## 禁止调用工具。
    tckRequired = "required"
      ## 必须调用某个工具(具体哪个由模型决定)。
    tckSpecific = "specific"
      ## 必须调用指定的工具。

  ToolChoice* = object
    kind*: ToolChoiceKind
    name*: string
      ## 仅 tckSpecific 时有意义。

# ---------------------------------------------------------------------------
# 构造
# ---------------------------------------------------------------------------

proc initToolDefinition*(name: string, description: string = "",
                         inputSchema: JsonNode = nil): ToolDefinition =
  ToolDefinition(name: name, description: description, inputSchema: inputSchema)

proc initToolCall*(id, name: string, argumentsText: string = "",
                   arguments: JsonNode = nil): ToolCall =
  ToolCall(id: id, name: name, arguments: arguments,
           argumentsText: argumentsText)

proc initToolResult*(toolCallId, content: string,
                     isError: bool = false): ToolResult =
  ToolResult(toolCallId: toolCallId, content: content, isError: isError)

proc autoToolChoice*(): ToolChoice = ToolChoice(kind: tckAuto, name: "")
proc noToolChoice*(): ToolChoice = ToolChoice(kind: tckNone, name: "")
proc requiredToolChoice*(): ToolChoice = ToolChoice(kind: tckRequired, name: "")
proc specificToolChoice*(name: string): ToolChoice =
  ToolChoice(kind: tckSpecific, name: name)

# ---------------------------------------------------------------------------
# 流式参数累积(§20.5.5 Streaming Tool Call)
# ---------------------------------------------------------------------------

proc appendArguments*(call: var ToolCall, delta: string) =
  ## 追加一段参数文本。用于流式工具调用的累积。
  ##
  ## 每次追加后 `arguments` 被置为 nil:此刻文本很可能还不是合法 JSON,
  ## 保留上一次的解析结果会造成「参数看起来完整但其实过期」的错觉。
  call.argumentsText.add(delta)
  call.arguments = nil

proc finalizeArguments*(call: var ToolCall) =
  ## 参数接收完毕,把累积的文本解析为 JSON。
  ##
  ## 解析失败抛 IsvikError(TOOL_CALL_FAILED):模型给出了无法解析的参数,
  ## 这是必须让调用方知道的失败,不能静默当作空参数继续。
  let text = call.argumentsText.strip()
  if text.len == 0:
    # 无参数工具的正常情况:视为空对象。
    call.arguments = newJObject()
    return
  try:
    call.arguments = parseJson(text)
  except JsonParsingError as e:
    raiseIsvikError(
      ecToolCallFailed,
      "Tool call arguments are not valid JSON",
      "toolCallId=" & call.id & " tool=" & call.name & " parse=" & e.msg
    )

proc hasParsedArguments*(call: ToolCall): bool =
  ## 参数是否已解析完成。
  call.arguments != nil

proc argumentsObject*(call: ToolCall): JsonNode =
  ## 取参数的**对象**形式,供需要 JSON 对象的协议使用(Anthropic 的 `input`)。
  ##
  ## 优先用已解析结果;只有文本时尝试解析;都没有或解析失败时返回空对象。
  ##
  ## 这里刻意**不报错**:该函数用在响应构造路径上,此时参数早已通过
  ## `finalizeArguments` 校验过。在输出阶段再抛一次异常只会把一个已经
  ## 成功的推理变成失败。
  if call.arguments != nil:
    return call.arguments
  if call.argumentsText.strip().len == 0:
    return newJObject()
  try:
    result = parseJson(call.argumentsText)
  except CatchableError:
    result = newJObject()
  if result == nil or result.kind != JObject:
    result = newJObject()

# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------

proc validateToolDefinition*(tool: ToolDefinition): Option[string] =
  ## 校验单个工具声明。返回 none 表示合法。
  if tool.name.strip().len == 0:
    return some("tool name must not be empty")

  # 工具名会出现在协议 JSON 与模型提示中,限制字符集避免转义与歧义问题。
  for c in tool.name:
    if not (c.isAlphaNumeric or c in {'_', '-'}):
      return some("tool name may only contain letters, digits, '_' and '-', got: " &
                  tool.name)

  if tool.inputSchema != nil and tool.inputSchema.kind != JObject:
    return some("tool inputSchema must be a JSON object, got: " &
                $tool.inputSchema.kind)

  result = none(string)

proc validateTools*(tools: openArray[ToolDefinition]): Option[string] =
  ## 校验工具集合,并检查名称唯一性。
  ##
  ## 名称重复必须报错:模型按名字选择工具,重名会让「调用哪个」变成不确定行为。
  var seen = initHashSet[string]()
  for tool in tools:
    let problem = validateToolDefinition(tool)
    if problem.isSome:
      return problem
    if seen.contains(tool.name):
      return some("duplicate tool name: " & tool.name)
    seen.incl(tool.name)
  result = none(string)

proc validateToolChoice*(choice: ToolChoice,
                         tools: openArray[ToolDefinition]): Option[string] =
  ## 校验工具选择策略与工具集合是否自洽。
  case choice.kind
  of tckSpecific:
    if choice.name.strip().len == 0:
      return some("tool choice 'specific' requires a tool name")
    var found = false
    for tool in tools:
      if tool.name == choice.name:
        found = true
        break
    if not found:
      return some("tool choice refers to an undeclared tool: " & choice.name)
  of tckRequired:
    if tools.len == 0:
      return some("tool choice 'required' needs at least one declared tool")
  of tckAuto, tckNone:
    discard
  result = none(string)

# ---------------------------------------------------------------------------
# JSON 表示(Isvik Native 形式)
# ---------------------------------------------------------------------------

proc toJsonNode*(tool: ToolDefinition): JsonNode =
  result = %*{"name": tool.name, "description": tool.description}
  if tool.inputSchema != nil:
    result["input_schema"] = tool.inputSchema

proc toJsonNode*(call: ToolCall): JsonNode =
  result = %*{"id": call.id, "name": call.name}
  if call.arguments != nil:
    result["arguments"] = call.arguments
  elif call.argumentsText.len > 0:
    # 尚未解析完成时,如实输出原始文本而不是伪造一个空对象。
    result["arguments_text"] = %call.argumentsText

proc toJsonNode*(res: ToolResult): JsonNode =
  %*{
    "tool_call_id": res.toolCallId,
    "content": res.content,
    "is_error": res.isError
  }

proc toJsonNode*(choice: ToolChoice): JsonNode =
  result = %*{"kind": $choice.kind}
  if choice.kind == tckSpecific:
    result["name"] = %choice.name
