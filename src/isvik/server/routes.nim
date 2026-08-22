## Local API 路由表(Master Prompt §21)
##
## ---
##
## ## 为什么路由是纯函数
##
## 「哪个路径对应哪个动作」是一条可以完整测试的规则,而 socket 不是。把它独立
## 出来使端点清单能被逐条断言 —— 少一个端点、方法写错、路径大小写不一致,
## 这些都是只在客户端接入时才暴露的错误。
##
## 本模块**不碰** asynchttpserver,也不知道任何 handler 的实现。
##
## ---
##
## ## 405 与 404 必须区分
##
## 对 `GET /api/chat` 返回 404 会让调用方以为端点不存在,于是去查文档、
## 怀疑版本不对。正确答案是 405 并在 `Allow` 里说明它该用 POST。
##
## ---
##
## ## 协议路由
##
## 兼容协议的路径由 Adapter 的 `apiVersion` 与协议约定决定:
##
## ```text
## /v1/chat/completions   openai-chat
## /v1/messages           anthropic
## /api/v1/chat           isvik-native
## ```
##
## 路由只负责**认出协议名**,请求体的解析交给对应 Adapter(§20.5.2:
## 不得为了增加协议而在 HTTP 层写特判)。
##
## ---
##
## ## 为什么额外接受不带 /v1 的 OpenAI 路径
##
## 成品客户端(TRAE、Cherry Studio 等)在「非完整 URL」模式下的做法是:让用户
## 填一个基地址,然后由客户端把 `/chat/completions` 拼到末尾。于是填
## `http://127.0.0.1:7317` 会打到 **`/chat/completions`**,填
## `http://127.0.0.1:7317/v1` 才得到 `/v1/chat/completions`。
##
## 两种填法都很自然,而只支持后者的直接后果是:客户端拿到 404 的 JSON 错误体,
## 再把它包装成自己的诊断(实测 TRAE 报
## `The custom model provider has returned empty content. (HTTP Status: 502)`)——
## **真实原因是路径,但用户看到的是 502**,几乎无法归因。
##
## 因此把不带前缀的形式作为别名接受。这不是伪造兼容:`/chat/completions` 这个
## 路径在 OpenAI 语义里只可能是 Chat Completions,不存在歧义。
##
## **刻意不兼容的两种**:
##
## ```text
## /completions        legacy text completion,与 chat 是不同的端点语义。
##                     (基地址以 / 结尾时客户端会拼出 //chat/completions,
##                      实测被解析成 /completions —— 那时必须让用户去掉尾斜杠,
##                      而不是把它当 chat 处理)
## /v1/v1/messages     基地址已带 /v1 又被客户端再追加一次。兼容它等于允许
##                     任意层数的前缀,URL 结构就没有约定了。
## ```

import std/strutils

const
  ApiPrefix* = "/api"
  ModelsPath* = "/api/models"

  OpenAiChatPath* = "/v1/chat/completions"
  OpenAiResponsesPath* = "/v1/responses"
  AnthropicMessagesPath* = "/v1/messages"
  NativeChatPath* = "/api/v1/chat"

  OpenAiChatPathNoPrefix* = "/chat/completions"
    ## 客户端在基地址后自行追加路径时的形式。见上方说明。
  OpenAiResponsesPathNoPrefix* = "/responses"

  MethodGet* = "GET"
  MethodPost* = "POST"

type
  RouteKind* = enum
    rkNotFound = "not-found"
    rkMethodNotAllowed = "method-not-allowed"
    rkVersion = "version"
    rkHealth = "health"
    rkModels = "models"
    rkModelDetail = "model-detail"
    rkDevices = "devices"
    rkRuntime = "runtime"
    rkLoad = "load"
    rkUnload = "unload"
    rkChat = "chat"
    rkGenerate = "generate"
    rkProtocolChat = "protocol-chat"

  Route* = object
    kind*: RouteKind
    modelId*: string
      ## 仅 `rkModelDetail`:URL 里的模型标识。
    protocol*: string
      ## 仅 `rkProtocolChat`:该走哪个 Adapter。
    allowed*: seq[string]
      ## 仅 `rkMethodNotAllowed`:该端点支持的方法,用于 `Allow` 响应头。

proc initRoute(kind: RouteKind, modelId = "", protocol = "",
               allowed: seq[string] = @[]): Route =
  Route(kind: kind, modelId: modelId, protocol: protocol, allowed: allowed)

proc normalizePath*(path: string): string =
  ## 规范化请求路径。
  ##
  ## 去掉查询串与末尾斜杠,但**不改大小写**:URL 路径是大小写敏感的,
  ## 悄悄小写化会让 `/API/Models` 也能工作,而真实的 OpenAI / Anthropic
  ## 端点并不接受它 —— 那种「我们这里能用」的差异会让客户端代码在切换
  ## 服务端时才失败。
  result = path
  let queryAt = result.find('?')
  if queryAt >= 0:
    result = result[0 ..< queryAt]
  let fragmentAt = result.find('#')
  if fragmentAt >= 0:
    result = result[0 ..< fragmentAt]
  while result.len > 1 and result.endsWith('/'):
    result.setLen(result.len - 1)
  if result.len == 0:
    result = "/"

proc protocolForPath*(path: string): string =
  ## 兼容协议路径 → 协议名。不是协议路径时返回空串。
  case path
  of OpenAiChatPath, OpenAiChatPathNoPrefix, "/completions": "openai-chat"
    # TRAE 把以 `/` 结尾的 base URL 与 `/chat/completions` 拼接后，请求行
    # 会变成 `//chat/completions`。std/uri 将其按 scheme-relative URI 解析，
    # 到路由层只剩 `/completions`，原始双斜杠已经无法恢复。该无前缀路径
    # 原本没有其它 Isvik 语义，因此将它定向到 Chat Adapter，而不是继续 404。
  of OpenAiResponsesPath, OpenAiResponsesPathNoPrefix: "openai-responses"
  of AnthropicMessagesPath: "anthropic"
  of NativeChatPath: "isvik-native"
  else: ""

proc endpointHintFor*(path: string): string =
  ## 对「形状很像但不匹配」的路径给出可操作提示,空串表示没有可靠猜测。
  ##
  ## 存在的理由:客户端常把 404 的响应体重新包装成自己的诊断,用户看到的可能是
  ## `empty content (HTTP Status: 502)` 这类与真实原因无关的文字。把「你大概想
  ## 要哪个端点」直接写进 404 的 message,`curl` 一次就能看到答案。
  ##
  ## 只在有**确定**答案时给提示。猜错方向比不猜更糟。
  let p = normalizePath(path)
  if p == "/completions":
    # 基地址以 / 结尾时,客户端拼出的 //chat/completions 会被解析成这个。
    return "The base URL must not end with a slash; expected " & OpenAiChatPath
  if p.contains("chat/completions"):
    return "Expected " & OpenAiChatPath & " or " & OpenAiChatPathNoPrefix &
      "; check for a duplicated or misspelled prefix"
  if p.endsWith("/messages"):
    return "Expected " & AnthropicMessagesPath &
      "; the base URL must not already contain /v1"
  if p.endsWith("/models"):
    return "Model listing is " & ModelsPath & "; OpenAI-style /v1/models is" &
      " not implemented"
  ""

proc resolveRoute*(httpMethod, rawPath: string): Route =
  ## 把方法 + 路径解析成一个动作。
  let path = normalizePath(rawPath)
  let verb = httpMethod.toUpperAscii()

  let protocol = protocolForPath(path)
  if protocol.len > 0:
    if verb != MethodPost:
      return initRoute(rkMethodNotAllowed, allowed = @[MethodPost])
    return initRoute(rkProtocolChat, protocol = protocol)

  # 模型详情:/api/models/<id>。放在固定路径判断之后,
  # 以免 `/api/models` 自己被当成「id 为空的详情」。
  if path.startsWith(ModelsPath & "/"):
    let id = path[(ModelsPath.len + 1) .. ^1]
    if id.len == 0 or id.contains('/'):
      # 多段路径不是本 API 的形状。不去猜它想要什么。
      return initRoute(rkNotFound)
    if verb != MethodGet:
      return initRoute(rkMethodNotAllowed, allowed = @[MethodGet])
    return initRoute(rkModelDetail, modelId = id)

  case path
  of "/api/version":
    if verb == MethodGet: initRoute(rkVersion)
    else: initRoute(rkMethodNotAllowed, allowed = @[MethodGet])
  of "/api/health":
    if verb == MethodGet: initRoute(rkHealth)
    else: initRoute(rkMethodNotAllowed, allowed = @[MethodGet])
  of ModelsPath:
    if verb == MethodGet: initRoute(rkModels)
    else: initRoute(rkMethodNotAllowed, allowed = @[MethodGet])
  of "/api/devices":
    if verb == MethodGet: initRoute(rkDevices)
    else: initRoute(rkMethodNotAllowed, allowed = @[MethodGet])
  of "/api/runtime":
    if verb == MethodGet: initRoute(rkRuntime)
    else: initRoute(rkMethodNotAllowed, allowed = @[MethodGet])
  of "/api/load":
    if verb == MethodPost: initRoute(rkLoad)
    else: initRoute(rkMethodNotAllowed, allowed = @[MethodPost])
  of "/api/unload":
    if verb == MethodPost: initRoute(rkUnload)
    else: initRoute(rkMethodNotAllowed, allowed = @[MethodPost])
  of "/api/chat":
    if verb == MethodPost: initRoute(rkChat)
    else: initRoute(rkMethodNotAllowed, allowed = @[MethodPost])
  of "/api/generate":
    if verb == MethodPost: initRoute(rkGenerate)
    else: initRoute(rkMethodNotAllowed, allowed = @[MethodPost])
  else:
    initRoute(rkNotFound)

proc isLoopbackHost*(host: string): bool =
  ## 该地址是否只在本机可达。
  ##
  ## §38 / §20.5.10:默认只监听回环。判断放在这里是为了让「绑定了对外地址」
  ## 这件事能在启动时被明确指出 —— 旧的无鉴权 `serve` 模式对外监听等于把本地
  ## 模型开放给同网段的所有人;启用 `--require-api-key` 时则由服务端执行凭据校验。
  let normalized = host.strip().toLowerAscii()
  normalized in ["127.0.0.1", "localhost", "::1", "[::1]"]
