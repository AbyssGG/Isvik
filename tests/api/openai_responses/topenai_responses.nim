## OpenAI Responses API Adapter 测试(§20.5.12)
##
## Responses 不是 Chat Completions 换个路径,形状是重新设计过的。因此这里的
## 断言集中在那些**结构性差异**上:input 的两种形态、顶层 instructions、
## output 条目数组、status 的语义、具名流式事件。
##
## 最容易出的错是把 `status` 一律写成 `completed` —— 那会让客户端把被截断的
## 半截回答当成完整回答。

import std/[json, options, strutils, unittest]

import isvik/core/errors
import isvik/core/tools
import isvik/core/inference
import isvik/core/inference_events
import isvik/core/protocol
import isvik/protocol/openai_responses

let adapter = newOpenAiResponsesAdapter()

proc codeOf(body: proc()): IsvikErrorCode =
  result = ecServerError
  try:
    body()
  except IsvikError as e:
    result = e.code

suite "Responses:元信息与能力":

  test "协议名与版本前缀":
    check adapter.protocolName() == "openai-responses"
    check adapter.apiVersion() == "/v1"

  test "声明单条输入能力":
    # input 可以是一个裸字符串,那正是「单条原始输入」。
    let caps = adapter.capabilities()
    check pcSingleInput in caps
    check pcStreaming in caps
    check pcMultiTurn in caps
    check pcToolCalling in caps
    # text.format 未接入解码,因此不声明。
    check pcStructuredOutput notin caps

suite "Responses:input 的两种形态":

  test "裸字符串按一条 user 消息处理":
    let req = adapter.parseRequest(%*{"model": "gemma", "input": "hi"})
    check req.messages.len == 1
    check req.messages[0].role == mrUser
    check req.messages[0].plainText() == "hi"

  test "条目数组按顺序转成消息":
    let req = adapter.parseRequest(%*{
      "model": "gemma",
      "input": [
        {"type": "message", "role": "user", "content": "one"},
        {"type": "message", "role": "assistant", "content": "two"},
        {"type": "message", "role": "user", "content": "three"}
      ]
    })
    check req.messages.len == 3
    check req.messages[1].role == mrAssistant
    check req.messages[2].plainText() == "three"

  test "input_text 与 output_text 片段都被接受":
    # Responses 的片段类型名与 Chat Completions 不同。
    let req = adapter.parseRequest(%*{
      "model": "gemma",
      "input": [{"type": "message", "role": "user", "content": [
        {"type": "input_text", "text": "ab"},
        {"type": "output_text", "text": "cd"}
      ]}]
    })
    check req.messages[0].plainText() == "abcd"

  test "省略 type 时按 message 处理":
    let req = adapter.parseRequest(%*{
      "model": "gemma",
      "input": [{"role": "user", "content": "hi"}]
    })
    check req.messages[0].role == mrUser

  test "缺 input 或 input 为空都报 INVALID_REQUEST":
    check codeOf(proc() =
      discard adapter.parseRequest(%*{"model": "gemma"})) == ecInvalidRequest
    check codeOf(proc() =
      discard adapter.parseRequest(%*{"model": "gemma", "input": ""})) ==
        ecInvalidRequest
    check codeOf(proc() =
      discard adapter.parseRequest(%*{"model": "gemma", "input": []})) ==
        ecInvalidRequest

  test "未支持的条目类型抛 NOT_IMPLEMENTED":
    check codeOf(proc() = discard adapter.parseRequest(%*{
      "model": "gemma",
      "input": [{"type": "file_search_call"}]
    })) == ecNotImplemented

suite "Responses:顶层 instructions":

  test "instructions 变成第一条 system 消息":
    # 与 Anthropic 的顶层 system 同一处理方式:差异在 Adapter 边界消化。
    let req = adapter.parseRequest(%*{
      "model": "gemma",
      "instructions": "be brief",
      "input": "hi"
    })
    check req.messages.len == 2
    check req.messages[0].role == mrSystem
    check req.messages[0].plainText() == "be brief"
    check req.messages[1].role == mrUser

  test "空白 instructions 不产生空消息":
    let req = adapter.parseRequest(%*{
      "model": "gemma", "instructions": "   ", "input": "hi"
    })
    check req.messages.len == 1

suite "Responses:参数与工具":

  test "max_output_tokens 映射到统一模型的 maxTokens":
    let req = adapter.parseRequest(%*{
      "model": "gemma", "input": "hi", "max_output_tokens": 32
    })
    check req.parameters.maxTokens == some(32)

  test "扁平工具声明被解析":
    # Responses 的工具没有 Chat Completions 那层 function 包装。
    let req = adapter.parseRequest(%*{
      "model": "gemma", "input": "hi",
      "tools": [{
        "type": "function", "name": "get_time",
        "description": "Return the time",
        "parameters": {"type": "object"}
      }]
    })
    check req.tools.len == 1
    check req.tools[0].name == "get_time"
    check req.tools[0].inputSchema != nil

  test "function_call 与 function_call_output 条目能回传":
    let req = adapter.parseRequest(%*{
      "model": "gemma",
      "input": [
        {"type": "message", "role": "user", "content": "time?"},
        {"type": "function_call", "call_id": "call_1", "name": "get_time",
         "arguments": "{}"},
        {"type": "function_call_output", "call_id": "call_1",
         "output": "12:00"}
      ]
    })
    check req.messages.len == 3
    check req.messages[1].role == mrAssistant
    check req.messages[1].content[0].kind == cpkToolUse
    check req.messages[1].content[0].toolCall.id == "call_1"
    check req.messages[2].role == mrTool
    check req.messages[2].content[0].toolResult.content == "12:00"

  test "tool_choice 的三种字符串与对象形式":
    proc choiceOf(value: JsonNode): ToolChoice =
      adapter.parseRequest(%*{
        "model": "gemma", "input": "hi",
        "tools": [{"type": "function", "name": "get_time"}],
        "tool_choice": value
      }).toolChoice
    check choiceOf(%"auto").kind == tckAuto
    check choiceOf(%"none").kind == tckNone
    check choiceOf(%"required").kind == tckRequired
    let specific = choiceOf(%*{"type": "function", "name": "get_time"})
    check specific.kind == tckSpecific
    check specific.name == "get_time"

suite "Responses:拒绝有状态字段":

  test "previous_response_id 抛 NOT_IMPLEMENTED":
    # 静默忽略最危险:客户端以为上一轮上下文还在,而模型什么都不记得。
    check codeOf(proc() = discard adapter.parseRequest(%*{
      "model": "gemma", "input": "hi", "previous_response_id": "resp_1"
    })) == ecNotImplemented

  test "store: true 抛 NOT_IMPLEMENTED":
    check codeOf(proc() = discard adapter.parseRequest(%*{
      "model": "gemma", "input": "hi", "store": true
    })) == ecNotImplemented

  test "store: false 与无状态实现一致,被接受":
    let req = adapter.parseRequest(%*{
      "model": "gemma", "input": "hi", "store": false
    })
    check req.messages.len == 1

suite "Responses:响应形状":

  test "output 数组与 output_text 同时给出":
    var res = initUnifiedInferenceResult("gemma")
    res.device = "CPU"
    res.content = @[textPart("hello")]
    res.stopReason = srEndTurn
    res.usage = Usage(inputTokens: 3, outputTokens: 5)

    let node = adapter.formatResult(res)
    check node["object"].getStr == "response"
    check node["status"].getStr == "completed"
    check node["output"].len == 1
    check node["output"][0]["type"].getStr == "message"
    check node["output"][0]["content"][0]["type"].getStr == "output_text"
    check node["output"][0]["content"][0]["text"].getStr == "hello"
    # output_text 是官方的便利字段。
    check node["output_text"].getStr == "hello"
    check node["usage"]["input_tokens"].getInt == 3
    check node["usage"]["total_tokens"].getInt == 8
    check node["isvik"]["device"].getStr == "CPU"

  test "工具调用是并列的 function_call 条目":
    # 一次响应可以既说一句话又发起一个调用,两者不是嵌套关系。
    var res = initUnifiedInferenceResult("gemma")
    res.stopReason = srToolUse
    res.content = @[
      textPart("Checking."),
      toolUsePart(initToolCall("call_1", "get_time", "{\"tz\":\"UTC\"}"))
    ]
    let node = adapter.formatResult(res)
    check node["output"].len == 2
    check node["output"][0]["type"].getStr == "message"
    check node["output"][1]["type"].getStr == "function_call"
    check node["output"][1]["call_id"].getStr == "call_1"
    check node["output"][1]["name"].getStr == "get_time"
    # arguments 是字符串,与 Chat Completions 一致。
    check node["output"][1]["arguments"].kind == JString
    # output_text 只含文本,不把工具参数混进去。
    check node["output_text"].getStr == "Checking."

  test "status 如实反映终止原因":
    proc statusOf(reason: StopReason): string =
      var res = initUnifiedInferenceResult("m")
      res.stopReason = reason
      adapter.formatResult(res)["status"].getStr

    check statusOf(srEndTurn) == "completed"
    check statusOf(srToolUse) == "completed"
    # 被截断不是完成 —— 报 completed 会让半截回答看起来是完整的。
    check statusOf(srMaxTokens) == "incomplete"
    check statusOf(srCancelled) == "cancelled"
    check statusOf(srError) == "failed"

  test "incomplete 时说明原因":
    var res = initUnifiedInferenceResult("m")
    res.stopReason = srMaxTokens
    let node = adapter.formatResult(res)
    check node["incomplete_details"]["reason"].getStr == "max_output_tokens"

  test "正常完成时 incomplete_details 为 null":
    var res = initUnifiedInferenceResult("m")
    res.stopReason = srEndTurn
    check adapter.formatResult(res)["incomplete_details"].kind == JNull

suite "Responses:流式具名事件":

  test "开始事件给出 created 与 output_item.added":
    let chunks = adapter.formatEvent(inferenceStarted("gemma", "CPU"))
    check chunks.len == 2
    check chunks[0].eventName == "response.created"
    check chunks[0].data["response"]["model"].getStr == "gemma"
    check chunks[0].data["response"]["status"].getStr == "in_progress"
    check chunks[1].eventName == "response.output_item.added"

  test "文本增量是 output_text.delta":
    let chunks = adapter.formatEvent(contentDelta("wor"))
    check chunks.len == 1
    check chunks[0].eventName == "response.output_text.delta"
    check chunks[0].data["delta"].getStr == "wor"

  test "事件载荷自带 type 字段":
    # 客户端按 data.type 分派,不只依赖 SSE 的 event: 行。
    let chunks = adapter.formatEvent(contentDelta("x"))
    check chunks[0].data["type"].getStr == "response.output_text.delta"

  test "工具事件用 output_item.added 与 function_call_arguments.delta":
    let started = adapter.formatEvent(toolCallStarted("call_1", "get_time"))
    check started.len == 1
    check started[0].eventName == "response.output_item.added"
    check started[0].data["item"]["type"].getStr == "function_call"
    check started[0].data["item"]["call_id"].getStr == "call_1"

    let delta = adapter.formatEvent(toolCallDelta("call_1", "{\"tz\":"))
    check delta[0].eventName == "response.function_call_arguments.delta"
    check delta[0].data["delta"].getStr == "{\"tz\":"

  test "推理增量被丢弃,不污染 output_text":
    check adapter.formatEvent(reasoningDelta("hmm")).len == 0

  test "usage 事件不单独成块":
    check adapter.formatEvent(
      usageUpdated(Usage(inputTokens: 1, outputTokens: 2))).len == 0

  test "完成事件给出 completed 并结束流":
    var res = initUnifiedInferenceResult("gemma")
    res.stopReason = srEndTurn
    res.content = @[textPart("done")]
    res.usage = Usage(inputTokens: 2, outputTokens: 3)
    let chunks = adapter.formatEvent(inferenceCompleted(res))
    check chunks.len == 3
    check chunks[0].eventName == "response.output_item.done"
    check chunks[1].eventName == "response.completed"
    check chunks[1].data["response"]["status"].getStr == "completed"
    check chunks[1].data["response"]["output_text"].getStr == "done"
    check chunks[^1].isDone

  test "取消用专门的事件名,不复用 completed":
    let chunks = adapter.formatEvent(inferenceCancelled("client gone"))
    check chunks[0].eventName == "response.incomplete"
    check chunks[0].data["response"]["status"].getStr == "cancelled"
    check chunks[^1].isDone

  test "错误事件是 response.failed":
    let chunks = adapter.formatEvent(
      inferenceError(ecInferenceFailed, "boom"))
    check chunks[0].eventName == "response.failed"
    check chunks[0].data["response"]["error"]["code"].getStr ==
      "INFERENCE_FAILED"
    check chunks[^1].isDone

suite "Responses:错误映射":

  test "错误形状与 Chat Completions 一致,保留 Isvik 错误码":
    let node = adapter.formatError(ecModelNotFound, "no such model")
    check node["error"]["type"].getStr == "invalid_request_error"
    check node["error"]["code"].getStr == "MODEL_NOT_FOUND"

  test "错误体不含 detail":
    check not ($adapter.formatError(ecModelNotFound, "m")).contains("detail")

  test "HTTP 状态沿用默认映射":
    check adapter.httpStatusFor(ecModelNotFound) == 404
    check adapter.httpStatusFor(ecNotImplemented) == 501
    check adapter.httpStatusFor(ecStreamCancelled) == 499

suite "Responses:text.format 必须被解析后再拒绝":
  ## Responses 把结构化输出放在 `text.format`,Chat Completions 放在顶层
  ## `response_format`。位置不同但陷阱相同:不解析 → 入口校验看不到
  ## `pcStructuredOutput` → 请求被当成普通文本返回 200,零报错。

  proc bodyWith(format: JsonNode): JsonNode =
    result = %*{"model": "gemma", "input": "hi"}
    result["text"] = %*{"format": format}

  test "json_object 在入口被拒为 NOT_IMPLEMENTED":
    check codeOf(proc() =
      discard adapter.parseRequest(bodyWith(%*{"type": "json_object"}))) ==
      ecNotImplemented

  test "json_schema 在入口被拒,且原因指向 structured_output":
    let body = bodyWith(%*{
      "type": "json_schema",
      "name": "city",
      "schema": {"type": "object",
                 "properties": {"city": {"type": "string"}}}
    })
    var captured = ecServerError
    try:
      discard adapter.parseRequest(body)
    except IsvikError as e:
      captured = e.code
      check "structured_output" in e.detail
    check captured == ecNotImplemented

  test "Responses 的 name 与 schema 是扁平的,没有 json_schema 包装":
    # 按 Chat Completions 的形状写会缺 schema —— 报错而不是当成 text 放行。
    let body = bodyWith(%*{
      "type": "json_schema",
      "json_schema": {"name": "city", "schema": {"type": "object"}}
    })
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecInvalidRequest

  test "type text 与缺失 format 都等于 text":
    let req = adapter.parseRequest(bodyWith(%*{"type": "text"}))
    check req.responseFormat.kind == rfkText
    check pcStructuredOutput notin requiredCapabilities(req)

    var noFormat = %*{"model": "gemma", "input": "hi", "text": {}}
    check adapter.parseRequest(noFormat).responseFormat.kind == rfkText

    var noText = %*{"model": "gemma", "input": "hi"}
    check adapter.parseRequest(noText).responseFormat.kind == rfkText

  test "未知 format type 报 INVALID_PARAMETER":
    check codeOf(proc() =
      discard adapter.parseRequest(bodyWith(%*{"type": "yaml"}))) ==
      ecInvalidParameter

  test "text 字段类型错报 INVALID_PARAMETER":
    var body = %*{"model": "gemma", "input": "hi"}
    body["text"] = %"json"
    check codeOf(proc() = discard adapter.parseRequest(body)) ==
      ecInvalidParameter
