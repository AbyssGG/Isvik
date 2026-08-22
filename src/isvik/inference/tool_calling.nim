## 工具调用的解码侧接入(Master Prompt §20.5.5)
##
## ---
##
## ## 这是**提示词方案**,不是原生工具格式
##
## Gemma 4 的对话模板里没有工具回合,词表里也没有工具调用标记。因此本模块的
## 做法是:
##
## ```text
## 请求里的 tools  →  渲染成一段系统指令,告诉模型「要调用工具就输出这个 JSON」
## 模型的输出       →  扫描出该 JSON,还原成统一模型的 ToolCall
## ```
##
## 这条路径的性质必须说清楚:
##
## - **可靠性取决于模型是否听话。** 没有经过工具微调的模型可能不输出信封,
##   也可能输出格式不对的信封。前者表现为「模型直接用文字回答了」,
##   后者报 `TOOL_CALL_FAILED`。两种都不是静默失败。
## - **不是 function-calling 微调模型的等价物。** 真正的原生支持需要模型侧的
##   特殊 token 与训练,那不是运行时能补的。
##
## 之所以仍然实现它:§20.5.5 要求 Tool Calling 是 Isvik 的**统一能力**,
## 而「协议层能表达、解码层直接拒绝」会让整条链路永远无法端到端验证。
##
## ---
##
## ## 为什么信封键带命名空间
##
## 信封是 `{"isvik_tool_call": {...}}`。
##
## 如果用 `{"name": ..., "arguments": ...}` 这种通用形状,模型在回答「JSON 长什么
## 样」这类问题时随手写出的示例就会被当成真的工具调用 —— 那是最难排查的一类
## 误判:请求看起来成功了,但客户端收到一个它没要求过的工具调用。
##
## `isvik_tool_call` 这个键不会出现在普通文本里。

import std/[json, strutils]

import isvik/core/errors
import isvik/core/tools

const
  ToolCallEnvelopeKey* = "isvik_tool_call"
    ## 工具调用信封的顶层键。带命名空间以避免与模型随手写的 JSON 混淆。
  ToolResultEnvelopeKey* = "isvik_tool_result"
    ## 工具结果回传给模型时使用的标记。
  DefaultToolCallIdPrefix* = "call_"

type
  ToolCallExtraction* = object
    ## 从模型输出里分离出的工具调用与剩余可见文本。
    calls*: seq[ToolCall]
    text*: string
      ## 去掉信封后的可见文本。模型常在信封前后附一句解释,
      ## 那部分仍然是给用户看的正文。
    hadCall*: bool

proc initToolCallExtraction*(text: string): ToolCallExtraction =
  ToolCallExtraction(calls: @[], text: text, hadCall: false)

# ---------------------------------------------------------------------------
# 指令渲染
# ---------------------------------------------------------------------------

proc schemaText(tool: ToolDefinition): string =
  if tool.inputSchema == nil:
    "{}"
  else:
    $tool.inputSchema

proc renderToolInstructions*(tools: openArray[ToolDefinition],
                             choice: ToolChoice): string =
  ## 把工具声明渲染成一段系统指令。
  ##
  ## 工具集为空、或策略是 `none` 时返回空串 —— 那两种情况下不该向模型提
  ## 工具,否则它可能凭空调用一个不存在的东西。
  if tools.len == 0 or choice.kind == tckNone:
    return ""

  var lines: seq[string] = @[]
  lines.add("You have access to the following tools.")
  lines.add("")
  for tool in tools:
    var line = "- " & tool.name
    if tool.description.len > 0:
      line.add(": " & tool.description)
    lines.add(line)
    lines.add("  parameters JSON Schema: " & schemaText(tool))
  lines.add("")
  lines.add("To call a tool, reply with exactly this JSON object and nothing" &
            " else:")
  lines.add("{\"" & ToolCallEnvelopeKey &
            "\": {\"name\": \"<tool name>\", \"arguments\": { ... }}}")
  lines.add("")
  lines.add("Rules:")
  lines.add("- The arguments object must match that tool's schema.")
  lines.add("- Call only tools from the list above.")
  # 每条策略都必须说出来。只在代码里判断而不告诉模型,`required` 就形同虚设。
  case choice.kind
  of tckAuto:
    lines.add("- If no tool is needed, answer normally in plain text.")
  of tckRequired:
    lines.add("- You must call one of the tools; do not answer in plain text.")
  of tckSpecific:
    lines.add("- You must call the tool named \"" & choice.name & "\".")
  of tckNone:
    discard
  lines.add("- A tool result will be provided back to you, marked with \"" &
            ToolResultEnvelopeKey & "\".")
  result = lines.join("\n")

proc renderToolCallEnvelope*(call: ToolCall): string =
  ## 把一次工具调用还原成信封文本。
  ##
  ## 用于**重放历史**:多轮工具对话里,上一轮 assistant 的工具调用必须以模型
  ## 当初输出的形状回到提示词里,否则它看到的是自己没说过的话。
  $(%*{ToolCallEnvelopeKey: {
    "name": call.name,
    "arguments": call.argumentsObject()
  }})

proc renderToolResultText*(res: ToolResult, toolName: string = ""): string =
  ## 把工具结果渲染成回传给模型的文本。
  ##
  ## `chat_format.ChatRole` 刻意不含 tool 角色(工具回合的模板远比文本回合
  ## 复杂),因此结果以 **user 回合**的形式回去,并用标记键说明它的来源。
  ## 不把它伪装成普通用户发言:模型需要知道这是工具的输出。
  var payload = %*{
    "tool_call_id": res.toolCallId,
    "content": res.content,
    "is_error": res.isError
  }
  if toolName.len > 0:
    payload["name"] = %toolName
  $(%*{ToolResultEnvelopeKey: payload})

# ---------------------------------------------------------------------------
# 输出解析
# ---------------------------------------------------------------------------

proc balancedObjectEnd(text: string, start: int): int =
  ## 从 `text[start] == '{'` 出发找到配对的 `}`,返回其下标;找不到返回 -1。
  ##
  ## 必须感知字符串与转义:参数里出现 `"}"` 这种内容时,单纯数括号会在错误的
  ## 位置收尾,得到一个能解析但内容被截断的 JSON —— 那是静默的错误结果。
  if start >= text.len or text[start] != '{':
    return -1
  var depth = 0
  var inString = false
  var escaped = false
  var i = start
  while i < text.len:
    let c = text[i]
    if inString:
      if escaped:
        escaped = false
      elif c == '\\':
        escaped = true
      elif c == '"':
        inString = false
    else:
      case c
      of '"': inString = true
      of '{': inc depth
      of '}':
        dec depth
        if depth == 0:
          return i
      else: discard
    inc i
  -1

proc stripFenceArtifacts(text: string): string =
  ## 去掉只剩围栏的行。
  ##
  ## 模型常把 JSON 包在 ```json ... ``` 里。信封被摘走之后,剩下两行孤立的
  ## 反引号,直接回给用户很难看,而它们并不是回答内容。
  var kept: seq[string] = @[]
  for line in text.splitLines():
    let trimmed = line.strip()
    if trimmed == "```" or trimmed.startsWith("```") and
        trimmed.len <= 8 and not trimmed.contains(' '):
      continue
    kept.add(line)
  kept.join("\n").strip()

proc lookupTool(declared: openArray[ToolDefinition], name: string): int =
  for i, tool in declared:
    if tool.name == name:
      return i
  -1

proc extractToolCalls*(text: string, declared: openArray[ToolDefinition],
                       idPrefix: string = DefaultToolCallIdPrefix):
    ToolCallExtraction =
  ## 从模型输出里分离工具调用。
  ##
  ## 未声明任何工具时**不解析** —— 我们没告诉模型工具的存在,那么形状相似的
  ## 内容只能是普通文本。
  ##
  ## 调用了未声明的工具时报 `TOOL_CALL_FAILED`:把它原样交给客户端会让客户端
  ## 去执行一个它没提供的工具。这属于模型行为异常,必须可见。
  result = initToolCallExtraction(text)
  if declared.len == 0 or text.len == 0:
    return

  var remaining = ""
  var cursor = 0
  var index = 0
  var i = 0

  while i < text.len:
    if text[i] != '{':
      inc i
      continue
    let closing = balancedObjectEnd(text, i)
    if closing < 0:
      # 没有配对的右括号,后面不可能再有完整对象。
      break
    let candidate = text[i .. closing]
    var node: JsonNode = nil
    try:
      node = parseJson(candidate)
    except CatchableError:
      node = nil

    if node == nil or node.kind != JObject or
        not node.hasKey(ToolCallEnvelopeKey):
      # 不是信封:跳过这个 `{` 本身继续找,不跳过整段 ——
      # 信封可能嵌在一个更大的非 JSON 文本里。
      inc i
      continue

    let envelope = node[ToolCallEnvelopeKey]
    if envelope.kind != JObject:
      raiseIsvikError(
        ecToolCallFailed,
        "Tool call envelope must be a JSON object",
        "key=" & ToolCallEnvelopeKey & " got=" & $envelope.kind
      )

    let name = envelope{"name"}.getStr("").strip()
    if name.len == 0:
      raiseIsvikError(
        ecToolCallFailed,
        "Tool call is missing a tool name",
        "key=" & ToolCallEnvelopeKey
      )
    if lookupTool(declared, name) < 0:
      var known: seq[string] = @[]
      for tool in declared:
        known.add(tool.name)
      raiseIsvikError(
        ecToolCallFailed,
        "The model called a tool that was not declared",
        "tool=" & name & " declared=" & known.join(",")
      )

    let argumentsNode =
      if envelope.hasKey("arguments"): envelope["arguments"] else: newJObject()
    if argumentsNode.kind != JObject:
      raiseIsvikError(
        ecToolCallFailed,
        "Tool call arguments must be a JSON object",
        "tool=" & name & " got=" & $argumentsNode.kind
      )

    inc index
    var call = initToolCall(idPrefix & $index, name, $argumentsNode,
                            argumentsNode)
    result.calls.add(call)
    result.hadCall = true

    remaining.add(text[cursor ..< i])
    cursor = closing + 1
    i = closing + 1

  if result.hadCall:
    remaining.add(text[cursor .. ^1])
    result.text = stripFenceArtifacts(remaining)

proc requiresToolCall*(choice: ToolChoice): bool =
  ## 该策略是否要求必须产生工具调用。
  choice.kind in {tckRequired, tckSpecific}

proc checkToolChoiceSatisfied*(extraction: ToolCallExtraction,
                               choice: ToolChoice) =
  ## 校验模型是否遵守了选择策略。
  ##
  ## `required` / `specific` 下模型仍然用文字回答时报 `TOOL_CALL_FAILED`,
  ## 而不是把那段文字当成正常回答返回 —— 后者会让客户端以为「模型认为不需要
  ## 调用工具」,而事实是它没有遵守约束。这是提示词方案的固有风险,
  ## 必须暴露出来。
  if not requiresToolCall(choice):
    return
  if not extraction.hadCall:
    raiseIsvikError(
      ecToolCallFailed,
      "The model did not call a tool although tool_choice required one",
      "toolChoice=" & $choice.kind &
        (if choice.name.len > 0: " tool=" & choice.name else: "")
    )
  if choice.kind == tckSpecific:
    for call in extraction.calls:
      if call.name == choice.name:
        return
    raiseIsvikError(
      ecToolCallFailed,
      "The model did not call the tool required by tool_choice",
      "required=" & choice.name
    )
