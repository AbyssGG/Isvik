## Local API 路由与 SSE 编码测试
##
## 路由与编码都是纯函数,因此这里能把 §21 的端点清单逐条断言 ——
## 少一个端点、方法写错、路径大小写不一致,都是只在客户端接入时才暴露的错误。

import std/[json, strutils, unittest]

import isvik/core/protocol
import isvik/server/routes
import isvik/server/sse

suite "路径规范化":

  test "去掉查询串与片段":
    check normalizePath("/api/models?verbose=1") == "/api/models"
    check normalizePath("/api/models#x") == "/api/models"

  test "去掉末尾斜杠但保留根路径":
    check normalizePath("/api/models/") == "/api/models"
    check normalizePath("/api/models///") == "/api/models"
    check normalizePath("/") == "/"
    check normalizePath("") == "/"

  test "不改大小写":
    # URL 路径大小写敏感。悄悄小写化会让「我们这里能用」的写法在切换到
    # 真实 OpenAI 端点时失败。
    check normalizePath("/API/Models") == "/API/Models"
    check resolveRoute("GET", "/API/models").kind == rkNotFound

suite "§21 端点清单":

  test "六个 GET 端点齐备":
    check resolveRoute("GET", "/api/version").kind == rkVersion
    check resolveRoute("GET", "/api/health").kind == rkHealth
    check resolveRoute("GET", "/api/models").kind == rkModels
    check resolveRoute("GET", "/api/devices").kind == rkDevices
    check resolveRoute("GET", "/api/runtime").kind == rkRuntime
    let detail = resolveRoute("GET", "/api/models/gemma-4")
    check detail.kind == rkModelDetail
    check detail.modelId == "gemma-4"

  test "四个 POST 端点齐备":
    check resolveRoute("POST", "/api/generate").kind == rkGenerate
    check resolveRoute("POST", "/api/chat").kind == rkChat
    check resolveRoute("POST", "/api/load").kind == rkLoad
    check resolveRoute("POST", "/api/unload").kind == rkUnload

  test "方法小写同样被识别":
    check resolveRoute("get", "/api/health").kind == rkHealth
    check resolveRoute("post", "/api/chat").kind == rkChat

suite "404 与 405 必须区分":

  test "方法不对报 405 并给出 Allow":
    # 报 404 会让调用方以为端点不存在,于是去查文档、怀疑版本不对。
    let route = resolveRoute("GET", "/api/chat")
    check route.kind == rkMethodNotAllowed
    check route.allowed == @["POST"]

    let getOnly = resolveRoute("POST", "/api/version")
    check getOnly.kind == rkMethodNotAllowed
    check getOnly.allowed == @["GET"]

  test "模型详情只允许 GET":
    let route = resolveRoute("DELETE", "/api/models/x")
    check route.kind == rkMethodNotAllowed
    check route.allowed == @["GET"]

  test "未知路径报 404":
    check resolveRoute("GET", "/").kind == rkNotFound
    check resolveRoute("GET", "/api").kind == rkNotFound
    check resolveRoute("GET", "/api/nope").kind == rkNotFound

  test "多段模型路径不猜意图":
    check resolveRoute("GET", "/api/models/a/b").kind == rkNotFound
    check resolveRoute("GET", "/api/models/").kind == rkModels

suite "协议路由":

  test "四个协议端点映射到对应 Adapter":
    let openai = resolveRoute("POST", "/v1/chat/completions")
    check openai.kind == rkProtocolChat
    check openai.protocol == "openai-chat"

    let responses = resolveRoute("POST", "/v1/responses")
    check responses.kind == rkProtocolChat
    check responses.protocol == "openai-responses"

    let anthropic = resolveRoute("POST", "/v1/messages")
    check anthropic.kind == rkProtocolChat
    check anthropic.protocol == "anthropic"

    let native = resolveRoute("POST", "/api/v1/chat")
    check native.kind == rkProtocolChat
    check native.protocol == "isvik-native"

  test "协议端点只允许 POST":
    let route = resolveRoute("GET", "/v1/chat/completions")
    check route.kind == rkMethodNotAllowed
    check route.allowed == @["POST"]

  test "非协议路径不返回协议名":
    check protocolForPath("/api/models") == ""
    check protocolForPath("/v1/nope") == ""

suite "回环判定":

  test "回环地址被识别":
    for host in ["127.0.0.1", "localhost", "::1", "[::1]", " 127.0.0.1 ",
                 "LOCALHOST"]:
      check isLoopbackHost(host)

  test "对外地址不被当成回环":
    # 当前没有任何鉴权,对外监听等于把本地模型开放给同网段所有人。
    for host in ["0.0.0.0", "192.168.1.10", "::", "example.com"]:
      check not isLoopbackHost(host)

suite "SSE 帧编码":

  test "具名事件与匿名事件":
    check sseFrame("message_start", "{}") == "event: message_start\ndata: {}\n\n"
    check sseFrame("", "{}") == "data: {}\n\n"

  test "空数据也产生一个 data 行":
    # 没有 data 行客户端收不到事件。
    check sseFrame("", "") == "data: \n\n"

  test "多行数据被拆成多个 data 行":
    # 一条 data 里的换行会被解析成「事件结束」,后面的内容变成下一个事件的
    # 开头 —— 客户端收到两个残缺的 JSON。
    let frame = sseFrame("", "{\n  \"a\": 1\n}")
    check frame.count("data: ") == 3
    check frame.endsWith("\n\n")

  test "注释帧用于保活":
    check sseComment(" keep-alive") == ": keep-alive\n\n"

suite "协议流块编码":

  test "普通数据块":
    let chunk = initChunk("", %*{"a": 1})
    check encodeChunk(chunk) == "data: {\"a\":1}\n\n"

  test "OpenAI 的结束标记是字面量而不是 JSON":
    check encodeChunk(doneChunk()) == "data: [DONE]\n\n"

  test "Anthropic 不需要额外结束帧":
    # 它靠具名的 message_stop 表示结束;再补 [DONE] 会让状态机收到
    # 一个不认识的帧。
    check encodeChunk(doneChunk(), doneLiteralFor("anthropic")) == ""

  test "结束标记约定按协议区分":
    check doneLiteralFor("openai-chat") == "[DONE]"
    check doneLiteralFor("anthropic") == ""
    check doneLiteralFor("isvik-native") == ""

  test "多个块被顺序拼接":
    let encoded = encodeChunks(@[
      initChunk("", %*{"i": 1}),
      initChunk("", %*{"i": 2}),
      doneChunk()
    ])
    check encoded == "data: {\"i\":1}\n\ndata: {\"i\":2}\n\ndata: [DONE]\n\n"

  test "带 data 的结束块仍然输出数据":
    # isDone 只表示「这是最后一块」,不代表它没有内容。
    var chunk = initChunk("message_stop", %*{"type": "message_stop"})
    chunk.isDone = true
    let encoded = encodeChunk(chunk, doneLiteralFor("anthropic"))
    check encoded.contains("message_stop")
