## Task 7 测试:统一推理请求、Tool 模型、Structured Output、取消

import std/[unittest, json, options, strutils, tables]

import isvik/core/errors
import isvik/core/inference
import isvik/core/tools

suite "§20.5.3 统一请求包含规范要求的全部字段":

  test "十个字段齐备":
    # §20.5.3 列出:model / messages / input / parameters / device /
    # stream / tools / response_format / metadata / cancellation
    var req = initUnifiedInferenceRequest("qwen")
    req.messages = @[textMessage(mrUser, "hi")]
    req.input = ""
    req.device = "NPU"
    req.stream = true
    req.tools = @[initToolDefinition("get_time")]
    req.responseFormat = jsonObjectFormat()
    req.metadata["request_id"] = "abc"
    req.cancellation = newCancellationToken()

    check req.model == "qwen"
    check req.messages.len == 1
    check req.device == "NPU"
    check req.stream
    check req.tools.len == 1
    check req.responseFormat.kind == rfkJsonObject
    check req.metadata["request_id"] == "abc"
    check req.cancellation != nil
    check req.parameters.maxTokens.isNone

  test "默认请求是中性的":
    let req = initUnifiedInferenceRequest("m")
    check req.messages.len == 0
    check req.input == ""
    check req.device == ""          # 空 = 交给 Runtime Policy(AUTO)
    check not req.stream
    check req.tools.len == 0
    check req.toolChoice.kind == tckAuto
    check req.responseFormat.kind == rfkText
    check req.metadata.len == 0
    check req.cancellation == nil

suite "消息角色与内容片段":

  test "四种角色的字符串表示":
    check $mrSystem == "system"
    check $mrUser == "user"
    check $mrAssistant == "assistant"
    check $mrTool == "tool"

  test "四种内容片段类型":
    check $cpkText == "text"
    check $cpkReasoning == "reasoning"
    check $cpkToolUse == "tool_use"
    check $cpkToolResult == "tool_result"

  test "内容片段类型总数为 4,不含未实现的多模态类型":
    # 声明了却不支持比不声明更糟(§20.5.6)。
    var count = 0
    var names: seq[string] = @[]
    for k in ContentPartKind:
      inc count
      names.add($k)
    check count == 4
    check "image" notin names
    check "audio" notin names

  test "文本片段构造与读取":
    let part = textPart("hello")
    check part.kind == cpkText
    check part.text == "hello"

  test "工具调用片段承载 ToolCall":
    let part = toolUsePart(initToolCall("call_1", "get_time"))
    check part.kind == cpkToolUse
    check part.toolCall.id == "call_1"
    check part.toolCall.name == "get_time"

  test "工具结果片段承载 ToolResult":
    let part = toolResultPart(initToolResult("call_1", "12:00"))
    check part.kind == cpkToolResult
    check part.toolResult.toolCallId == "call_1"
    check part.toolResult.content == "12:00"
    check not part.toolResult.isError

  test "一条消息可同时包含文本与多个工具调用":
    let msg = initMessage(mrAssistant, @[
      textPart("让我查一下"),
      toolUsePart(initToolCall("c1", "get_time")),
      toolUsePart(initToolCall("c2", "get_weather"))
    ])
    check msg.content.len == 3
    check msg.plainText == "让我查一下"
    check msg.content.toolCalls.len == 2

  test "plainText 不包含 reasoning 内容":
    # 推理内容不属于对外回答的正文,混进来会暴露本不该暴露的内容。
    let parts = @[
      reasoningPart("先想一想:用户问的是时间"),
      textPart("现在是 12:00")
    ]
    check parts.plainText == "现在是 12:00"
    check parts.reasoningText == "先想一想:用户问的是时间"

  test "多个文本片段被顺序拼接":
    let parts = @[textPart("abc"), textPart("def"), textPart("ghi")]
    check parts.plainText == "abcdefghi"

suite "采样参数:未指定与显式取值必须可区分":

  test "默认全部为未指定":
    let p = initInferenceParameters()
    check p.maxTokens.isNone
    check p.temperature.isNone
    check p.topP.isNone
    check p.topK.isNone
    check p.seed.isNone
    check p.presencePenalty.isNone
    check p.frequencyPenalty.isNone
    check p.stopSequences.len == 0

  test "temperature 显式设为 0 与未指定不同":
    # temperature=0 是有意义的取值(贪心解码),不能与「没传」混为一谈。
    var p = initInferenceParameters()
    p.temperature = some(0.0)
    check p.temperature.isSome
    check p.temperature.get == 0.0

  test "合法参数通过校验":
    var p = initInferenceParameters()
    p.maxTokens = some(512)
    p.temperature = some(0.7)
    p.topP = some(0.9)
    p.topK = some(40)
    check validateParameters(p).isNone

  test "边界值被接受":
    var p = initInferenceParameters()
    p.temperature = some(0.0)
    check validateParameters(p).isNone
    p.temperature = some(2.0)
    check validateParameters(p).isNone
    p.topP = some(1.0)
    check validateParameters(p).isNone

  test "非法 max_tokens 被拒绝":
    var p = initInferenceParameters()
    p.maxTokens = some(0)
    check validateParameters(p).isSome
    p.maxTokens = some(-1)
    check validateParameters(p).isSome

  test "非法 temperature 被拒绝":
    var p = initInferenceParameters()
    p.temperature = some(-0.1)
    check validateParameters(p).isSome
    p.temperature = some(2.1)
    check validateParameters(p).isSome

  test "非法 top_p 被拒绝":
    var p = initInferenceParameters()
    p.topP = some(0.0)      # 必须 > 0
    check validateParameters(p).isSome
    p.topP = some(1.1)
    check validateParameters(p).isSome

  test "非法 top_k 被拒绝":
    var p = initInferenceParameters()
    p.topK = some(0)
    check validateParameters(p).isSome

  test "空停止序列被拒绝":
    var p = initInferenceParameters()
    p.stopSequences = @["ok", ""]
    check validateParameters(p).isSome

  test "校验失败原因是可读文本且含实际取值":
    var p = initInferenceParameters()
    p.temperature = some(5.0)
    let problem = validateParameters(p)
    check problem.isSome
    check problem.get.contains("temperature")
    check problem.get.contains("5.0")

suite "§20.5.6 Structured Output":

  test "三种输出格式":
    check $rfkText == "text"
    check $rfkJsonObject == "json_object"
    check $rfkJsonSchema == "json_schema"

  test "文本格式":
    check textFormat().kind == rfkText

  test "JSON 对象格式":
    check jsonObjectFormat().kind == rfkJsonObject

  test "JSON Schema 格式承载名称与 schema":
    let schema = %*{"type": "object", "properties": {"a": {"type": "string"}}}
    let format = jsonSchemaFormat("MySchema", schema)
    check format.kind == rfkJsonSchema
    check format.schemaName == "MySchema"
    check format.schema["type"].getStr == "object"

  test "json_schema 缺少 schema 时请求校验失败":
    var req = initUnifiedInferenceRequest("m")
    req.messages = @[textMessage(mrUser, "hi")]
    req.responseFormat = ResponseFormat(kind: rfkJsonSchema,
                                        schemaName: "X", schema: nil)
    let problem = validate(req)
    check problem.isSome
    check problem.get.contains("schema")

  test "schema 不是对象时请求校验失败":
    var req = initUnifiedInferenceRequest("m")
    req.messages = @[textMessage(mrUser, "hi")]
    req.responseFormat = ResponseFormat(kind: rfkJsonSchema,
                                        schemaName: "X",
                                        schema: %*[1, 2, 3])
    check validate(req).isSome

suite "§20.5.5 Tool 模型":

  test "工具声明":
    let tool = initToolDefinition("get_weather", "查询天气",
                                  %*{"type": "object"})
    check tool.name == "get_weather"
    check tool.description == "查询天气"
    check tool.inputSchema["type"].getStr == "object"

  test "无参数工具的 schema 可为 nil":
    let tool = initToolDefinition("ping")
    check tool.inputSchema == nil
    check validateToolDefinition(tool).isNone

  test "工具名为空被拒绝":
    check validateToolDefinition(initToolDefinition("")).isSome
    check validateToolDefinition(initToolDefinition("   ")).isSome

  test "工具名含非法字符被拒绝":
    # 工具名会进入协议 JSON 与模型提示,限制字符集避免转义与歧义。
    check validateToolDefinition(initToolDefinition("get weather")).isSome
    check validateToolDefinition(initToolDefinition("get.weather")).isSome
    check validateToolDefinition(initToolDefinition("get/weather")).isSome

  test "工具名允许字母数字下划线连字符":
    check validateToolDefinition(initToolDefinition("get_weather")).isNone
    check validateToolDefinition(initToolDefinition("get-weather-2")).isNone
    check validateToolDefinition(initToolDefinition("Tool123")).isNone

  test "schema 不是对象被拒绝":
    check validateToolDefinition(
      initToolDefinition("t", "", %*[1, 2])).isSome

  test "工具名重复被拒绝":
    # 模型按名字选工具,重名会让「调用哪个」变成不确定行为。
    let tools = @[
      initToolDefinition("get_time"),
      initToolDefinition("get_time")
    ]
    let problem = validateTools(tools)
    check problem.isSome
    check problem.get.contains("duplicate")

  test "不同名工具集合合法":
    check validateTools(@[
      initToolDefinition("a"),
      initToolDefinition("b"),
      initToolDefinition("c")
    ]).isNone

suite "工具选择策略":

  test "四种策略的字符串表示":
    check $tckAuto == "auto"
    check $tckNone == "none"
    check $tckRequired == "required"
    check $tckSpecific == "specific"

  test "auto 与 none 不需要工具":
    check validateToolChoice(autoToolChoice(), []).isNone
    check validateToolChoice(noToolChoice(), []).isNone

  test "required 需要至少一个工具":
    check validateToolChoice(requiredToolChoice(), []).isSome
    check validateToolChoice(requiredToolChoice(),
                             [initToolDefinition("a")]).isNone

  test "specific 必须指定名称":
    check validateToolChoice(ToolChoice(kind: tckSpecific, name: ""),
                             [initToolDefinition("a")]).isSome

  test "specific 引用未声明的工具被拒绝":
    let problem = validateToolChoice(specificToolChoice("nope"),
                                     [initToolDefinition("a")])
    check problem.isSome
    check problem.get.contains("undeclared")

  test "specific 引用已声明的工具合法":
    check validateToolChoice(specificToolChoice("a"),
                             [initToolDefinition("a")]).isNone

suite "流式工具调用参数累积":

  test "逐片累积后解析":
    var call = initToolCall("c1", "get_weather")
    call.appendArguments("{\"city\":")
    call.appendArguments(" \"Beijing\"")
    call.appendArguments("}")

    check call.argumentsText == "{\"city\": \"Beijing\"}"
    check not call.hasParsedArguments   # 尚未 finalize

    call.finalizeArguments()
    check call.hasParsedArguments
    check call.arguments["city"].getStr == "Beijing"

  test "累积过程中已解析结果被置空":
    # 中途的文本很可能不是合法 JSON,保留旧解析结果会造成
    # 「参数看起来完整但其实过期」的错觉。
    var call = initToolCall("c1", "t")
    call.appendArguments("{}")
    call.finalizeArguments()
    check call.hasParsedArguments

    call.appendArguments("extra")
    check not call.hasParsedArguments

  test "空参数被解析为空对象":
    var call = initToolCall("c1", "ping")
    call.finalizeArguments()
    check call.hasParsedArguments
    check call.arguments.kind == JObject
    check call.arguments.len == 0

  test "只有空白的参数也被解析为空对象":
    var call = initToolCall("c1", "ping")
    call.appendArguments("   \n  ")
    call.finalizeArguments()
    check call.arguments.len == 0

  test "非法 JSON 参数抛 TOOL_CALL_FAILED":
    # 模型给出了无法解析的参数,必须让调用方知道,不能静默当空参数继续。
    var call = initToolCall("c1", "get_weather")
    call.appendArguments("{not json")
    var caught = false
    var code: IsvikErrorCode
    try:
      call.finalizeArguments()
    except IsvikError as e:
      caught = true
      code = e.code
    check caught
    if caught:
      check code == ecToolCallFailed

  test "错误 detail 含工具名与调用 id,便于定位":
    var call = initToolCall("call_7", "search")
    call.appendArguments("[[[")
    try:
      call.finalizeArguments()
      check false
    except IsvikError as e:
      check e.detail.contains("call_7")
      check e.detail.contains("search")

suite "工具结果的错误标记":

  test "工具失败用标记位表达,不抛异常":
    # 工具失败不等于推理失败:模型通常需要看到错误内容以便重试。
    let res = initToolResult("c1", "connection timed out", isError = true)
    check res.isError
    check res.content == "connection timed out"

  test "成功结果默认非错误":
    check not initToolResult("c1", "ok").isError

suite "请求校验":

  test "合法请求通过":
    var req = initUnifiedInferenceRequest("qwen")
    req.messages = @[textMessage(mrUser, "hello")]
    check validate(req).isNone

  test "model 为空被拒绝":
    var req = initUnifiedInferenceRequest("")
    req.messages = @[textMessage(mrUser, "hi")]
    check validate(req).isSome

  test "既无 messages 也无 input 被拒绝":
    let req = initUnifiedInferenceRequest("m")
    let problem = validate(req)
    check problem.isSome
    check problem.get.contains("either messages or input")

  test "同时提供 messages 与 input 被拒绝":
    # 调用方意图不明,不猜测该用哪个。
    var req = initUnifiedInferenceRequest("m")
    req.messages = @[textMessage(mrUser, "hi")]
    req.input = "also this"
    check validate(req).isSome

  test "只有 input 的请求合法(embeddings 场景)":
    var req = initUnifiedInferenceRequest("bge")
    req.input = "some text to embed"
    check validate(req).isNone

  test "空内容的消息被拒绝":
    var req = initUnifiedInferenceRequest("m")
    req.messages = @[initMessage(mrUser, @[])]
    let problem = validate(req)
    check problem.isSome
    check problem.get.contains("no content")

  test "工具调用缺 id 被拒绝":
    var req = initUnifiedInferenceRequest("m")
    req.messages = @[initMessage(mrAssistant,
                                 @[toolUsePart(initToolCall("", "t"))])]
    check validate(req).isSome

  test "工具调用缺名称被拒绝":
    var req = initUnifiedInferenceRequest("m")
    req.messages = @[initMessage(mrAssistant,
                                 @[toolUsePart(initToolCall("c1", ""))])]
    check validate(req).isSome

  test "工具结果缺 tool_call_id 被拒绝":
    # 缺了它就无法把结果关联回调用。
    var req = initUnifiedInferenceRequest("m")
    req.messages = @[initMessage(mrTool,
                                 @[toolResultPart(initToolResult("", "x"))])]
    check validate(req).isSome

  test "requireValid 抛 INVALID_REQUEST":
    let req = initUnifiedInferenceRequest("")
    var caught = false
    var code: IsvikErrorCode
    try:
      req.requireValid()
    except IsvikError as e:
      caught = true
      code = e.code
    check caught
    if caught:
      check code == ecInvalidRequest

  test "requireValid 对合法请求不抛异常":
    var req = initUnifiedInferenceRequest("m")
    req.messages = @[textMessage(mrUser, "hi")]
    req.requireValid()

suite "取消令牌":

  test "新令牌未取消":
    let token = newCancellationToken()
    check not token.isCancelled
    check token.cancelReason == ""

  test "取消后状态与原因可读":
    let token = newCancellationToken()
    token.cancel("client disconnected")
    check token.isCancelled
    check token.cancelReason == "client disconnected"

  test "nil 令牌视为未取消,调用方无需判空":
    let token: CancellationToken = nil
    check not token.isCancelled
    check token.cancelReason == ""
    token.cancel("ignored")          # 不应崩溃
    token.throwIfCancelled()         # 不应抛异常

  test "重复取消保留首次原因":
    # 第一个原因才是真正触发取消的那个。
    let token = newCancellationToken()
    token.cancel("first")
    token.cancel("second")
    check token.cancelReason == "first"

  test "throwIfCancelled 抛 STREAM_CANCELLED":
    let token = newCancellationToken()
    token.cancel("user pressed stop")
    var caught = false
    var code: IsvikErrorCode
    try:
      token.throwIfCancelled()
    except IsvikError as e:
      caught = true
      code = e.code
      check e.detail.contains("user pressed stop")
    check caught
    if caught:
      check code == ecStreamCancelled

  test "未取消时 throwIfCancelled 不抛异常":
    newCancellationToken().throwIfCancelled()

suite "用量与终止原因":

  test "总数由输入输出计算,不单独存储":
    let usage = Usage(inputTokens: 10, outputTokens: 25)
    check usage.totalTokens == 35

  test "用量可累加":
    let a = Usage(inputTokens: 10, outputTokens: 5)
    let b = Usage(inputTokens: 0, outputTokens: 7)
    let sum = a + b
    check sum.inputTokens == 10
    check sum.outputTokens == 12
    check sum.totalTokens == 22

  test "七种终止原因":
    check $srUnspecified == "unspecified"
    check $srEndTurn == "end_turn"
    check $srMaxTokens == "max_tokens"
    check $srStopSequence == "stop_sequence"
    check $srToolUse == "tool_use"
    check $srCancelled == "cancelled"
    check $srError == "error"

  test "默认结果是中性的":
    let res = initUnifiedInferenceResult("m")
    check res.model == "m"
    check res.device == ""
    check res.content.len == 0
    check res.stopReason == srUnspecified
    check res.usage.totalTokens == 0
