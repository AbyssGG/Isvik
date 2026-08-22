## 工具调用解码接入测试
##
## 提示词方案的固有风险是**误判**:把模型随手写的 JSON 当成真的工具调用。
## 因此这里的重点是两侧边界:
##
## ```text
## 该认出来的要认出来   信封嵌在解释文字里、包在围栏里、参数含 } 字符
## 不该认的绝不能认     普通 JSON、未声明工具、没声明过工具的请求
## ```

import std/[json, strutils, unittest]

import isvik/core/errors
import isvik/core/tools
import isvik/inference/tool_calling

let weather = initToolDefinition(
  "get_weather", "Return the weather",
  %*{"type": "object", "properties": {"city": {"type": "string"}}})
let clock = initToolDefinition("get_time", "Return the time", nil)
let toolSet = @[weather, clock]

proc envelope(name: string, arguments: string): string =
  "{\"" & ToolCallEnvelopeKey & "\": {\"name\": \"" & name &
    "\", \"arguments\": " & arguments & "}}"

proc codeOf(body: proc()): IsvikErrorCode =
  result = ecServerError
  try:
    body()
  except IsvikError as e:
    result = e.code

suite "指令渲染":

  test "列出工具名、说明与 schema":
    let text = renderToolInstructions(toolSet, autoToolChoice())
    check text.contains("get_weather")
    check text.contains("Return the weather")
    check text.contains("get_time")
    check text.contains(ToolCallEnvelopeKey)
    # 无参数工具的 schema 渲染为空对象而不是 nil 字面量。
    check not text.contains("nil")

  test "工具集为空时不提工具":
    # 否则模型可能凭空调用一个不存在的东西。
    check renderToolInstructions([], autoToolChoice()) == ""

  test "策略为 none 时不提工具":
    check renderToolInstructions(toolSet, noToolChoice()) == ""

  test "每种策略都写进指令里":
    # 只在代码里判断而不告诉模型,required 就形同虚设。
    check renderToolInstructions(toolSet, autoToolChoice())
      .contains("no tool is needed")
    check renderToolInstructions(toolSet, requiredToolChoice())
      .contains("must call one of the tools")
    let specific = renderToolInstructions(
      toolSet, specificToolChoice("get_time"))
    check specific.contains("must call the tool named")
    check specific.contains("get_time")

suite "信封识别":

  test "纯信封被认出来":
    let extraction = extractToolCalls(
      envelope("get_weather", "{\"city\": \"Oslo\"}"), toolSet)
    check extraction.hadCall
    check extraction.calls.len == 1
    check extraction.calls[0].name == "get_weather"
    check extraction.calls[0].arguments["city"].getStr == "Oslo"
    check extraction.calls[0].id.startsWith(DefaultToolCallIdPrefix)
    check extraction.text == ""

  test "信封前后的解释文字仍是正文":
    let text = "Let me check.\n" &
      envelope("get_time", "{}") & "\nOne moment."
    let extraction = extractToolCalls(text, toolSet)
    check extraction.hadCall
    check extraction.calls.len == 1
    check extraction.text.contains("Let me check.")
    check extraction.text.contains("One moment.")
    check not extraction.text.contains(ToolCallEnvelopeKey)

  test "包在 Markdown 围栏里也能认出,且围栏不留在正文里":
    let text = "```json\n" & envelope("get_time", "{}") & "\n```"
    let extraction = extractToolCalls(text, toolSet)
    check extraction.hadCall
    check extraction.text == ""

  test "参数里含右花括号字符时不被提前截断":
    # 单纯数括号会在错误位置收尾,得到一个能解析但内容被截断的 JSON。
    let extraction = extractToolCalls(
      envelope("get_weather", "{\"city\": \"a}b\"}"), toolSet)
    check extraction.calls.len == 1
    check extraction.calls[0].arguments["city"].getStr == "a}b"

  test "参数里含转义引号同样正确":
    let extraction = extractToolCalls(
      envelope("get_weather", "{\"city\": \"say \\\"hi\\\"\"}"), toolSet)
    check extraction.calls.len == 1
    check extraction.calls[0].arguments["city"].getStr == "say \"hi\""

  test "多个信封按出现顺序产生多个调用,id 各不相同":
    let text = envelope("get_time", "{}") & "\nand\n" &
      envelope("get_weather", "{\"city\": \"Oslo\"}")
    let extraction = extractToolCalls(text, toolSet)
    check extraction.calls.len == 2
    check extraction.calls[0].name == "get_time"
    check extraction.calls[1].name == "get_weather"
    check extraction.calls[0].id != extraction.calls[1].id

  test "缺 arguments 时视为空参数":
    let text = "{\"" & ToolCallEnvelopeKey & "\": {\"name\": \"get_time\"}}"
    let extraction = extractToolCalls(text, toolSet)
    check extraction.calls.len == 1
    check extraction.calls[0].arguments.kind == JObject
    check extraction.calls[0].arguments.len == 0

suite "不该被认成工具调用的输入":

  test "没声明工具时一律当普通文本":
    # 我们没告诉模型工具的存在,形状相似的内容只能是普通文本。
    let text = envelope("get_weather", "{\"city\": \"Oslo\"}")
    let extraction = extractToolCalls(text, [])
    check not extraction.hadCall
    check extraction.text == text

  test "普通 JSON 不会被误判":
    # 这是命名空间键存在的理由:通用形状会把模型写的示例当成真调用。
    for text in ["{\"name\": \"get_weather\", \"arguments\": {}}",
                 "{\"tool\": \"get_time\"}",
                 "Here is JSON: {\"a\": 1}",
                 "{ not json at all",
                 ""]:
      let extraction = extractToolCalls(text, toolSet)
      check not extraction.hadCall
      check extraction.text == text

  test "谈论工具的文字不触发调用":
    let text = "You could call get_weather with a city name."
    check not extractToolCalls(text, toolSet).hadCall

suite "异常的工具调用必须可见":

  test "调用未声明的工具报 TOOL_CALL_FAILED":
    # 原样交给客户端会让它去执行一个自己没提供的工具。
    let text = envelope("delete_everything", "{}")
    check codeOf(proc() = discard extractToolCalls(text, toolSet)) ==
      ecToolCallFailed

  test "缺工具名报 TOOL_CALL_FAILED":
    let text = "{\"" & ToolCallEnvelopeKey & "\": {\"arguments\": {}}}"
    check codeOf(proc() = discard extractToolCalls(text, toolSet)) ==
      ecToolCallFailed

  test "信封不是对象报 TOOL_CALL_FAILED":
    let text = "{\"" & ToolCallEnvelopeKey & "\": \"get_time\"}"
    check codeOf(proc() = discard extractToolCalls(text, toolSet)) ==
      ecToolCallFailed

  test "参数不是对象报 TOOL_CALL_FAILED":
    let text = envelope("get_time", "[1, 2]")
    check codeOf(proc() = discard extractToolCalls(text, toolSet)) ==
      ecToolCallFailed

suite "选择策略的遵守情况":

  test "auto 下不调用工具是合法的":
    let extraction = extractToolCalls("Plain answer.", toolSet)
    extraction.checkToolChoiceSatisfied(autoToolChoice())
    check true

  test "required 下没调用工具报 TOOL_CALL_FAILED":
    # 把那段文字当成正常回答会让客户端以为「模型认为不需要工具」,
    # 而事实是它没遵守约束。提示词方案的这个风险必须暴露。
    let extraction = extractToolCalls("Plain answer.", toolSet)
    check codeOf(proc() =
      extraction.checkToolChoiceSatisfied(requiredToolChoice())) ==
        ecToolCallFailed

  test "required 下调用了任意工具即满足":
    let extraction = extractToolCalls(envelope("get_time", "{}"), toolSet)
    extraction.checkToolChoiceSatisfied(requiredToolChoice())
    check true

  test "specific 下调用了别的工具报 TOOL_CALL_FAILED":
    let extraction = extractToolCalls(envelope("get_time", "{}"), toolSet)
    check codeOf(proc() =
      extraction.checkToolChoiceSatisfied(
        specificToolChoice("get_weather"))) == ecToolCallFailed

  test "specific 下调用了指定工具即满足":
    let extraction = extractToolCalls(
      envelope("get_weather", "{\"city\": \"Oslo\"}"), toolSet)
    extraction.checkToolChoiceSatisfied(specificToolChoice("get_weather"))
    check true

  test "requiresToolCall 只对 required 与 specific 为真":
    check not requiresToolCall(autoToolChoice())
    check not requiresToolCall(noToolChoice())
    check requiresToolCall(requiredToolChoice())
    check requiresToolCall(specificToolChoice("get_time"))

suite "历史重放":

  test "工具调用能还原成信封并被重新解析":
    # 多轮工具对话里,上一轮的调用必须以模型当初输出的形状回到提示词里。
    let original = extractToolCalls(
      envelope("get_weather", "{\"city\": \"Oslo\"}"), toolSet).calls[0]
    let replayed = renderToolCallEnvelope(original)
    let again = extractToolCalls(replayed, toolSet)
    check again.calls.len == 1
    check again.calls[0].name == original.name
    check again.calls[0].arguments["city"].getStr == "Oslo"

  test "参数只有文本时也能还原":
    var call = initToolCall("call_1", "get_weather", "{\"city\": \"Oslo\"}")
    check renderToolCallEnvelope(call).contains("Oslo")

  test "工具结果带来源标记,不伪装成普通用户发言":
    # 模型需要知道这是工具的输出。
    let text = renderToolResultText(
      initToolResult("call_1", "18C"), "get_weather")
    check text.contains(ToolResultEnvelopeKey)
    check text.contains("call_1")
    check text.contains("18C")
    check text.contains("get_weather")

  test "工具失败标记被保留":
    # 工具失败不等于推理失败,模型需要看到错误内容以便改用其它工具。
    let text = renderToolResultText(
      initToolResult("call_1", "timeout", isError = true))
    check text.contains("timeout")
    let node = parseJson(text)[ToolResultEnvelopeKey]
    check node["is_error"].getBool
