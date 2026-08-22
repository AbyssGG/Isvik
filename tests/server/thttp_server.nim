## Local API Server 测试
##
## 只测**不需要 socket** 的部分:响应构造、错误翻译、请求体解析、启动信息。
## 这些恰好是最容易出静默错误的地方 —— 比如错误响应里泄漏了 detail,
## 或者绑定对外地址时没有警告。
##
## 真实端到端调用需要起进程并发请求,属于集成验证,不放在单元测试里。

import std/[json, os, strutils, unittest]

import isvik/core/errors
import isvik/core/inference
import isvik/core/protocol
import isvik/config/paths
import isvik/config/settings
import isvik/server/http_server

proc serverWith(host: string, port: int): ApiServer =
  var s = defaultSettings()
  s.server.host = host
  s.server.port = port
  newApiServer(newIsvikPaths(getTempDir()), s, proc (line: string) = discard)

suite "服务构造":

  test "构造不加载模型也不监听端口":
    # 构造必须能在没有模型、甚至没有 OpenVINO 的机器上成功。
    let server = serverWith("127.0.0.1", 7317)
    check server.host == "127.0.0.1"
    check server.port == 7317
    check server.adapters().len == 4
    server.close()

  test "close 幂等":
    let server = serverWith("127.0.0.1", 7317)
    server.close()
    server.close()
    check true

suite "启动信息必须说清安全现状":

  test "回环绑定说明只能本机访问":
    let server = serverWith("127.0.0.1", 7317)
    defer: server.close()
    let lines = server.describeBinding().join("\n")
    check lines.contains("http://127.0.0.1:7317")
    check lines.contains("loopback")
    check lines.contains("WARNING: API key authentication is disabled")
    check lines.contains("bound to loopback; reachable only from this machine")

  test "非回环绑定必须警告没有鉴权":
    # 改配置的人未必读过文档,但一定会看到启动输出。
    let server = serverWith("0.0.0.0", 7317)
    defer: server.close()
    let lines = server.describeBinding().join("\n")
    check lines.contains("WARNING")
    check lines.contains("NO authentication")

  test "启动信息列出已注册协议":
    let server = serverWith("127.0.0.1", 7317)
    defer: server.close()
    let lines = server.describeBinding().join("\n")
    for name in ["isvik-native", "openai-chat", "openai-responses",
                 "anthropic"]:
      check lines.contains(name)

  test "并发与流式的当前限制被如实标注":
    # §13 禁止的是伪造。已知限制必须写出来,而不是等用户自己发现。
    let server = serverWith("127.0.0.1", 7317)
    defer: server.close()
    let lines = server.describeBinding().join("\n")
    check lines.contains("blocks the event loop")
    check lines.contains("not")

suite "固定响应体":

  test "版本响应含产品与版本号":
    let node = versionJson()
    check node["product"].getStr.len > 0
    check node["version"].getStr.len > 0

  test "健康响应如实回报有没有加载模型":
    # 「服务活着」不等于「能推理」。
    let idle = healthJson(false, "", "")
    check idle["status"].getStr == "ok"
    check not idle["modelLoaded"].getBool
    check not idle.hasKey("model")

    let busy = healthJson(true, "gemma", "CPU")
    check busy["modelLoaded"].getBool
    check busy["model"].getStr == "gemma"
    check busy["device"].getStr == "CPU"

  test "404 与 405 的响应体都是 §22 的错误形状":
    let notFound = notFoundJson("/api/nope")
    check notFound["error"]["code"].getStr == "INVALID_REQUEST"
    check notFound["error"]["message"].getStr.contains("/api/nope")

    let notAllowed = methodNotAllowedJson(@["POST"])
    check notAllowed["error"]["message"].getStr.contains("POST")

  test "请求体超限的错误说明限额":
    let node = bodyTooLargeJson(1024)
    check node["error"]["message"].getStr.contains("1024")

suite "请求体解析":

  test "合法 JSON 被解析":
    check parseJsonBody("{\"a\":1}")["a"].getInt == 1

  test "空请求体报 INVALID_REQUEST":
    var code = ecServerError
    try:
      discard parseJsonBody("   ")
    except IsvikError as e:
      code = e.code
    check code == ecInvalidRequest

  test "非法 JSON 报 INVALID_REQUEST 而不是穿透成 500":
    var code = ecServerError
    try:
      discard parseJsonBody("{not json")
    except IsvikError as e:
      code = e.code
    check code == ecInvalidRequest

suite "错误翻译":

  test "按协议翻译并使用该协议的状态码":
    let server = serverWith("127.0.0.1", 7317)
    defer: server.close()
    let e = newIsvikError(ecNpuNotAvailable, "no npu", "detail=secret")

    # Anthropic 把设备不可用映射为 529;OpenAI 用默认的 503。
    let anthropic = server.errorResponse("anthropic", e)
    check anthropic.status == 529
    check anthropic.body["error"]["type"].getStr == "overloaded_error"

    let openai = server.errorResponse("openai-chat", e)
    check openai.status == 503
    check openai.body["error"]["code"].getStr == "NPU_NOT_AVAILABLE"

  test "未知协议退回 Isvik 原生错误形状":
    let server = serverWith("127.0.0.1", 7317)
    defer: server.close()
    let e = newIsvikError(ecModelNotFound, "missing")
    let response = server.errorResponse("", e)
    check response.status == 404
    check response.body["error"]["code"].getStr == "MODEL_NOT_FOUND"

  test "错误响应不泄漏 detail":
    # §22:detail 只进日志,不进 API 响应。
    let server = serverWith("127.0.0.1", 7317)
    defer: server.close()
    let e = newIsvikError(ecModelNotFound, "missing",
                          "path=C:\\secret\\models")
    for protocolName in ["", "openai-chat", "anthropic", "isvik-native"]:
      let response = server.errorResponse(protocolName, e)
      check not ($response.body).contains("secret")

suite "响应辅助":

  test "jsonResponse 不带 Allow 头":
    let response = jsonResponse(200, %*{"ok": true})
    check response.status == 200
    check response.allow.len == 0

suite "流式收尾只发生一次":

  # 回归:失败在 `execute` **内部**发生时,错误已经作为终止事件走过 Adapter,
  # 那条序列本身就是完整的收尾。HTTP 层若再补一遍,OpenAI 流会变成
  # `error` → `[DONE]` → `error` → `[DONE]`:按约定在 `[DONE]` 处停止解析的
  # 客户端会把错误整个丢掉,继续读的客户端则看到同一个错误两次。
  #
  # 用「模型不存在」触发:它在解析阶段就失败,不需要真实模型或 OpenVINO。

  proc streamFor(protocolName: string): string =
    let server = serverWith("127.0.0.1", 7317)
    defer: server.close()
    let adapter = server.adapters().get(protocolName)
    var req = initUnifiedInferenceRequest("no-such-model-for-streaming")
    req.stream = true
    req.messages = @[initMessage(mrUser, @[textPart("hi")])]
    result = server.encodeEventStream(req, adapter, protocolName)

  test "OpenAI 错误流只有一个 [DONE] 且错误不重复":
    let payload = streamFor("openai-chat")
    check payload.count("data: [DONE]") == 1
    check payload.count("MODEL_NOT_FOUND") == 1
    # `[DONE]` 必须是最后一帧,后面不能再有内容。
    check payload.strip().endsWith("data: [DONE]")

  test "Anthropic 错误流只发一次 error 与一次 message_stop":
    let payload = streamFor("anthropic")
    check payload.count("event: error") == 1
    check payload.count("message_stop") == 2   # 具名事件行 + data 里的 type
    check payload.count("MODEL_NOT_FOUND") == 1
    # Anthropic 用 message_stop 收尾,不该再补 [DONE]。
    check not payload.contains("[DONE]")
