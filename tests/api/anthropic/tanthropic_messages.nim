## Anthropic Messages Adapter 测试(§20.5.12)
##
## 与 OpenAI 用例的差异集中在三处结构性区别:顶层 system、必填 max_tokens、
## 具名流式事件。这三点各自都有独立断言 —— 它们是 Adapter 存在的理由。

import std/[json, options, strutils, unittest]

import isvik/core/errors
import isvik/core/inference
import isvik/core/inference_events
import isvik/core/protocol
import isvik/protocol/anthropic

let adapter = newAnthropicAdapter()

proc codeOf(body: proc()): IsvikErrorCode =
  result = ecServerError
  try:
    body()
  except IsvikError as e:
    result = e.code

proc minimalBody(): JsonNode =
  %*{
    "model": "gemma",
    "max_tokens": 64,
    "messages": [{"role": "user", "content": "hi"}]
  }

suite "Anthropic:元信息与能力":

  test "协议名与版本前缀稳定":
    check adapter.protocolName() == "anthropic"
    check adapter.apiVersion() == "/v1"

  test "只声明真正实现的能力":
    let caps = adapter.capabilities()
    check pcStreaming in caps
    check pcMultiTurn in caps
    check pcCancellation in caps
    # 有 thinking 块与 thinking_delta,推理内容能双向如实表达。
    check pcReasoning in caps
    # 工具调用已通过提示词方案接入解码层。
    check pcToolCalling in caps
    check pcStructuredOutput notin caps

suite "Anthropic:请求解析":

  test "最小合法请求":
    let req = adapter.parseRequest(minimalBody())
    check req.model == "gemma"
    check req.messages.len == 1
    check req.messages[0].role == mrUser
    check req.parameters.maxTokens == some(64)

  test "顶层 system 变成第一条 system 消息":
    # 这是与 OpenAI 最主要的结构差异,由 Adapter 在边界上消化(§20.5.3)。
    var body = minimalBody()
    body["system"] = %"be brief"
    let req = adapter.parseRequest(body)
    check req.messages.len == 2
    check req.messages[0].role == mrSystem
    check req.messages[0].plainText() == "be brief"
    check req.messages[1].role == mrUser

  test "system 也接受文本块数组":
    var body = minimalBody()
    body["system"] = %*[{"type": "text", "text": "a"},
                        {"type": "text", "text": "b"}]
    check adapter.parseRequest(body).messages[0].plainText() == "ab"

  test "空 system 不产生空消息":
    var body = minimalBody()
    body["system"] = %"   "
    check adapter.parseRequest(body).messages.len == 1

  test "messages 里出现 system 角色报错":
    # 接受它会让「system 该放哪」出现两种写法,而其中一种在官方 API 上无效。
    var body = minimalBody()
    body["messages"] = %*[{"role": "system", "content": "x"}]
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecInvalidParameter

  test "max_tokens 缺失报 INVALID_REQUEST 而不是替客户端选一个":
    # 替它选会让回答被截断,而客户端以为模型就是那么答的。
    var body = %*{
      "model": "gemma",
      "messages": [{"role": "user", "content": "hi"}]
    }
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecInvalidRequest

  test "top_k 被映射(OpenAI 没有这个字段)":
    var body = minimalBody()
    body["top_k"] = %40
    check adapter.parseRequest(body).parameters.topK == some(40)

  test "stop_sequences 接受单字符串与数组":
    var single = minimalBody()
    single["stop_sequences"] = %"END"
    check adapter.parseRequest(single).parameters.stopSequences == @["END"]
    var many = minimalBody()
    many["stop_sequences"] = %*["a", "b"]
    check adapter.parseRequest(many).parameters.stopSequences == @["a", "b"]

  test "thinking 块映射为 reasoning,不混进正文":
    var body = minimalBody()
    body["messages"] = %*[
      {"role": "assistant", "content": [
        {"type": "thinking", "thinking": "hidden"},
        {"type": "text", "text": "shown"}
      ]},
      {"role": "user", "content": "next"}
    ]
    let req = adapter.parseRequest(body)
    check req.messages[0].plainText() == "shown"
    check req.messages[0].content.len == 2

  test "未知内容块类型抛 NOT_IMPLEMENTED":
    var body = minimalBody()
    body["messages"] = %*[
      {"role": "user", "content": [{"type": "image", "source": {}}]}
    ]
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecNotImplemented

  test "请求体形状错误与字段类型错误被区分":
    check codeOf(proc() = discard adapter.parseRequest(%*"nope")) ==
      ecInvalidRequest
    var body = minimalBody()
    body["top_p"] = %"high"
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecInvalidParameter

suite "Anthropic:非流式响应":

  test "响应形状符合协议":
    var res = initUnifiedInferenceResult("gemma")
    res.device = "CPU"
    res.content = @[textPart("hello")]
    res.stopReason = srEndTurn
    res.usage = Usage(inputTokens: 3, outputTokens: 5)

    let node = adapter.formatResult(res)
    check node["type"].getStr == "message"
    check node["role"].getStr == "assistant"
    check node["content"][0]["type"].getStr == "text"
    check node["content"][0]["text"].getStr == "hello"
    check node["stop_reason"].getStr == "end_turn"
    check node["usage"]["input_tokens"].getInt == 3
    check node["usage"]["output_tokens"].getInt == 5
    # Anthropic 只报输入与输出,没有 total。
    check not node["usage"].hasKey("total_tokens")
    check node["isvik"]["device"].getStr == "CPU"

  test "空回答不产生空文本块":
    let node = adapter.formatResult(initUnifiedInferenceResult("m"))
    check node["content"].len == 0

  test "终止原因如实映射,取消为 null":
    proc reasonOf(r: StopReason): JsonNode =
      var res = initUnifiedInferenceResult("m")
      res.stopReason = r
      adapter.formatResult(res)["stop_reason"]

    check reasonOf(srEndTurn).getStr == "end_turn"
    check reasonOf(srMaxTokens).getStr == "max_tokens"
    check reasonOf(srStopSequence).getStr == "stop_sequence"
    check reasonOf(srToolUse).getStr == "tool_use"
    check reasonOf(srCancelled).kind == JNull
    check reasonOf(srError).kind == JNull

suite "Anthropic:流式事件序列":

  test "开始事件同时给出 message_start 与 content_block_start":
    # 官方 SDK 按状态机解析:少发 content_block_start 会直接抛错。
    let chunks = adapter.formatEvent(inferenceStarted("gemma", "CPU"))
    check chunks.len == 2
    check chunks[0].eventName == "message_start"
    check chunks[0].data["message"]["model"].getStr == "gemma"
    check chunks[1].eventName == "content_block_start"

  test "内容增量是 text_delta":
    let chunks = adapter.formatEvent(contentDelta("wor"))
    check chunks.len == 1
    check chunks[0].eventName == "content_block_delta"
    check chunks[0].data["delta"]["type"].getStr == "text_delta"
    check chunks[0].data["delta"]["text"].getStr == "wor"

  test "推理增量是 thinking_delta,不像 OpenAI 那样被丢弃":
    # Anthropic 有对应字段,因此可以如实单独输出。
    let chunks = adapter.formatEvent(reasoningDelta("hmm"))
    check chunks.len == 1
    check chunks[0].data["delta"]["type"].getStr == "thinking_delta"
    check chunks[0].data["delta"]["thinking"].getStr == "hmm"

  test "usage 事件不单独成块":
    # 官方流里没有「只带 usage」的事件,它随 message_delta 一起发。
    check adapter.formatEvent(
      usageUpdated(Usage(inputTokens: 1, outputTokens: 2))).len == 0

  test "完成事件把状态机收干净":
    var res = initUnifiedInferenceResult("gemma")
    res.stopReason = srMaxTokens
    res.usage = Usage(inputTokens: 7, outputTokens: 11)
    let chunks = adapter.formatEvent(inferenceCompleted(res))
    check chunks.len == 3
    check chunks[0].eventName == "content_block_stop"
    check chunks[1].eventName == "message_delta"
    check chunks[1].data["delta"]["stop_reason"].getStr == "max_tokens"
    check chunks[1].data["usage"]["output_tokens"].getInt == 11
    check chunks[2].eventName == "message_stop"

  test "取消也要收尾,否则客户端一直等 message_stop":
    let chunks = adapter.formatEvent(inferenceCancelled("client gone"))
    check chunks.len == 3
    check chunks[^1].eventName == "message_stop"
    check chunks[1].data["delta"]["stop_reason"].kind == JNull

  test "错误事件用 error 事件名并收尾":
    let chunks = adapter.formatEvent(
      inferenceError(ecInferenceFailed, "boom"))
    check chunks.len == 2
    check chunks[0].eventName == "error"
    check chunks[0].data["type"].getStr == "error"
    check chunks[^1].eventName == "message_stop"

suite "Anthropic:错误与状态映射":

  test "错误形状符合协议且保留 Isvik 错误码":
    let node = adapter.formatError(ecModelNotFound, "no such model")
    check node["type"].getStr == "error"
    check node["error"]["type"].getStr == "not_found_error"
    check node["error"]["message"].getStr == "no such model"
    check node["error"]["code"].getStr == "MODEL_NOT_FOUND"

  test "错误体不含 detail":
    check not ($adapter.formatError(ecModelNotFound, "m")).contains("detail")

  test "设备与 Backend 不可用映射为 529 overloaded":
    # 529 才是 Anthropic 客户端做退避的标准信号;503 会被当成一般性故障。
    for code in [ecDeviceNotAvailable, ecNpuNotAvailable, ecGpuNotAvailable,
                 ecBackendNotAvailable]:
      check adapter.httpStatusFor(code) == 529
    check adapter.formatError(ecNpuNotAvailable, "x")["error"]["type"]
      .getStr == "overloaded_error"

  test "其余错误码沿用默认映射":
    check adapter.httpStatusFor(ecModelNotFound) == 404
    check adapter.httpStatusFor(ecInvalidRequest) == 400
    check adapter.httpStatusFor(ecStreamCancelled) == 499
    check adapter.httpStatusFor(ecNotImplemented) == 501
    check adapter.httpStatusFor(ecInferenceFailed) == 500
