## OpenAI Chat Completions Adapter 测试(§20.5.12)
##
## 覆盖场景:Normal Request、Invalid Request、能力拒绝、Streaming、
## Cancellation、Errors。
##
## 断言的重点是**不失真**:
##
## ```text
## 被截断的回答不能报成 "stop"
## 未实现的能力不能静默忽略
## 推理内容不能混进正文
## ```

import std/[json, options, strutils, unittest]

import isvik/core/errors
import isvik/core/tools
import isvik/core/inference
import isvik/core/inference_events
import isvik/core/protocol
import isvik/protocol/openai_chat

let adapter = newOpenAiChatAdapter()

proc codeOf(body: proc()): IsvikErrorCode =
  result = ecServerError
  try:
    body()
  except IsvikError as e:
    result = e.code

proc minimalBody(): JsonNode =
  %*{
    "model": "gemma",
    "messages": [{"role": "user", "content": "hi"}]
  }

suite "OpenAI Chat:元信息与能力":

  test "协议名与版本前缀稳定":
    check adapter.protocolName() == "openai-chat"
    check adapter.apiVersion() == "/v1"

  test "只声明真正实现的能力":
    # 声明了却不实现比不声明更糟(§20.5.13 第 12 条)。
    let caps = adapter.capabilities()
    check pcStreaming in caps
    check pcMultiTurn in caps
    check pcCancellation in caps
    # 工具调用已通过提示词方案接入解码层。
    check pcToolCalling in caps
    # response_format 仍未接入解码,因此不声明。
    check pcStructuredOutput notin caps

suite "OpenAI Chat:请求解析":

  test "最小合法请求":
    let req = adapter.parseRequest(minimalBody())
    check req.model == "gemma"
    check req.messages.len == 1
    check req.messages[0].role == mrUser
    check req.messages[0].plainText() == "hi"
    check not req.stream
    # 协议没有设备字段,device 保持为空即交给 Runtime Policy。
    check req.device == ""

  test "developer 角色等同 system":
    var body = minimalBody()
    body["messages"] = %*[
      {"role": "developer", "content": "be brief"},
      {"role": "user", "content": "hi"}
    ]
    let req = adapter.parseRequest(body)
    check req.messages[0].role == mrSystem

  test "content 支持字符串与文本片段数组":
    var body = minimalBody()
    body["messages"] = %*[
      {"role": "user", "content": [
        {"type": "text", "text": "ab"},
        {"type": "text", "text": "cd"}
      ]}
    ]
    let req = adapter.parseRequest(body)
    check req.messages[0].plainText() == "abcd"

  test "非文本片段抛 NOT_IMPLEMENTED,不静默丢弃":
    # 丢掉图片会让客户端以为模型「看过了但没看懂」。
    var body = minimalBody()
    body["messages"] = %*[
      {"role": "user", "content": [
        {"type": "image_url", "image_url": {"url": "http://x/y.png"}}
      ]}
    ]
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecNotImplemented

  test "采样参数被映射,而不是被忽略":
    var body = minimalBody()
    body["temperature"] = %0.7
    body["top_p"] = %0.9
    body["seed"] = %42
    let req = adapter.parseRequest(body)
    check req.parameters.temperature == some(0.7)
    check req.parameters.topP == some(0.9)
    check req.parameters.seed == some(42)

  test "整数字面量对浮点参数合法":
    var body = minimalBody()
    body["temperature"] = %1
    check adapter.parseRequest(body).parameters.temperature == some(1.0)

  test "max_completion_tokens 优先于 max_tokens":
    var body = minimalBody()
    body["max_tokens"] = %16
    body["max_completion_tokens"] = %32
    check adapter.parseRequest(body).parameters.maxTokens == some(32)

  test "stop 接受单字符串与数组":
    var single = minimalBody()
    single["stop"] = %"END"
    check adapter.parseRequest(single).parameters.stopSequences == @["END"]
    var many = minimalBody()
    many["stop"] = %*["a", "b"]
    check adapter.parseRequest(many).parameters.stopSequences == @["a", "b"]

  test "缺 model 或 messages 报 INVALID_REQUEST":
    check codeOf(proc() =
      discard adapter.parseRequest(%*{"messages": [
        {"role": "user", "content": "x"}]})) == ecInvalidRequest
    check codeOf(proc() =
      discard adapter.parseRequest(%*{"model": "m", "messages": []})) ==
        ecInvalidRequest

  test "请求体不是对象时报 INVALID_REQUEST 而不是字段错误":
    # 形状错误与字段错误对客户端含义不同,不能混为一谈。
    check codeOf(proc() = discard adapter.parseRequest(%*[1, 2])) ==
      ecInvalidRequest
    check codeOf(proc() = discard adapter.parseRequest(nil)) ==
      ecInvalidRequest

  test "字段类型错误报 INVALID_PARAMETER 并指明字段":
    var body = minimalBody()
    body["temperature"] = %"hot"
    var detail = ""
    try:
      discard adapter.parseRequest(body)
    except IsvikError as e:
      check e.code == ecInvalidParameter
      detail = e.detail
    check detail.contains("temperature")

  test "既无 content 又无 tool_calls 时被拒绝":
    var body = minimalBody()
    body["messages"] = %*[{"role": "assistant", "content": newJNull()}]
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecInvalidRequest

  test "工具循环的第二轮能被解析":
    # content 为 null 而只带 tool_calls,是客户端回传模型上一次的调用。
    var body = minimalBody()
    body["messages"] = %*[
      {"role": "user", "content": "weather?"},
      {"role": "assistant", "content": newJNull(), "tool_calls": [
        {"id": "call_1", "type": "function",
         "function": {"name": "get_weather",
                      "arguments": "{\"city\":\"Oslo\"}"}}
      ]},
      {"role": "tool", "tool_call_id": "call_1", "content": "12C"}
    ]
    let req = adapter.parseRequest(body)
    check req.messages.len == 3
    check req.messages[1].role == mrAssistant
    check req.messages[1].content[0].kind == cpkToolUse
    check req.messages[1].content[0].toolCall.id == "call_1"
    # arguments 原样保留为字符串,解析交给统一模型。
    check req.messages[1].content[0].toolCall.argumentsText.contains("Oslo")
    check req.messages[2].role == mrTool
    check req.messages[2].content[0].kind == cpkToolResult
    check req.messages[2].content[0].toolResult.toolCallId == "call_1"
    check req.messages[2].content[0].toolResult.content == "12C"

  test "tool 消息缺 tool_call_id 被拒绝":
    # 它是工具结果与调用的唯一对应依据,缺了就无法关联。
    var body = minimalBody()
    body["messages"] = %*[{"role": "tool", "content": "12C"}]
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecInvalidRequest

  test "function 工具被解析成统一模型的工具":
    var body = minimalBody()
    body["tools"] = %*[
      {"type": "function", "function": {
        "name": "get_time", "description": "Return the time",
        "parameters": {"type": "object"}
      }}
    ]
    let req = adapter.parseRequest(body)
    check req.tools.len == 1
    check req.tools[0].name == "get_time"
    check req.tools[0].description == "Return the time"
    check req.tools[0].inputSchema != nil

  test "非 function 类型的工具抛 NOT_IMPLEMENTED":
    # 静默跳过会让客户端以为工具已注册,而模型从没见过它。
    var body = minimalBody()
    body["tools"] = %*[{"type": "code_interpreter"}]
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecNotImplemented

  test "tool_choice 的字符串与对象两种写法":
    proc choiceOf(value: JsonNode): ToolChoice =
      var body = minimalBody()
      body["tools"] = %*[
        {"type": "function", "function": {"name": "get_time"}}
      ]
      body["tool_choice"] = value
      adapter.parseRequest(body).toolChoice

    check choiceOf(%"auto").kind == tckAuto
    check choiceOf(%"none").kind == tckNone
    check choiceOf(%"required").kind == tckRequired
    let specific = choiceOf(%*{"type": "function",
                               "function": {"name": "get_time"}})
    check specific.kind == tckSpecific
    check specific.name == "get_time"

  test "未知 tool_choice 取值被拒绝":
    var body = minimalBody()
    body["tool_choice"] = %"maybe"
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecInvalidParameter

suite "OpenAI Chat:非流式响应":

  test "响应形状符合协议":
    var res = initUnifiedInferenceResult("gemma")
    res.device = "CPU"
    res.content = @[textPart("hello")]
    res.stopReason = srEndTurn
    res.usage = Usage(inputTokens: 3, outputTokens: 5)

    let node = adapter.formatResult(res)
    check node["object"].getStr == "chat.completion"
    check node["model"].getStr == "gemma"
    check node["choices"].len == 1
    let choice = node["choices"][0]
    check choice["message"]["role"].getStr == "assistant"
    check choice["message"]["content"].getStr == "hello"
    check choice["finish_reason"].getStr == "stop"
    check node["usage"]["prompt_tokens"].getInt == 3
    check node["usage"]["completion_tokens"].getInt == 5
    check node["usage"]["total_tokens"].getInt == 8

  test "实际设备如实回报在自有命名空间下":
    # 隐瞒设备等于让调用方无法知道推理跑在哪里(§27);
    # 放在 isvik 下则不与官方字段冲突。
    var res = initUnifiedInferenceResult("gemma")
    res.device = "NPU"
    let node = adapter.formatResult(res)
    check node["isvik"]["device"].getStr == "NPU"

  test "截断报 length,取消报 null,不都说成 stop":
    proc reasonOf(r: StopReason): JsonNode =
      var res = initUnifiedInferenceResult("m")
      res.stopReason = r
      adapter.formatResult(res)["choices"][0]["finish_reason"]

    check reasonOf(srEndTurn).getStr == "stop"
    check reasonOf(srMaxTokens).getStr == "length"
    check reasonOf(srToolUse).getStr == "tool_calls"
    # null 表示「没有正常结束」,恰好是事实。
    check reasonOf(srCancelled).kind == JNull
    check reasonOf(srError).kind == JNull
    check reasonOf(srUnspecified).kind == JNull

suite "OpenAI Chat:流式":

  test "首块只带角色,正文从后续块开始":
    let chunks = adapter.formatEvent(inferenceStarted("gemma", "CPU"))
    check chunks.len == 1
    let delta = chunks[0].data["choices"][0]["delta"]
    check delta["role"].getStr == "assistant"
    check not delta.hasKey("content")
    check chunks[0].data["model"].getStr == "gemma"

  test "内容增量映射为 delta.content":
    let chunks = adapter.formatEvent(contentDelta("wor"))
    check chunks.len == 1
    check chunks[0].data["choices"][0]["delta"]["content"].getStr == "wor"
    check not chunks[0].isDone

  test "推理增量被丢弃,不污染正文":
    # Chat Completions 没有推理字段。塞进 content 会让思考过程出现在回答里。
    check adapter.formatEvent(reasoningDelta("thinking")).len == 0

  test "usage 事件不产生块":
    check adapter.formatEvent(
      usageUpdated(Usage(inputTokens: 1, outputTokens: 2))).len == 0

  test "完成事件给出 finish_reason 并结束流":
    var res = initUnifiedInferenceResult("gemma")
    res.stopReason = srMaxTokens
    let chunks = adapter.formatEvent(inferenceCompleted(res))
    check chunks.len == 2
    check chunks[0].data["choices"][0]["finish_reason"].getStr == "length"
    check chunks[^1].isDone

  test "取消事件收尾但不伪造 stop":
    let chunks = adapter.formatEvent(inferenceCancelled("client gone"))
    check chunks.len == 2
    check chunks[0].data["choices"][0]["finish_reason"].kind == JNull
    check chunks[^1].isDone

  test "错误事件输出错误体并结束流":
    let chunks = adapter.formatEvent(
      inferenceError(ecInferenceFailed, "boom"))
    check chunks.len == 2
    check chunks[0].data["error"]["code"].getStr == "INFERENCE_FAILED"
    check chunks[^1].isDone

  test "身份字段由传输层补齐,已有的 model 不被覆盖":
    # Adapter 刻意无状态:并发的两个流不会互相覆盖身份字段。
    let started = adapter.formatEvent(inferenceStarted("real-model", "CPU"))[0]
    let stamped = started.withStreamIdentity("chatcmpl-1", 1700000000,
                                             "requested-model")
    check stamped.data["id"].getStr == "chatcmpl-1"
    check stamped.data["created"].getInt == 1700000000
    # 事件自带的模型名来自实际推理,比请求里的名字更可信。
    check stamped.data["model"].getStr == "real-model"

    let plain = adapter.formatEvent(contentDelta("x"))[0]
    check plain.withStreamIdentity("id-2", 5, "m").data["model"].getStr == "m"

  test "结束标记块不带数据也不崩溃":
    let done = doneChunk()
    check done.withStreamIdentity("id", 1, "m").isDone

suite "OpenAI Chat:工具调用响应":

  test "工具调用输出为 tool_calls,content 为 null":
    # OpenAI 客户端据此判断该去执行工具而不是把内容显示给用户。
    var res = initUnifiedInferenceResult("gemma")
    res.stopReason = srToolUse
    res.content = @[toolUsePart(initToolCall(
      "call_1", "get_time", "{\"tz\": \"UTC\"}"))]

    let message = adapter.formatResult(res)["choices"][0]["message"]
    check message["content"].kind == JNull
    check message["tool_calls"].len == 1
    let call = message["tool_calls"][0]
    check call["id"].getStr == "call_1"
    check call["type"].getStr == "function"
    check call["function"]["name"].getStr == "get_time"
    # arguments 是字符串而不是对象,这是 OpenAI 的约定。
    check call["function"]["arguments"].kind == JString
    check call["function"]["arguments"].getStr.contains("UTC")

  test "同时有文本与工具调用时两者都在":
    var res = initUnifiedInferenceResult("gemma")
    res.stopReason = srToolUse
    res.content = @[
      textPart("Checking."),
      toolUsePart(initToolCall("call_1", "get_time", "{}"))
    ]
    let message = adapter.formatResult(res)["choices"][0]["message"]
    check message["content"].getStr == "Checking."
    check message["tool_calls"].len == 1

  test "没有工具调用时不出现 tool_calls 字段":
    var res = initUnifiedInferenceResult("gemma")
    res.content = @[textPart("hi")]
    check not adapter.formatResult(res)["choices"][0]["message"]
      .hasKey("tool_calls")

  test "tool_use 的 finish_reason 是 tool_calls":
    var res = initUnifiedInferenceResult("gemma")
    res.stopReason = srToolUse
    check adapter.formatResult(res)["choices"][0]["finish_reason"]
      .getStr == "tool_calls"

  test "工具事件映射为 tool_calls 增量":
    let started = adapter.formatEvent(toolCallStarted("call_1", "get_time"))
    check started.len == 1
    let first = started[0].data["choices"][0]["delta"]["tool_calls"][0]
    check first["index"].getInt == 0
    check first["id"].getStr == "call_1"
    check first["function"]["name"].getStr == "get_time"

    let delta = adapter.formatEvent(toolCallDelta("call_1", "{\"tz\":"))
    check delta.len == 1
    let piece = delta[0].data["choices"][0]["delta"]["tool_calls"][0]
    # 增量块不重复 id 与 name:客户端按 index 累积,重复会被当成第二次调用。
    check not piece.hasKey("id")
    check piece["function"]["arguments"].getStr == "{\"tz\":"

suite "OpenAI Chat:错误映射":

  test "错误形状符合协议且保留 Isvik 错误码":
    let node = adapter.formatError(ecModelNotFound, "no such model")
    check node["error"]["message"].getStr == "no such model"
    check node["error"]["type"].getStr == "invalid_request_error"
    check node["error"]["code"].getStr == "MODEL_NOT_FOUND"

  test "5xx 归为 server_error":
    check adapter.formatError(ecInferenceFailed, "x")["error"]["type"]
      .getStr == "server_error"

  test "错误体不含 detail":
    # §22:detail 不进 API 响应。
    let node = adapter.formatError(ecModelNotFound, "message only")
    check not ($node).contains("detail")

  test "HTTP 状态沿用默认映射":
    check adapter.httpStatusFor(ecModelNotFound) == 404
    check adapter.httpStatusFor(ecInvalidRequest) == 400
    check adapter.httpStatusFor(ecStreamCancelled) == 499
    check adapter.httpStatusFor(ecNotImplemented) == 501

suite "OpenAI Chat:response_format 必须被解析后再拒绝":
  ## 这一组锁的是一个真实出现过的洞:`parseRequest` 不读 `response_format`
  ## 时,`requiredCapabilities` 看不到 `pcStructuredOutput`,入口校验放行,
  ## 请求被当成普通文本处理并返回 200 —— 客户端要 JSON,拿到散文,零报错。
  ##
  ## 只断言「返回 501」是不够的:那无法区分「解析了并按能力拒绝」与
  ## 「压根没解析、恰好别的地方报了 501」。因此同时断言解析结果本身。

  test "json_object 在入口被拒为 NOT_IMPLEMENTED":
    var body = minimalBody()
    body["response_format"] = %*{"type": "json_object"}
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecNotImplemented

  test "json_schema 在入口被拒为 NOT_IMPLEMENTED":
    var body = minimalBody()
    body["response_format"] = %*{
      "type": "json_schema",
      "json_schema": {
        "name": "city",
        "schema": {"type": "object",
                   "properties": {"city": {"type": "string"}}}
      }
    }
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecNotImplemented

  test "type text 是默认值,不构成结构化输出需求":
    var body = minimalBody()
    body["response_format"] = %*{"type": "text"}
    let req = adapter.parseRequest(body)
    check req.responseFormat.kind == rfkText
    check pcStructuredOutput notin requiredCapabilities(req)

  test "缺失或 null 都等于 text":
    let req = adapter.parseRequest(minimalBody())
    check req.responseFormat.kind == rfkText
    var body = minimalBody()
    body["response_format"] = newJNull()
    check adapter.parseRequest(body).responseFormat.kind == rfkText

  test "字段确实被读进统一模型,而不是被丢弃":
    # 绕开能力校验直接看解析结果:Native Adapter 声明了 pcStructuredOutput,
    # 但这里要验的是 OpenAI 侧的解析,所以用 requiredCapabilities 反推。
    var body = minimalBody()
    body["response_format"] = %*{"type": "json_object"}
    var captured = ecServerError
    try:
      discard adapter.parseRequest(body)
    except IsvikError as e:
      captured = e.code
      # 入口拒绝的原因必须指向 structured_output 这项能力,
      # 而不是别的偶然失败。
      check "structured_output" in e.detail
    check captured == ecNotImplemented

  test "未知 type 报 INVALID_PARAMETER 并列出允许值":
    var body = minimalBody()
    body["response_format"] = %*{"type": "yaml"}
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecInvalidParameter

  test "response_format 类型错报 INVALID_PARAMETER":
    var body = minimalBody()
    body["response_format"] = %"json_object"
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecInvalidParameter

  test "json_schema 缺 schema 报 INVALID_REQUEST":
    var body = minimalBody()
    body["response_format"] = %*{
      "type": "json_schema",
      "json_schema": {"name": "x"}
    }
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecInvalidRequest

  test "json_schema 缺 json_schema 包装报 INVALID_REQUEST":
    var body = minimalBody()
    body["response_format"] = %*{"type": "json_schema"}
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecInvalidRequest
