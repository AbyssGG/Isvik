## Task 7 测试:ProtocolAdapter 接口与 Isvik Native 适配器
##
## 重点验证两件事:
## 1. **JSON ↔ Unified 往返无损** —— 若某字段无法往返,说明统一模型有漏洞。
## 2. **未实现能力返回 Unsupported 而非静默忽略**(§20.5.13 第 12 条)。

import std/[unittest, json, options, strutils, tables]

import isvik/core/errors
import isvik/core/inference
import isvik/core/inference_events
import isvik/core/protocol
import isvik/core/tools
import isvik/protocol/native

type
  ## 一个能力受限的 Adapter,用于验证 Unsupported 行为。
  ## 定义在模块顶层,因为 Nim 的 method 分派要求类型模块级可见。
  MinimalAdapter = ref object of ProtocolAdapter

method protocolName(a: MinimalAdapter): string = "minimal"
method apiVersion(a: MinimalAdapter): string = "/v1"
method capabilities(a: MinimalAdapter): set[ProtocolCapability] =
  ## 只支持多轮对话,不支持流式、工具、结构化输出。
  {pcMultiTurn}

proc simpleRequest(): UnifiedInferenceRequest =
  var req = initUnifiedInferenceRequest("qwen")
  req.messages = @[textMessage(mrUser, "你好")]
  result = req

suite "Adapter 元信息":

  test "Native 协议标识与版本路径":
    let a = newNativeAdapter()
    check a.protocolName() == "isvik-native"
    check a.protocolName() == NativeProtocolName
    # §20.5.9 规定 Isvik Native 使用 /api/v1/
    check a.apiVersion() == "/api/v1"

  test "未实现任何方法的基类 Adapter 抛 NOT_IMPLEMENTED":
    let bare = ProtocolAdapter()
    var caught = false
    try:
      discard bare.protocolName()
    except IsvikError as e:
      caught = true
      check e.code == ecNotImplemented
    check caught

suite "能力声明(§20.5.13 第 12 条)":

  test "Native 声明支持全部七项能力":
    let caps = newNativeAdapter().capabilities()
    check pcStreaming in caps
    check pcToolCalling in caps
    check pcStructuredOutput in caps
    check pcReasoning in caps
    check pcMultiTurn in caps
    check pcSingleInput in caps
    check pcCancellation in caps

  test "supports 查询单项能力":
    let a = newNativeAdapter()
    check a.supports(pcStreaming)
    let m = MinimalAdapter()
    check m.supports(pcMultiTurn)
    check not m.supports(pcStreaming)

  test "requireCapability 对支持的能力不抛异常":
    newNativeAdapter().requireCapability(pcToolCalling)

  test "requireCapability 对不支持的能力抛 NOT_IMPLEMENTED":
    # 靠文档说「暂不支持」不够,运行时必须真的拒绝。
    let m = MinimalAdapter()
    var caught = false
    var code: IsvikErrorCode
    try:
      m.requireCapability(pcStreaming)
    except IsvikError as e:
      caught = true
      code = e.code
      check e.detail.contains("minimal")
      check e.detail.contains("streaming")
    check caught
    if caught:
      check code == ecNotImplemented

suite "请求能力推导":

  test "简单对话请求只需要 multi_turn":
    let needed = requiredCapabilities(simpleRequest())
    check needed == {pcMultiTurn}

  test "流式请求需要 streaming":
    var req = simpleRequest()
    req.stream = true
    check pcStreaming in requiredCapabilities(req)

  test "带工具的请求需要 tool_calling":
    var req = simpleRequest()
    req.tools = @[initToolDefinition("get_time")]
    check pcToolCalling in requiredCapabilities(req)

  test "非 auto 的工具选择也需要 tool_calling":
    var req = simpleRequest()
    req.toolChoice = noToolChoice()
    check pcToolCalling in requiredCapabilities(req)

  test "结构化输出请求需要 structured_output":
    var req = simpleRequest()
    req.responseFormat = jsonObjectFormat()
    check pcStructuredOutput in requiredCapabilities(req)

  test "含推理片段的请求需要 reasoning":
    var req = initUnifiedInferenceRequest("m")
    req.messages = @[initMessage(mrAssistant, @[reasoningPart("thinking")])]
    check pcReasoning in requiredCapabilities(req)

  test "只有 input 的请求需要 single_input":
    var req = initUnifiedInferenceRequest("bge")
    req.input = "embed me"
    let needed = requiredCapabilities(req)
    check pcSingleInput in needed
    check pcMultiTurn notin needed

  test "带取消令牌的请求需要 cancellation":
    var req = simpleRequest()
    req.cancellation = newCancellationToken()
    check pcCancellation in requiredCapabilities(req)

  test "Native 能处理任意合法请求":
    var req = simpleRequest()
    req.stream = true
    req.tools = @[initToolDefinition("t")]
    req.responseFormat = jsonObjectFormat()
    req.cancellation = newCancellationToken()
    newNativeAdapter().requireSupportedRequest(req)

  test "能力不足时 requireSupportedRequest 抛 NOT_IMPLEMENTED 并列出缺失项":
    var req = simpleRequest()
    req.stream = true
    req.tools = @[initToolDefinition("t")]

    var caught = false
    try:
      MinimalAdapter().requireSupportedRequest(req)
    except IsvikError as e:
      caught = true
      check e.code == ecNotImplemented
      check e.detail.contains("streaming")
      check e.detail.contains("tool_calling")
    check caught

  test "能力足够时不抛异常":
    MinimalAdapter().requireSupportedRequest(simpleRequest())

suite "Native 请求解析":

  test "最小请求":
    let body = %*{"model": "qwen", "messages": [
      {"role": "user", "content": "你好"}
    ]}
    let req = newNativeAdapter().parseRequest(body)
    check req.model == "qwen"
    check req.messages.len == 1
    check req.messages[0].role == mrUser
    check req.messages[0].plainText == "你好"

  test "content 支持字符串便捷形式":
    let body = %*{"model": "m", "messages": [{"role": "user", "content": "hi"}]}
    let req = newNativeAdapter().parseRequest(body)
    check req.messages[0].content.len == 1
    check req.messages[0].content[0].kind == cpkText

  test "content 支持片段数组完整形式":
    let body = %*{"model": "m", "messages": [{
      "role": "assistant",
      "content": [
        {"type": "reasoning", "text": "想一想"},
        {"type": "text", "text": "答案"}
      ]
    }]}
    let req = newNativeAdapter().parseRequest(body)
    check req.messages[0].content.len == 2
    check req.messages[0].content[0].kind == cpkReasoning
    check req.messages[0].content[1].kind == cpkText

  test "解析工具调用片段":
    let body = %*{"model": "m", "messages": [{
      "role": "assistant",
      "content": [{
        "type": "tool_use",
        "tool_call": {"id": "c1", "name": "get_time",
                      "arguments": {"tz": "UTC"}}
      }]
    }]}
    let req = newNativeAdapter().parseRequest(body)
    let call = req.messages[0].content[0].toolCall
    check call.id == "c1"
    check call.name == "get_time"
    check call.arguments["tz"].getStr == "UTC"

  test "解析工具结果片段":
    let body = %*{"model": "m", "messages": [{
      "role": "tool",
      "content": [{
        "type": "tool_result",
        "tool_result": {"tool_call_id": "c1", "content": "12:00",
                        "is_error": false}
      }]
    }]}
    let req = newNativeAdapter().parseRequest(body)
    check req.messages[0].content[0].toolResult.toolCallId == "c1"

  test "解析采样参数":
    let body = %*{
      "model": "m",
      "messages": [{"role": "user", "content": "hi"}],
      "parameters": {
        "max_tokens": 256, "temperature": 0.7, "top_p": 0.9,
        "top_k": 40, "seed": 42,
        "stop_sequences": ["<|end|>", "STOP"]
      }
    }
    let req = newNativeAdapter().parseRequest(body)
    check req.parameters.maxTokens.get == 256
    check req.parameters.temperature.get == 0.7
    check req.parameters.topP.get == 0.9
    check req.parameters.topK.get == 40
    check req.parameters.seed.get == 42
    check req.parameters.stopSequences == @["<|end|>", "STOP"]

  test "未提供的参数保持为未指定":
    let body = %*{"model": "m", "messages": [{"role": "user", "content": "hi"}]}
    let req = newNativeAdapter().parseRequest(body)
    check req.parameters.maxTokens.isNone
    check req.parameters.temperature.isNone

  test "整数字面量可用于浮点参数":
    let body = %*{
      "model": "m", "messages": [{"role": "user", "content": "hi"}],
      "parameters": {"temperature": 1}
    }
    let req = newNativeAdapter().parseRequest(body)
    check req.parameters.temperature.get == 1.0

  test "null 视为未指定":
    let body = %*{
      "model": "m", "messages": [{"role": "user", "content": "hi"}],
      "parameters": {"temperature": nil, "max_tokens": nil}
    }
    let req = newNativeAdapter().parseRequest(body)
    check req.parameters.temperature.isNone
    check req.parameters.maxTokens.isNone

  test "解析工具声明与选择策略":
    let body = %*{
      "model": "m",
      "messages": [{"role": "user", "content": "hi"}],
      "tools": [{
        "name": "get_weather",
        "description": "查天气",
        "input_schema": {"type": "object"}
      }],
      "tool_choice": {"kind": "specific", "name": "get_weather"}
    }
    let req = newNativeAdapter().parseRequest(body)
    check req.tools.len == 1
    check req.tools[0].name == "get_weather"
    check req.toolChoice.kind == tckSpecific
    check req.toolChoice.name == "get_weather"

  test "解析 response_format 的三种形式":
    let a = newNativeAdapter()
    let base = %*{"model": "m", "messages": [{"role": "user", "content": "hi"}]}

    var b1 = base.copy()
    b1["response_format"] = %*{"kind": "text"}
    check a.parseRequest(b1).responseFormat.kind == rfkText

    var b2 = base.copy()
    b2["response_format"] = %*{"kind": "json_object"}
    check a.parseRequest(b2).responseFormat.kind == rfkJsonObject

    var b3 = base.copy()
    b3["response_format"] = %*{
      "kind": "json_schema", "name": "S",
      "schema": {"type": "object"}
    }
    let format = a.parseRequest(b3).responseFormat
    check format.kind == rfkJsonSchema
    check format.schemaName == "S"

  test "解析 metadata 与 device 与 stream":
    let body = %*{
      "model": "m",
      "messages": [{"role": "user", "content": "hi"}],
      "device": "NPU",
      "stream": true,
      "metadata": {"request_id": "r-1", "client": "trae"}
    }
    let req = newNativeAdapter().parseRequest(body)
    check req.device == "NPU"
    check req.stream
    check req.metadata["request_id"] == "r-1"
    check req.metadata["client"] == "trae"

suite "Native 解析错误处理":

  test "请求体非对象抛 INVALID_REQUEST":
    let a = newNativeAdapter()
    for body in [%*[1, 2, 3], %*"string", %*42]:
      var caught = false
      try:
        discard a.parseRequest(body)
      except IsvikError as e:
        caught = true
        check e.code == ecInvalidRequest
      check caught

  test "nil 请求体抛 INVALID_REQUEST":
    var caught = false
    try:
      discard newNativeAdapter().parseRequest(nil)
    except IsvikError as e:
      caught = true
      check e.code == ecInvalidRequest
    check caught

  test "字段类型错误抛 INVALID_PARAMETER 并指明字段与期望类型":
    # 与配置模块一致:字段存在而类型错必须报错,不静默忽略。
    var caught = false
    try:
      discard newNativeAdapter().parseRequest(%*{
        "model": "m",
        "messages": [{"role": "user", "content": "hi"}],
        "parameters": {"max_tokens": "many"}
      })
    except IsvikError as e:
      caught = true
      check e.code == ecInvalidParameter
      check e.detail.contains("parameters.max_tokens")
      check e.detail.contains("expected=integer")
      check e.detail.contains("got=string")
    check caught

  test "model 类型错误被指出":
    var caught = false
    try:
      discard newNativeAdapter().parseRequest(%*{"model": 42})
    except IsvikError as e:
      caught = true
      check e.detail.contains("field=model")
    check caught

  test "messages 不是数组被指出":
    var caught = false
    try:
      discard newNativeAdapter().parseRequest(%*{
        "model": "m", "messages": "not an array"})
    except IsvikError as e:
      caught = true
      check e.code == ecInvalidParameter
      check e.detail.contains("field=messages")
    check caught

  test "嵌套字段路径出现在错误信息中":
    var caught = false
    try:
      discard newNativeAdapter().parseRequest(%*{
        "model": "m",
        "messages": [{"role": "user", "content": [{"type": "text", "text": 1}]}]
      })
    except IsvikError as e:
      caught = true
      check e.detail.contains("messages[0].content[0].text")
    check caught

  test "未知角色抛 INVALID_PARAMETER 并列出合法取值":
    var caught = false
    try:
      discard newNativeAdapter().parseRequest(%*{
        "model": "m", "messages": [{"role": "wizard", "content": "hi"}]})
    except IsvikError as e:
      caught = true
      check e.code == ecInvalidParameter
      check e.detail.contains("wizard")
      check e.detail.contains("user")
    check caught

  test "未知内容片段类型抛 NOT_IMPLEMENTED 而不是静默丢弃":
    # 客户端显然想表达某种内容,忽略它会让请求语义悄悄改变。
    var caught = false
    var code: IsvikErrorCode
    try:
      discard newNativeAdapter().parseRequest(%*{
        "model": "m",
        "messages": [{"role": "user",
                      "content": [{"type": "image", "url": "x.png"}]}]
      })
    except IsvikError as e:
      caught = true
      code = e.code
      check e.detail.contains("image")
    check caught
    if caught:
      check code == ecNotImplemented

  test "tool_use 缺 tool_call 对象抛 INVALID_REQUEST":
    var caught = false
    try:
      discard newNativeAdapter().parseRequest(%*{
        "model": "m",
        "messages": [{"role": "assistant",
                      "content": [{"type": "tool_use"}]}]
      })
    except IsvikError as e:
      caught = true
      check e.code == ecInvalidRequest
    check caught

  test "json_schema 缺 schema 抛 INVALID_REQUEST":
    var caught = false
    try:
      discard newNativeAdapter().parseRequest(%*{
        "model": "m",
        "messages": [{"role": "user", "content": "hi"}],
        "response_format": {"kind": "json_schema", "name": "S"}
      })
    except IsvikError as e:
      caught = true
      check e.code == ecInvalidRequest
    check caught

  test "解析后自动执行请求校验":
    # 参数越界在解析阶段就被拦住,不会进入 Core。
    var caught = false
    try:
      discard newNativeAdapter().parseRequest(%*{
        "model": "m",
        "messages": [{"role": "user", "content": "hi"}],
        "parameters": {"temperature": 9.0}
      })
    except IsvikError as e:
      caught = true
      check e.code in {ecInvalidRequest, ecInvalidParameter}
    check caught

  test "缺少 model 被校验拦住":
    var caught = false
    try:
      discard newNativeAdapter().parseRequest(%*{
        "messages": [{"role": "user", "content": "hi"}]})
    except IsvikError as e:
      caught = true
      check e.code == ecInvalidRequest
    check caught

suite "JSON ↔ Unified 往返无损":

  test "简单请求往返":
    let a = newNativeAdapter()
    let original = %*{"model": "qwen", "messages": [
      {"role": "user", "content": [{"type": "text", "text": "你好"}]}
    ]}
    let req = a.parseRequest(original)
    let roundTripped = req.toJsonNode()
    check roundTripped == original

  test "完整请求往返:所有字段无丢失":
    # 若某字段无法往返,说明统一模型有表达漏洞。
    let a = newNativeAdapter()
    let original = %*{
      "model": "qwen-7b",
      "messages": [
        {"role": "system", "content": [{"type": "text", "text": "你是助手"}]},
        {"role": "user", "content": [{"type": "text", "text": "北京天气?"}]},
        {"role": "assistant", "content": [
          {"type": "reasoning", "text": "需要调用工具"},
          {"type": "tool_use", "tool_call": {
            "id": "call_1", "name": "get_weather",
            "arguments": {"city": "Beijing"}
          }}
        ]},
        {"role": "tool", "content": [
          {"type": "tool_result", "tool_result": {
            "tool_call_id": "call_1", "content": "晴 25C", "is_error": false
          }}
        ]}
      ],
      "device": "NPU",
      "stream": true,
      "parameters": {
        "max_tokens": 512,
        "temperature": 0.7,
        "top_p": 0.95,
        "top_k": 40,
        "seed": 1234,
        "presence_penalty": 0.1,
        "frequency_penalty": 0.2,
        "stop_sequences": ["<|im_end|>"]
      },
      "tools": [{
        "name": "get_weather",
        "description": "查询天气",
        "input_schema": {
          "type": "object",
          "properties": {"city": {"type": "string"}},
          "required": ["city"]
        }
      }],
      "tool_choice": {"kind": "specific", "name": "get_weather"},
      "response_format": {
        "kind": "json_schema",
        "name": "WeatherReply",
        "schema": {"type": "object", "properties": {"t": {"type": "number"}}}
      },
      "metadata": {"request_id": "req-42"}
    }

    let req = a.parseRequest(original)
    let roundTripped = req.toJsonNode()
    check roundTripped == original

  test "两次往返稳定(幂等)":
    let a = newNativeAdapter()
    let original = %*{
      "model": "m",
      "messages": [{"role": "user", "content": [{"type": "text", "text": "x"}]}],
      "parameters": {"temperature": 0.5}
    }
    let once = a.parseRequest(original).toJsonNode()
    let twice = a.parseRequest(once).toJsonNode()
    check once == twice

  test "未指定的参数不被补成默认值":
    # 把未指定补成默认值输出,再解析回来「未指定」就变成了「显式指定」。
    let a = newNativeAdapter()
    let body = %*{"model": "m", "messages": [
      {"role": "user", "content": [{"type": "text", "text": "x"}]}]}
    let node = a.parseRequest(body).toJsonNode()
    check not node.hasKey("parameters")
    check not node.hasKey("temperature")

  test "默认值字段不出现在输出中":
    let a = newNativeAdapter()
    let node = a.parseRequest(%*{"model": "m", "messages": [
      {"role": "user", "content": [{"type": "text", "text": "x"}]}]}).toJsonNode()
    check not node.hasKey("stream")          # false 不输出
    check not node.hasKey("device")          # 空不输出
    check not node.hasKey("tool_choice")     # auto 不输出
    check not node.hasKey("response_format") # text 不输出
    check not node.hasKey("metadata")
    check not node.hasKey("tools")
    check not node.hasKey("input")

  test "temperature 为 0 能往返(不被当作未指定)":
    let a = newNativeAdapter()
    let original = %*{
      "model": "m",
      "messages": [{"role": "user", "content": [{"type": "text", "text": "x"}]}],
      "parameters": {"temperature": 0.0}
    }
    let node = a.parseRequest(original).toJsonNode()
    check node["parameters"].hasKey("temperature")
    check node["parameters"]["temperature"].getFloat == 0.0

  test "只有 input 的请求往返":
    let a = newNativeAdapter()
    let original = %*{"model": "bge", "input": "embed this"}
    check a.parseRequest(original).toJsonNode() == original

suite "Native 响应与事件格式化":

  test "非流式响应就是统一结果本身":
    var res = initUnifiedInferenceResult("qwen")
    res.device = "CPU"
    res.stopReason = srEndTurn
    res.content = @[textPart("答案")]
    res.usage = Usage(inputTokens: 3, outputTokens: 2)

    let node = newNativeAdapter().formatResult(res)
    check node["model"].getStr == "qwen"
    check node["device"].getStr == "CPU"
    check node["stop_reason"].getStr == "end_turn"
    check node["content"][0]["text"].getStr == "答案"
    check node["usage"]["total_tokens"].getInt == 5

  test "每条事件产生一个块,事件名与 type 一致":
    let a = newNativeAdapter()
    let chunks = a.formatEvent(contentDelta("hi"))
    check chunks.len == 1
    check chunks[0].eventName == "ContentDelta"
    check chunks[0].data["type"].getStr == "ContentDelta"
    check chunks[0].data["text"].getStr == "hi"
    check not chunks[0].isDone

  test "终止事件额外产生 done 块":
    let a = newNativeAdapter()
    let chunks = a.formatEvent(inferenceCompleted(initUnifiedInferenceResult("m")))
    check chunks.len == 2
    check chunks[0].eventName == "InferenceCompleted"
    check chunks[1].isDone

  test "取消与错误事件也产生 done 块":
    let a = newNativeAdapter()
    check a.formatEvent(inferenceCancelled("stop"))[^1].isDone
    check a.formatEvent(inferenceError(ecServerError, "e"))[^1].isDone

  test "九种事件都能被格式化":
    let a = newNativeAdapter()
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
      let chunks = a.formatEvent(e)
      check chunks.len >= 1
      check chunks[0].data != nil

  test "错误响应采用 §22 形状":
    let node = newNativeAdapter().formatError(ecNpuNotAvailable, "no NPU here")
    check node["error"]["code"].getStr == "NPU_NOT_AVAILABLE"
    check node["error"]["message"].getStr == "no NPU here"
    check node["error"].len == 2      # 不含 detail

  test "流式块不含 SSE 物理格式":
    # SSE 的 event: / data: 前缀属于 HTTP 传输层,由 server 拼装。
    let chunk = newNativeAdapter().formatEvent(contentDelta("x"))[0]
    check not chunk.eventName.contains("event:")
    check not ($chunk.data).contains("data:")

suite "错误码到 HTTP 状态码映射":

  test "所有错误码都有映射":
    for code in IsvikErrorCode:
      let status = defaultHttpStatusFor(code)
      check status >= 400
      check status < 600

  test "调用方可修正的问题归 4xx":
    check defaultHttpStatusFor(ecInvalidRequest) == 400
    check defaultHttpStatusFor(ecInvalidParameter) == 400
    check defaultHttpStatusFor(ecModelNotFound) == 404
    check defaultHttpStatusFor(ecToolCallFailed) == 400

  test "设备不可用归 503 而非 400":
    # 请求本身没错,是当前环境不具备该能力。
    check defaultHttpStatusFor(ecNpuNotAvailable) == 503
    check defaultHttpStatusFor(ecGpuNotAvailable) == 503
    check defaultHttpStatusFor(ecDeviceNotAvailable) == 503
    check defaultHttpStatusFor(ecBackendNotAvailable) == 503

  test "未实现归 501":
    check defaultHttpStatusFor(ecNotImplemented) == 501

  test "取消归 499":
    check defaultHttpStatusFor(ecStreamCancelled) == 499

  test "服务端问题归 5xx":
    check defaultHttpStatusFor(ecInferenceFailed) == 500
    check defaultHttpStatusFor(ecCompilationFailed) == 500
    check defaultHttpStatusFor(ecServerError) == 500

  test "Adapter 默认沿用通用映射":
    check newNativeAdapter().httpStatusFor(ecModelNotFound) == 404

suite "Adapter 注册表":

  test "注册与查找":
    let registry = newAdapterRegistry()
    registry.register(newNativeAdapter())
    check registry.len == 1
    check registry.find("isvik-native") != nil
    check registry.find("nope") == nil

  test "get 找不到时抛 INVALID_REQUEST 并列出已注册协议":
    let registry = newAdapterRegistry()
    registry.register(newNativeAdapter())
    var caught = false
    try:
      discard registry.get("anthropic")
    except IsvikError as e:
      caught = true
      check e.code == ecInvalidRequest
      check e.detail.contains("isvik-native")
    check caught

  test "重复注册同名协议被拒绝":
    # 避免出现「哪个生效」的不确定性。
    let registry = newAdapterRegistry()
    registry.register(newNativeAdapter())
    var caught = false
    try:
      registry.register(newNativeAdapter())
    except IsvikError as e:
      caught = true
      check e.code == ecServerError
    check caught

  test "可注册多个不同协议":
    let registry = newAdapterRegistry()
    registry.register(newNativeAdapter())
    registry.register(MinimalAdapter())
    check registry.len == 2
    check registry.protocolNames() == @["isvik-native", "minimal"]

  test "不同协议各自声明能力,互不影响":
    let registry = newAdapterRegistry()
    registry.register(newNativeAdapter())
    registry.register(MinimalAdapter())
    check registry.get("isvik-native").supports(pcStreaming)
    check not registry.get("minimal").supports(pcStreaming)

suite "流式块辅助":

  test "initChunk 构造非终止块":
    let chunk = initChunk("Test", %*{"a": 1})
    check chunk.eventName == "Test"
    check chunk.data["a"].getInt == 1
    check not chunk.isDone

  test "doneChunk 构造终止块,data 为 nil":
    let chunk = doneChunk()
    check chunk.isDone
    check chunk.data == nil

  test "noChunks 表示该事件在本协议中无对应输出":
    check noChunks().len == 0
