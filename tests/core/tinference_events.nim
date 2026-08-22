## Task 7 测试:§20.5.4 统一推理事件流与流累积器

import std/[unittest, json, options, sets, strutils]

import isvik/core/errors
import isvik/core/inference
import isvik/core/inference_events
import isvik/core/tools

suite "§20.5.4 九种事件":

  test "事件名与规范原文逐字一致":
    check $iekInferenceStarted == "InferenceStarted"
    check $iekContentDelta == "ContentDelta"
    check $iekReasoningDelta == "ReasoningDelta"
    check $iekToolCallStarted == "ToolCallStarted"
    check $iekToolCallDelta == "ToolCallDelta"
    check $iekUsageUpdated == "UsageUpdated"
    check $iekInferenceCompleted == "InferenceCompleted"
    check $iekInferenceCancelled == "InferenceCancelled"
    check $iekInferenceError == "InferenceError"

  test "事件总数为 9,与 §20.5.4 列表一致":
    var count = 0
    for _ in InferenceEventKind:
      inc count
    check count == 9
    check Section2054EventNames.len == 9

  test "§20.5.4 列出的每个事件都存在":
    var known = initHashSet[string]()
    for kind in InferenceEventKind:
      known.incl($kind)
    for name in Section2054EventNames:
      check known.contains(name)

  test "没有多余的自造事件":
    let allowed = Section2054EventNames.toHashSet
    for kind in InferenceEventKind:
      check allowed.contains($kind)

  test "终止事件恰好三种":
    check TerminalEventKinds.card == 3
    check iekInferenceCompleted in TerminalEventKinds
    check iekInferenceCancelled in TerminalEventKinds
    check iekInferenceError in TerminalEventKinds

  test "非终止事件不被误判为终止":
    check not inferenceStarted("m", "CPU").isTerminal
    check not contentDelta("x").isTerminal
    check not reasoningDelta("x").isTerminal
    check not toolCallStarted("c", "t").isTerminal
    check not toolCallDelta("c", "{}").isTerminal
    check not usageUpdated(Usage()).isTerminal

  test "终止事件被正确识别":
    check inferenceCompleted(initUnifiedInferenceResult("m")).isTerminal
    check inferenceCancelled("stop").isTerminal
    check inferenceError(ecInferenceFailed, "boom").isTerminal

suite "事件构造与字段":

  test "InferenceStarted 携带模型与实际设备":
    # 设备是 AUTO 决策的结果,客户端据此知道推理真正跑在哪里。
    let e = inferenceStarted("qwen", "NPU")
    check e.kind == iekInferenceStarted
    check e.startedModel == "qwen"
    check e.startedDevice == "NPU"

  test "ContentDelta 与 ReasoningDelta 共享文本字段但类型不同":
    let content = contentDelta("hello")
    let reasoning = reasoningDelta("thinking")
    check content.kind == iekContentDelta
    check content.textDelta == "hello"
    check reasoning.kind == iekReasoningDelta
    check reasoning.textDelta == "thinking"

  test "ToolCallStarted 携带 id 与工具名":
    let e = toolCallStarted("call_1", "get_weather")
    check e.toolCallId == "call_1"
    check e.toolName == "get_weather"
    check e.argumentsDelta == ""

  test "ToolCallDelta 携带 id 与参数增量":
    let e = toolCallDelta("call_1", "{\"city\":")
    check e.toolCallId == "call_1"
    check e.argumentsDelta == "{\"city\":"

  test "UsageUpdated 携带用量":
    let e = usageUpdated(Usage(inputTokens: 10, outputTokens: 3))
    check e.usage.inputTokens == 10
    check e.usage.totalTokens == 13

  test "InferenceCompleted 携带完整结果":
    var res = initUnifiedInferenceResult("qwen")
    res.stopReason = srEndTurn
    res.content = @[textPart("done")]
    let e = inferenceCompleted(res)
    check e.finalResult.model == "qwen"
    check e.finalResult.stopReason == srEndTurn

  test "InferenceCancelled 携带原因":
    check inferenceCancelled("client gone").cancelledReason == "client gone"

  test "InferenceError 携带错误码与消息":
    let e = inferenceError(ecNpuNotAvailable, "no NPU")
    check e.errorCode == ecNpuNotAvailable
    check e.errorMessage == "no NPU"

  test "从 IsvikError 构造错误事件时不携带 detail":
    # detail 可能含本地路径,而事件流直接流向外部客户端。
    let secret = "C:/Users/Someone/.isvik/models/private.xml"
    let err = newIsvikError(ecModelInvalid, "bad model", secret)
    let e = inferenceErrorFrom(err)
    check e.errorCode == ecModelInvalid
    check e.errorMessage == "bad model"
    check not e.toJson().contains(secret)

suite "事件序列化":

  test "每个事件都带 type 字段,取值为规范事件名":
    for e in [
      inferenceStarted("m", "CPU"),
      contentDelta("a"),
      reasoningDelta("b"),
      toolCallStarted("c", "t"),
      toolCallDelta("c", "{}"),
      usageUpdated(Usage()),
      inferenceCompleted(initUnifiedInferenceResult("m")),
      inferenceCancelled("r"),
      inferenceError(ecServerError, "e")
    ]:
      let node = e.toJsonNode()
      check node.hasKey("type")
      check node["type"].getStr == $e.kind

  test "所有事件都能生成合法 JSON":
    for e in [
      inferenceStarted("m", "CPU"),
      contentDelta("中文与 \"引号\" 与 \n 换行"),
      toolCallDelta("c", "{\"a\": 1}"),
      inferenceError(ecServerError, "boom")
    ]:
      let reparsed = parseJson(e.toJson())
      check reparsed["type"].getStr == $e.kind

  test "InferenceStarted 的 JSON 含 model 与 device":
    let node = inferenceStarted("qwen", "NPU").toJsonNode()
    check node["model"].getStr == "qwen"
    check node["device"].getStr == "NPU"

  test "ContentDelta 的 JSON 含 text":
    check contentDelta("hi").toJsonNode()["text"].getStr == "hi"

  test "ToolCallStarted 与 ToolCallDelta 的 JSON 字段不同":
    let started = toolCallStarted("c1", "get_time").toJsonNode()
    check started["tool_call_id"].getStr == "c1"
    check started["tool_name"].getStr == "get_time"
    check not started.hasKey("arguments_delta")

    let delta = toolCallDelta("c1", "{}").toJsonNode()
    check delta["tool_call_id"].getStr == "c1"
    check delta["arguments_delta"].getStr == "{}"
    check not delta.hasKey("tool_name")

  test "UsageUpdated 的 JSON 含三个计数":
    let node = usageUpdated(Usage(inputTokens: 5, outputTokens: 7)).toJsonNode()
    check node["usage"]["input_tokens"].getInt == 5
    check node["usage"]["output_tokens"].getInt == 7
    check node["usage"]["total_tokens"].getInt == 12

  test "InferenceError 的 JSON 采用 §22 的错误形状":
    # 客户端可以复用同一套错误解析逻辑。
    let node = inferenceError(ecNpuNotAvailable, "no NPU").toJsonNode()
    check node["error"]["code"].getStr == "NPU_NOT_AVAILABLE"
    check node["error"]["message"].getStr == "no NPU"

  test "结果序列化含内容片段与终止原因":
    var res = initUnifiedInferenceResult("qwen")
    res.device = "CPU"
    res.stopReason = srEndTurn
    res.content = @[reasoningPart("思考"), textPart("答案")]
    res.usage = Usage(inputTokens: 3, outputTokens: 4)

    let node = res.toJsonNode()
    check node["model"].getStr == "qwen"
    check node["device"].getStr == "CPU"
    check node["stop_reason"].getStr == "end_turn"
    check node["content"].len == 2
    check node["content"][0]["type"].getStr == "reasoning"
    check node["content"][1]["type"].getStr == "text"
    check node["usage"]["total_tokens"].getInt == 7

  test "工具调用片段的序列化":
    var call = initToolCall("c1", "get_time")
    call.appendArguments("{\"tz\":\"UTC\"}")
    call.finalizeArguments()

    var res = initUnifiedInferenceResult("m")
    res.content = @[toolUsePart(call)]
    let node = res.toJsonNode()
    check node["content"][0]["type"].getStr == "tool_use"
    check node["content"][0]["tool_call"]["id"].getStr == "c1"
    check node["content"][0]["tool_call"]["arguments"]["tz"].getStr == "UTC"

  test "未解析完成的工具调用如实输出原始文本":
    # 不伪造一个空对象假装参数已就绪。
    var call = initToolCall("c1", "t")
    call.appendArguments("{partial")
    let node = call.toJsonNode()
    check not node.hasKey("arguments")
    check node["arguments_text"].getStr == "{partial"

suite "流累积器:文本与推理":

  test "累积文本增量":
    let acc = collect([
      inferenceStarted("qwen", "CPU"),
      contentDelta("你"),
      contentDelta("好"),
      contentDelta("世界")
    ])
    check acc.accumulatedText == "你好世界"
    check not acc.isFinished

  test "文本与推理分别累积,互不混淆":
    let acc = collect([
      reasoningDelta("先分析"),
      contentDelta("回答:"),
      reasoningDelta("再确认"),
      contentDelta("42")
    ])
    check acc.accumulatedReasoning == "先分析再确认"
    check acc.accumulatedText == "回答:42"

  test "用量被累加":
    let acc = collect([
      usageUpdated(Usage(inputTokens: 10, outputTokens: 0)),
      usageUpdated(Usage(inputTokens: 0, outputTokens: 5)),
      usageUpdated(Usage(inputTokens: 0, outputTokens: 3))
    ])
    check acc.accumulatedUsage.inputTokens == 10
    check acc.accumulatedUsage.outputTokens == 8
    check acc.accumulatedUsage.totalTokens == 18

  test "记录模型与设备":
    let acc = collect([inferenceStarted("qwen", "NPU")])
    let res = acc.buildResult()
    check res.model == "qwen"
    check res.device == "NPU"

suite "流累积器:工具调用":

  test "累积工具调用参数并解析":
    let acc = collect([
      toolCallStarted("c1", "get_weather"),
      toolCallDelta("c1", "{\"city\":"),
      toolCallDelta("c1", " \"Beijing\"}")
    ])
    acc.finalizeToolCalls()

    let calls = acc.accumulatedToolCalls
    check calls.len == 1
    check calls[0].id == "c1"
    check calls[0].name == "get_weather"
    check calls[0].arguments["city"].getStr == "Beijing"

  test "并发多个工具调用按 id 分别累积":
    let acc = collect([
      toolCallStarted("c1", "get_time"),
      toolCallStarted("c2", "get_weather"),
      toolCallDelta("c1", "{\"tz\":\"UTC\"}"),
      toolCallDelta("c2", "{\"city\":\"Xi'an\"}")
    ])
    acc.finalizeToolCalls()

    let calls = acc.accumulatedToolCalls
    check calls.len == 2
    check calls[0].arguments["tz"].getStr == "UTC"
    check calls[1].arguments["city"].getStr == "Xi'an"

  test "重复的工具调用 id 抛 TOOL_CALL_FAILED":
    let acc = newStreamAccumulator()
    acc.feed(toolCallStarted("c1", "t"))
    var caught = false
    try:
      acc.feed(toolCallStarted("c1", "t2"))
    except IsvikError as e:
      caught = true
      check e.code == ecToolCallFailed
    check caught

  test "Delta 先于 Started 到达时抛错而不是猜":
    # 事件顺序错误说明产生方有 bug,静默创建一个工具调用会掩盖它。
    let acc = newStreamAccumulator()
    var caught = false
    try:
      acc.feed(toolCallDelta("unknown", "{}"))
    except IsvikError as e:
      caught = true
      check e.code == ecToolCallFailed
      check e.detail.contains("unknown")
    check caught

  test "工具调用进入聚合结果的内容片段":
    let acc = collect([
      toolCallStarted("c1", "get_time"),
      toolCallDelta("c1", "{}")
    ])
    acc.finalizeToolCalls()
    let res = acc.buildResult()
    check res.content.toolCalls.len == 1
    check res.content.toolCalls[0].id == "c1"

suite "流累积器:终止与错误":

  test "以 InferenceCompleted 结束时采用其携带的结果":
    # 那是产生方给出的权威版本,重新拼装会有偏差风险。
    var authoritative = initUnifiedInferenceResult("qwen")
    authoritative.stopReason = srEndTurn
    authoritative.content = @[textPart("权威结果")]
    authoritative.usage = Usage(inputTokens: 100, outputTokens: 200)

    let acc = collect([
      contentDelta("增量文本会被覆盖"),
      inferenceCompleted(authoritative)
    ])

    check acc.isFinished
    let res = acc.buildResult()
    check res.content.plainText == "权威结果"
    check res.usage.inputTokens == 100

  test "未以 Completed 结束时按累积内容构造结果":
    let acc = collect([
      reasoningDelta("想"),
      contentDelta("答"),
      inferenceCancelled("user stopped")
    ])
    let res = acc.buildResult()
    check res.stopReason == srCancelled
    check res.content.reasoningText == "想"
    check res.content.plainText == "答"

  test "取消后终止原因为 cancelled":
    let acc = collect([inferenceCancelled("stop button")])
    check acc.isFinished
    check acc.accumulatedStopReason == srCancelled
    check acc.accumulatedErrorMessage == "stop button"

  test "错误后记录错误码":
    let acc = collect([inferenceError(ecInferenceFailed, "kernel crashed")])
    check acc.isFinished
    check acc.accumulatedStopReason == srError
    check acc.accumulatedErrorCode.isSome
    check acc.accumulatedErrorCode.get == ecInferenceFailed
    check acc.accumulatedErrorMessage == "kernel crashed"

  test "终止后继续送入事件抛 INVALID_REQUEST":
    # 流终止后还有事件说明产生方有 bug,静默忽略会掩盖它。
    let acc = collect([inferenceCancelled("done")])
    var caught = false
    try:
      acc.feed(contentDelta("late"))
    except IsvikError as e:
      caught = true
      check e.code == ecInvalidRequest
    check caught

  test "requireSuccess 在错误结束时抛出原错误码":
    let acc = collect([inferenceError(ecNpuNotAvailable, "no NPU")])
    var caught = false
    var code: IsvikErrorCode
    try:
      acc.requireSuccess()
    except IsvikError as e:
      caught = true
      code = e.code
    check caught
    if caught:
      check code == ecNpuNotAvailable

  test "requireSuccess 在取消结束时抛 STREAM_CANCELLED":
    let acc = collect([inferenceCancelled("client disconnected")])
    var caught = false
    var code: IsvikErrorCode
    try:
      acc.requireSuccess()
    except IsvikError as e:
      caught = true
      code = e.code
    check caught
    if caught:
      check code == ecStreamCancelled

  test "requireSuccess 在正常结束时不抛异常":
    var res = initUnifiedInferenceResult("m")
    res.stopReason = srEndTurn
    let acc = collect([inferenceCompleted(res)])
    acc.requireSuccess()

suite "流式与非流式共用同一条路径":

  test "把完整事件流累积起来等价于一次非流式响应":
    # 这是累积器存在的核心理由:避免流式与非流式变成两套代码。
    var final = initUnifiedInferenceResult("qwen")
    final.device = "CPU"
    final.stopReason = srEndTurn
    final.content = @[textPart("你好世界")]
    final.usage = Usage(inputTokens: 5, outputTokens: 4)

    let acc = collect([
      inferenceStarted("qwen", "CPU"),
      contentDelta("你好"),
      contentDelta("世界"),
      usageUpdated(Usage(inputTokens: 5, outputTokens: 4)),
      inferenceCompleted(final)
    ])
    acc.requireSuccess()

    let res = acc.buildResult()
    check res.model == "qwen"
    check res.device == "CPU"
    check res.stopReason == srEndTurn
    check res.content.plainText == "你好世界"
    check res.usage.totalTokens == 9
    # 流式消费者看到的增量拼起来与非流式结果一致
    check acc.accumulatedText == "你好世界"

  test "空流可以构造出结果而不崩溃":
    let acc = newStreamAccumulator()
    let res = acc.buildResult()
    check res.content.len == 0
    check res.stopReason == srUnspecified
