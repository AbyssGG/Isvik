## Local API Server(Master Prompt §21)
##
## ---
##
## ## 职责边界(§20.5.11)
##
## ```text
## 做:   HTTP 收发、路由、请求体解析、协议翻译、SSE 流式、错误翻译
##
## 不做: 模型编译、推理、设备选择、OpenVINO 调用、tensor 处理、缓存
##       —— 这些全部经 Application Services 完成
## ```
##
## 机械保证:本模块**不** import `isvik/backends/*`,也不 import
## `isvik/inference/*`。架构测试会拦住 `resonance` / `openvino` 一类的直连。
##
## ---
##
## ## 安全现状必须说清楚
##
## Local API 有两种启动模式:
##
## - 默认的 `isvik serve` 为保持旧流程兼容,不启用 API Key,且默认只监听回环。
## - `--require-api-key` 与面向成品客户端的 `isvik api serve` 启用动态 API Key
##   鉴权;绑定非回环地址时仍会在启动日志中明确显示安全状态。
##
## 鉴权模式使用操作系统随机生成的 Key,磁盘只保存摘要,服务端每次请求重新读取
## 元数据文件,因此新增和撤销会立即生效。无鉴权模式不应绑定非回环地址。
##
## ---
##
## ## 为什么用 std/asynchttpserver
##
## 它在标准库里,不引入 nimble 依赖 —— 当前仓库的外部依赖只有
## `nim >= 2.0.0`,保持这一点比省几行代码重要。
##
## 单线程 async 的直接后果:**推理会阻塞事件循环**。这不是被忽略的问题,
## 而是当前已知限制:一次请求推理期间,其它连接得不到响应。§70 的线程模型
## 尚未落地,此处如实标注而不假装并发。

import std/[asyncdispatch, asynchttpserver, asyncnet, json, strutils, tables,
            times]

import isvik/version
import isvik/core/errors
import isvik/core/inference
import isvik/core/inference_events
import isvik/core/protocol
import isvik/config/paths
import isvik/config/settings
import isvik/config/api_keys
import isvik/protocol/registry
import isvik/protocol/openai_chat
import isvik/services/model_service
import isvik/services/device_service
import isvik/services/inference_service
import isvik/server/routes
import isvik/server/sse

export routes, sse

const
  JsonContentType* = "application/json; charset=utf-8"
  MaxRequestBodyBytes* = 8 * 1024 * 1024
    ## 请求体上限。超过即拒,而不是让进程慢慢吃满内存。
    ## 8 MiB 足够容纳很长的多轮历史;真正的大输入应当分块而不是塞进一个请求。

type
  ServerLogger* = proc (line: string) {.closure.}
    ## 日志输出。注入而不是直接 echo,使测试与嵌入式使用不被迫写 stdout。

  ApiServer* = ref object
    ## Local API 服务。
    ##
    ## 一个 `InferenceService` 被所有请求共享 —— 它内部只缓存一个已加载模型,
    ## 这与「单线程 async」是配套的:并发推理本来就还没实现。
    inference: InferenceService
    models: ModelService
    adapters: AdapterRegistry
    host: string
    port: int
    log: ServerLogger
    logError: ServerLogger
      ## 错误专用 sink。分开是因为**级别会被用来过滤**:错误若以 INFO 记录,
      ## 用户把 `logging.level` 收紧到 ERROR 时会把错误一起丢掉 —— 那正好是
      ## 最需要它的时候。nil 时回落到 `log`。
    apiKeysPath: string
    requireApiKey: bool
    closed: bool

proc defaultLogger(): ServerLogger =
  result = proc (line: string) = echo line

proc newApiServer*(paths: IsvikPaths, s: Settings,
                   logger: ServerLogger = nil,
                   requireApiKey: bool = false,
                   errorLogger: ServerLogger = nil): ApiServer =
  new(result)
  result.inference = newInferenceService(paths, s)
  result.models = newModelService(paths, s)
  result.adapters = newDefaultAdapterRegistry()
  result.host = s.server.host
  result.port = s.server.port
  result.log = if logger == nil: defaultLogger() else: logger
  result.logError = if errorLogger == nil: result.log else: errorLogger
  result.apiKeysPath = paths.apiKeysFile
  result.requireApiKey = requireApiKey
  result.closed = false

proc close*(server: ApiServer) =
  if server == nil or server.closed:
    return
  server.closed = true
  server.inference.close()

proc host*(server: ApiServer): string = server.host
proc port*(server: ApiServer): int = server.port
proc adapters*(server: ApiServer): AdapterRegistry = server.adapters
proc requiresApiKey*(server: ApiServer): bool =
  server != nil and server.requireApiKey
proc apiKeysFile*(server: ApiServer): string =
  if server == nil: "" else: server.apiKeysPath

# ---------------------------------------------------------------------------
# 纯响应构造:可独立测试
# ---------------------------------------------------------------------------

proc versionJson*(): JsonNode =
  %*{
    "product": IsvikProductName,
    "version": IsvikVersion,
    "api": "local",
    "protocols": newJArray()
  }

proc healthJson*(loaded: bool, model, device: string): JsonNode =
  ## 健康检查如实回报「有没有加载模型」。
  ##
  ## 不把「服务活着」等同于「能推理」:前者只说明进程在跑。
  result = %*{
    "status": "ok",
    "modelLoaded": loaded
  }
  if loaded:
    result["model"] = %model
    result["device"] = %device

proc notFoundJson*(path: string): JsonNode =
  ## 404 的消息里带上「你大概想要哪个端点」——见 routes.endpointHintFor 的说明:
  ## 客户端往往把这个响应体换成自己的诊断,原始 message 是唯一的线索来源。
  let hint = endpointHintFor(path)
  if hint.len == 0:
    return errorJson(ecInvalidRequest, "Unknown endpoint: " & path)
  errorJson(ecInvalidRequest, "Unknown endpoint: " & path & ". " & hint)

proc methodNotAllowedJson*(allowed: seq[string]): JsonNode =
  errorJson(ecInvalidRequest,
            "Method not allowed; use " & allowed.join(", "))

proc bodyTooLargeJson*(limit: int): JsonNode =
  errorJson(ecInvalidRequest,
            "Request body exceeds the limit of " & $limit & " bytes")

proc parseJsonBody*(body: string): JsonNode =
  ## 解析请求体。非法 JSON 报 INVALID_REQUEST 而不是让异常穿透成 500。
  if body.strip().len == 0:
    raiseIsvikError(ecInvalidRequest, "Request body must not be empty",
                    "reason=empty-body")
  try:
    result = parseJson(body)
  except CatchableError as e:
    raiseIsvikError(ecInvalidRequest, "Request body is not valid JSON",
                    "reason=" & e.msg)

# ---------------------------------------------------------------------------
# 处理:同步部分(不碰 socket,便于测试)
# ---------------------------------------------------------------------------

type
  ApiResponse* = object
    ## 一个非流式响应。
    status*: int
    body*: JsonNode
    allow*: seq[string]
      ## 405 时的 `Allow` 头。

proc jsonResponse*(status: int, body: JsonNode): ApiResponse =
  ApiResponse(status: status, body: body, allow: @[])

proc errorResponse*(server: ApiServer, protocolName: string,
                    e: ref IsvikError): ApiResponse =
  ## 把 Isvik 错误翻译成协议错误。
  ##
  ## 顺序是固定的(§20.5.7):Backend Error → Isvik Error → Protocol Error。
  ## `formatError` 只收 code 与 message,因此 detail 不可能被误写进响应。
  let adapter =
    if protocolName.len > 0: server.adapters.find(protocolName) else: nil
  if adapter == nil:
    return ApiResponse(status: defaultHttpStatusFor(e.code),
                       body: e.toJsonNode(), allow: @[])
  ApiResponse(status: adapter.httpStatusFor(e.code),
              body: adapter.formatError(e.code, e.msg), allow: @[])

proc modelsJson(server: ApiServer): JsonNode =
  var items = newJArray()
  for stored in server.models.list():
    items.add(stored.manifest.toJsonNode())
  %*{
    "models": items,
    "modelDirectory": server.models.rootDirectory
  }

proc modelDetailJson(server: ApiServer, id: string): JsonNode =
  server.models.info(id).manifest.toJsonNode()

proc devicesJson(server: ApiServer): JsonNode =
  ## 设备快照。每次请求开一个 Device Service 并成对关闭 ——
  ## 常驻一个只为查设备的 Runtime 不划算,而设备列表本身会变(热插拔)。
  let svc = openDeviceService()
  try:
    var items = newJArray()
    for d in svc.devices():
      items.add(%*{
        "device": d.rawName,
        "deviceType": $d.deviceType,
        "fullName": d.fullName,
        "vendor": d.vendor,
        "available": d.available,
        "policyEligible": d.policyEligible,
        "exclusionReason": d.exclusionReason
      })
    var excluded = newJArray()
    for e in svc.excludedDevices():
      excluded.add(%*{"device": e.device, "reason": e.reason})
    result = %*{
      "backend": svc.backendName(),
      "backendVersion": svc.backendVersion(),
      "devices": items,
      "excluded": excluded
    }
  finally:
    svc.close()

proc runtimeJson(server: ApiServer): JsonNode =
  ## 运行时状态。只报**事实**:加载了什么、跑在哪个设备上。
  %*{
    "modelLoaded": server.inference.isLoaded(),
    "model": server.inference.loadedModel(),
    "device": server.inference.loadedDevice(),
    "directory": server.inference.loadedDirectory()
  }

proc handleLoad(server: ApiServer, body: JsonNode): ApiResponse =
  let model = body{"model"}.getStr("")
  if model.strip().len == 0:
    raiseIsvikError(ecInvalidRequest, "Field model is required",
                    "field=model")
  let device = body{"device"}.getStr("")
  let actual = server.inference.load(model, device)
  jsonResponse(200, %*{
    "loaded": true,
    "model": server.inference.loadedModel(),
    "requestedDevice":
      (if device.strip().len == 0: server.inference.defaultDevice()
       else: device),
    # 实际设备可能与请求不同(AUTO 决策或 CPU 回落),必须如实回报。
    "device": actual
  })

proc handleUnload(server: ApiServer): ApiResponse =
  let wasLoaded = server.inference.isLoaded()
  let previous = server.inference.loadedModel()
  server.inference.unload()
  jsonResponse(200, %*{
    "unloaded": wasLoaded,
    "model": previous
  })

proc logInferenceSuccess(server: ApiServer, protocolName: string,
                         stream: bool, res: UnifiedInferenceResult) =
  ## 只记录诊断摘要，不记录 prompt、正文、工具定义或 API Key。
  var summary =
    "completed protocol=" & protocolName &
    " stream=" & $stream &
    " model=" & res.model &
    " device=" & res.device &
    " input_tokens=" & $res.usage.inputTokens &
    " output_tokens=" & $res.usage.outputTokens &
    " text_chars=" & $res.content.plainText().len &
    " tools=" & $res.content.toolCalls().len &
    " stop=" & $res.stopReason

  if res.metadata.hasKey("prefill_ms"):
    summary.add(" prefill_ms=" & res.metadata["prefill_ms"])
  if res.metadata.hasKey("decode_ms"):
    summary.add(" decode_ms=" & res.metadata["decode_ms"])
  if res.metadata.hasKey("total_ms"):
    summary.add(" total_ms=" & res.metadata["total_ms"])
  if res.metadata.hasKey("prefill_batch_tokens"):
    summary.add(" prefill_batch=" & res.metadata["prefill_batch_tokens"])
  if res.metadata.hasKey("tool_instruction_chars"):
    summary.add(" tool_instruction_chars=" &
                res.metadata["tool_instruction_chars"])

  server.log(summary)

proc runInference(server: ApiServer, req: UnifiedInferenceRequest,
                  adapter: ProtocolAdapter,
                  protocolName: string = "isvik-native"): ApiResponse =
  ## 非流式推理。
  ##
  ## 与流式**共用同一条执行路径**(§20.5.4):这里只是不订阅事件。
  ## 不存在「流式一套、非流式另一套」的第二实现。
  let res = server.inference.execute(req)
  server.logInferenceSuccess(protocolName, false, res)
  if adapter == nil:
    jsonResponse(200, res.toJsonNode())
  else:
    jsonResponse(200, adapter.formatResult(res))

# ---------------------------------------------------------------------------
# 处理:异步部分
# ---------------------------------------------------------------------------

proc sendJson(request: Request, response: ApiResponse): Future[void] =
  var headers = newHttpHeaders({"Content-Type": JsonContentType})
  if response.allow.len > 0:
    headers["Allow"] = response.allow.join(", ")
  if response.status == 401:
    headers["WWW-Authenticate"] = "Bearer"
  request.respond(HttpCode(response.status), $response.body, headers)

proc extractApiKey(request: Request, protocolName: string): string =
  ## OpenAI 通常使用 Authorization: Bearer,Anthropic 通常使用 x-api-key。
  ## 两种格式都接受另一种常见写法,方便 TRAE 等自定义客户端复用同一个 Key。
  let xApiKey: string = request.headers.getOrDefault("x-api-key")
  if xApiKey.strip().len > 0:
    return xApiKey.strip()

  let authorization: string = request.headers.getOrDefault("Authorization")
  let normalizedAuthorization = authorization.strip()
  let lowerAuthorization = normalizedAuthorization.toLowerAscii
  if lowerAuthorization.startsWith("bearer "):
    return normalizedAuthorization[7 .. ^1].strip()
  if protocolName == "anthropic":
    # 某些兼容客户端把 Anthropic Key 也放在 Authorization 中,但不带
    # Bearer 前缀。只在 Anthropic 路径接受,避免放宽 OpenAI 语义。
    return authorization
  ""

proc requireValidApiKey(server: ApiServer, request: Request,
                        protocolName: string) =
  if not server.requireApiKey:
    return
  let presented = extractApiKey(request, protocolName)
  if not verifyApiKey(server.apiKeysPath, presented):
    raiseIsvikError(
      ecUnauthorized,
      "The API key is missing or invalid",
      "path=" & normalizePath(request.url.path)
    )


proc encodeEventStream*(server: ApiServer, req: UnifiedInferenceRequest,
                        adapter: ProtocolAdapter,
                        protocolName: string,
                        streamId: string = "",
                        created: int64 = -1,
                        skipStarted: bool = false): string =
  ## 执行推理并把整条事件流编码成 SSE 载荷。
  ##
  ## ---
  ##
  ## ## 一个必须说清楚的当前限制
  ##
  ## 载荷是**先攒完再发**的,不是逐 token 推送。原因是解码在事件循环里同步
  ## 运行(§70 的线程模型尚未落地),而在回调里 `waitFor` 会递归进入事件循环 ——
  ## 那是明确的错误用法。
  ##
  ## 所以这里的取舍是:**帧格式完全正确,投递时机暂不增量。** 客户端能按 SSE
  ## 正常解析,拿到的事件序列与真正的流式完全一致;区别只在它们同时到达。
  ##
  ## 不假装增量(比如在文档里写「支持流式」而不提这一点),也不因此拒绝
  ## `stream: true` —— 后者会让 SDK 直接不可用,而事件序列本身是可用的。
  ##
  ## 真正的增量投递需要把推理挪出事件循环,那是 §70 的工作。
  let doneLiteral = doneLiteralFor(protocolName)
  # 流式 HTTP 入口可预先发送 start 事件；编码剩余事件时必须沿用同一身份。
  let effectiveStreamId =
    if streamId.len > 0: streamId else: openai_chat.generatedId()
  let effectiveCreated =
    if created >= 0: created else: int64(epochTime())

  var payload = ""
  # 事件流是否已经自行收尾。Adapter 对终止事件(含 Error)已经产出完整的
  # 收尾序列 —— OpenAI 是 error 块 + `[DONE]`,Anthropic 是 error +
  # message_stop。若下面的 except 再补一遍,客户端会看到 `[DONE]` **之后**
  # 还有帧,以及同一个错误出现两次;按约定在 `[DONE]` 处停止解析的客户端
  # 反而会把错误整个丢掉。
  var terminated = false

  proc emit(e: InferenceEvent): bool =
    if skipStarted and e.kind == iekInferenceStarted:
      return true
    var chunks =
      if adapter == nil: @[initChunk("", e.toJsonNode())]
      else: adapter.formatEvent(e)
    if e.isTerminal and adapter == nil:
      chunks.add(doneChunk())
    if e.isTerminal:
      terminated = true
    for chunk in chunks:
      let stamped =
        if protocolName == OpenAiChatProtocolName:
          chunk.withStreamIdentity(effectiveStreamId, effectiveCreated,
                                   req.model)
        else: chunk
      payload.add(encodeChunk(stamped, doneLiteral))
    true

  try:
    let res = server.inference.execute(req, emit)
    server.logInferenceSuccess(protocolName, true, res)
  except IsvikError as e:
    # **这里是流式失败唯一还能看到 detail 的地方,必须记录。**
    #
    # 流式的错误不会冒泡到 `handleRequest`:它在这里被吃掉,HTTP 状态仍是 200,
    # 错误只作为流内的 error 事件送出。而事件用 `inferenceErrorFrom` 构造,
    # 按安全边界**不携带 detail** —— 于是「失败的具体原因」在客户端和日志里
    # 同时消失,只剩一句 `Inference execution failed`。
    #
    # 记录与投递是两件事:无论流是否已经自行收尾都要记,否则最常见的那种
    # (`execute` 内部失败、已经 emit 过终止事件)恰好一条都不会留下。
    server.logError("stream " & protocolName & " model=" & req.model &
                    " -> " & e.logLine())
    # 已经产出的增量必须保留:客户端拿到半截回答加一个错误事件,
    # 比什么都没有更有诊断价值。
    #
    # 但只在流**还没**收尾时补:失败发生在 `execute` 内部时,错误已经作为
    # 终止事件走过上面的 emit,这里再写一遍就是重复投递。这条兜底针对的是
    # 在任何事件产生**之前**就抛出的失败(入口校验、模型解析)。
    if not terminated:
      let response = server.errorResponse(protocolName, e)
      payload.add(sseFrame("error", $response.body))
      if doneLiteral.len > 0:
        payload.add(sseFrame("", doneLiteral))
  result = payload

proc chunkedWire(payload: string): string =
  ## std/asynchttpserver 只提供完整 Content-Length 响应；SSE 需要手工写标准
  ## HTTP/1.1 chunked 帧，才能在同步推理开始前把响应头和 start 事件送达。
  payload.len.toHex & "\r\n" & payload & "\r\n"

proc streamInference(server: ApiServer, request: Request,
                     req: UnifiedInferenceRequest,
                     adapter: ProtocolAdapter,
                     protocolName: string): Future[void] {.async.} =
  ## 先确认流，再执行同步推理。
  ##
  ## 这还不是 token 级并发投递：OpenVINO 推理仍运行在事件循环线程，后续
  ## delta 会在生成完成后一起写出。但与旧实现相比，HTTP 200、SSE 类型和
  ## 协议 start 事件会立即到达，TRAE 不会在模型编译/prefill 期间把“尚未
  ## 收到响应”误判成 502 empty content。完整的 worker/result queue 是下一层。
  let streamId = openai_chat.generatedId()
  let created = int64(epochTime())
  let doneLiteral = doneLiteralFor(protocolName)

  var initialPayload = ""
  var sentProtocolStart = false
  if adapter != nil and protocolName != "isvik-native":
    let startEvent = inferenceStarted(req.model, "")
    for chunk in adapter.formatEvent(startEvent):
      let stamped =
        if protocolName == OpenAiChatProtocolName:
          chunk.withStreamIdentity(streamId, created, req.model)
        else:
          chunk
      initialPayload.add(encodeChunk(stamped, doneLiteral))
    sentProtocolStart = initialPayload.len > 0
  if initialPayload.len == 0:
    # Native 或不产生 start chunk 的协议至少先收到合法 SSE 注释。
    initialPayload = sseComment(" isvik stream accepted")

  let headers =
    "HTTP/1.1 200 OK\r\n" &
    "Content-Type: " & SseContentType & "\r\n" &
    "Cache-Control: no-cache\r\n" &
    "X-Accel-Buffering: no\r\n" &
    "Transfer-Encoding: chunked\r\n" &
    "Connection: close\r\n\r\n"

  try:
    await request.client.send(headers)
    await request.client.send(chunkedWire(initialPayload))

    let payload = server.encodeEventStream(
      req, adapter, protocolName, streamId, created,
      skipStarted = sentProtocolStart)
    if payload.len > 0:
      await request.client.send(chunkedWire(payload))
    await request.client.send("0\r\n\r\n")
  except OSError as e:
    # 响应已经开始后不能再退回 JSON 错误；断开只记录摘要并结束连接。
    server.logError("stream " & protocolName & " model=" & req.model &
                    " client disconnected -> " & e.msg)
  finally:
    request.client.close()

proc handleRequest(server: ApiServer, request: Request) {.async.} =
  let route = resolveRoute($request.reqMethod, request.url.path)
  var protocolName =
    if route.kind == rkProtocolChat: route.protocol else: ""

  try:
    if request.body.len > MaxRequestBodyBytes:
      await request.sendJson(
        jsonResponse(413, bodyTooLargeJson(MaxRequestBodyBytes)))
      return

    server.requireValidApiKey(request, protocolName)

    case route.kind
    of rkNotFound:
      await request.sendJson(
        jsonResponse(404, notFoundJson(normalizePath(request.url.path))))
    of rkMethodNotAllowed:
      await request.sendJson(ApiResponse(
        status: 405,
        body: methodNotAllowedJson(route.allowed),
        allow: route.allowed))
    of rkVersion:
      var node = versionJson()
      node["protocols"] = %server.adapters.protocolNames()
      await request.sendJson(jsonResponse(200, node))
    of rkHealth:
      await request.sendJson(jsonResponse(200, healthJson(
        server.inference.isLoaded(),
        server.inference.loadedModel(),
        server.inference.loadedDevice())))
    of rkModels:
      await request.sendJson(jsonResponse(200, server.modelsJson()))
    of rkModelDetail:
      await request.sendJson(
        jsonResponse(200, server.modelDetailJson(route.modelId)))
    of rkDevices:
      await request.sendJson(jsonResponse(200, server.devicesJson()))
    of rkRuntime:
      await request.sendJson(jsonResponse(200, server.runtimeJson()))
    of rkLoad:
      await request.sendJson(server.handleLoad(parseJsonBody(request.body)))
    of rkUnload:
      await request.sendJson(server.handleUnload())
    of rkChat, rkGenerate, rkProtocolChat:
      protocolName =
        if route.kind == rkProtocolChat: route.protocol else: "isvik-native"
      let adapter = server.adapters.get(protocolName)
      let req = adapter.parseRequest(parseJsonBody(request.body))
      # 不记录 prompt、正文或 Key，只留下足够区分“请求没到”“空输出”和
      # “工具请求”的入口摘要。
      server.log("request method=" & $request.reqMethod &
                 " path=" & normalizePath(request.url.path) &
                 " protocol=" & protocolName &
                 " stream=" & $req.stream &
                 " model=" & req.model &
                 " messages=" & $req.messages.len &
                 " tools=" & $req.tools.len)
      if req.stream:
        await server.streamInference(request, req, adapter, protocolName)
      else:
        await request.sendJson(server.runInference(req, adapter, protocolName))
  except IsvikError as e:
    # 所有错误都先是 IsvikError,再翻译成协议错误。不让异常穿透成 500。
    #
    # **必须在这里记录 detail。** 响应体按安全边界只带 code + message
    # (detail 可能含绝对路径),于是失败的真正原因原本在这里被彻底丢弃 ——
    # 客户端只会显示 `Inference execution failed`,而 `operation=ovOpInfer`
    # 这类关键线索谁也看不到。`logLine()` 正是为此存在的。
    server.logError($request.reqMethod & " " & request.url.path & " -> " &
                    e.logLine())
    await request.sendJson(server.errorResponse(protocolName, e))
  except CatchableError as e:
    let wrapped = newIsvikError(ecServerError, "Unhandled server error", e.msg)
    server.logError($request.reqMethod & " " & request.url.path & " -> " &
                    wrapped.logLine())
    await request.sendJson(server.errorResponse(protocolName, wrapped))

proc describeBinding*(server: ApiServer): seq[string] =
  ## 启动前要打印的信息。**包含安全现状**。
  ##
  ## 把是否启用鉴权写在启动日志里:改配置的人未必读过文档,
  ## 但一定会看到当前服务的安全状态。
  result = @[]
  result.add("Isvik Local API  http://" & server.host & ":" & $server.port)
  result.add("  protocols: " & server.adapters.protocolNames().join(", "))
  if server.requireApiKey:
    result.add("  API key authentication enabled")
    result.add("  key metadata: " & server.apiKeysPath)
  elif isLoopbackHost(server.host):
    result.add("  WARNING: API key authentication is disabled")
    result.add("  bound to loopback; reachable only from this machine")
  else:
    result.add("  WARNING: bound to a non-loopback address and there is" &
               " NO authentication.")
    result.add("  Anyone who can reach this address can use your local" &
               " models. Put a reverse proxy in front of it.")
  result.add("  note: inference blocks the event loop; concurrent requests" &
             " are not served in parallel yet")
  result.add("  note: SSE headers/start are sent immediately; token deltas" &
             " are delivered together until the worker queue lands")

proc serve*(server: ApiServer) =
  ## 启动服务并阻塞。
  let http = newAsyncHttpServer()
  for line in server.describeBinding():
    server.log(line)

  proc callback(request: Request): Future[void] {.async, gcsafe.} =
    # `ProtocolAdapter` 的 method 是动态派发的,编译器无法证明它们 GC-safe,
    # 于是整条调用链都被标成不安全。
    #
    # 这里用 cast 而不是给所有 method 加 `{.gcsafe.}`:本服务是**单线程**
    # async(§70 的线程模型尚未落地),不存在跨线程共享,断言在当前设计下
    # 成立。等真的引入 worker 线程时,这个 cast 必须去掉并逐个审查 ——
    # 那时它就不再成立了。
    {.cast(gcsafe).}:
      await server.handleRequest(request)

  waitFor http.serve(Port(server.port), callback, address = server.host)
