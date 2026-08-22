## Task 2 测试:统一错误模型
##
## 这些测试保护三件具体的事:
## 1. 错误码字符串是 API 契约 —— 逐个精确断言,防止改枚举时悄悄破坏客户端。
## 2. Master Prompt §22 / §20.5.7 列出的每个码都真实存在 —— 规范一致性。
## 3. detail 不泄漏进 API 响应 —— 安全边界。

import std/[unittest, json, options, sets, strutils]

import isvik/core/errors

suite "错误码是稳定的 API 契约":

  test "每个错误码的字符串表示逐个精确匹配":
    # 这里故意写成一长串显式断言而不是循环:
    # 循环只能验证「自己和自己一致」,显式字面量才能在有人改动枚举值时失败。
    check $ecModelNotFound == "MODEL_NOT_FOUND"
    check $ecModelInvalid == "MODEL_INVALID"
    check $ecModelUnsupported == "MODEL_UNSUPPORTED"
    check $ecDeviceNotAvailable == "DEVICE_NOT_AVAILABLE"
    check $ecNpuNotAvailable == "NPU_NOT_AVAILABLE"
    check $ecGpuNotAvailable == "GPU_NOT_AVAILABLE"
    check $ecBackendNotAvailable == "BACKEND_NOT_AVAILABLE"
    check $ecCompilationFailed == "COMPILATION_FAILED"
    check $ecInferenceFailed == "INFERENCE_FAILED"
    check $ecInvalidRequest == "INVALID_REQUEST"
    check $ecInvalidParameter == "INVALID_PARAMETER"
    check $ecToolCallFailed == "TOOL_CALL_FAILED"
    check $ecStreamCancelled == "STREAM_CANCELLED"
    check $ecCacheInvalid == "CACHE_INVALID"
    check $ecCacheCorrupted == "CACHE_CORRUPTED"
    check $ecServerError == "SERVER_ERROR"
    check $ecNotImplemented == "NOT_IMPLEMENTED"
    check $ecUnauthorized == "UNAUTHORIZED"

  test "错误码总数为 18(16 个规范码 + 2 个 Isvik 扩展码)":
    # 防止误删。新增码时应同时更新此数字并在 errors.nim 中说明来源。
    var count = 0
    for _ in IsvikErrorCode:
      inc count
    check count == 18

  test "错误码字符串两两互不相同":
    var seen = initHashSet[string]()
    for code in IsvikErrorCode:
      let s = $code
      check not seen.contains(s)
      seen.incl(s)
    check seen.len == 18

  test "错误码字符串只含大写字母与下划线":
    # 稳定的机器可读形式:不允许小写、空格、连字符混入。
    for code in IsvikErrorCode:
      let s = $code
      check s.len > 0
      check s.allCharsInSet({'A'..'Z', '_'})
      check not s.startsWith("_")
      check not s.endsWith("_")

suite "与 Master Prompt 规范保持一致":

  test "§22 列出的 13 个错误码全部存在":
    check MasterPromptSection22Codes.len == 13
    for s in MasterPromptSection22Codes:
      let parsed = tryParseIsvikErrorCode(s)
      check parsed.isSome
      if parsed.isSome:
        check $parsed.get == s

  test "§20.5.7 列出的 16 个错误码全部存在":
    check MasterPromptSection2057Codes.len == 16
    for s in MasterPromptSection2057Codes:
      check tryParseIsvikErrorCode(s).isSome

  test "§22 是 §20.5.7 的子集(记录规范内部关系)":
    let broad = MasterPromptSection2057Codes.toHashSet
    for s in MasterPromptSection22Codes:
      check broad.contains(s)

  test "除 NOT_IMPLEMENTED 与 UNAUTHORIZED 外没有多余的自造错误码":
    # 保证实现没有偷偷发明规范之外的码。扩展码在这里显式排除，不伪造 Master Prompt 列表。
    let allowed = MasterPromptSection2057Codes.toHashSet
    for code in IsvikErrorCode:
      if code == ecNotImplemented or code == ecUnauthorized:
        continue
      check allowed.contains($code)

suite "默认消息":

  test "每个错误码都有非空默认消息":
    for code in IsvikErrorCode:
      check defaultMessage(code).len > 0

  test "默认消息两两不同,避免不同错误看起来一样":
    var seen = initHashSet[string]()
    for code in IsvikErrorCode:
      let m = defaultMessage(code)
      check not seen.contains(m)
      seen.incl(m)

suite "构造与抛出":

  test "未指定 msg 时使用默认消息":
    let e = newIsvikError(ecNpuNotAvailable)
    check e.code == ecNpuNotAvailable
    check e.msg == defaultMessage(ecNpuNotAvailable)
    check e.detail == ""

  test "显式 msg 与 detail 被保留":
    let e = newIsvikError(ecCompilationFailed, "compile failed on NPU", "device=NPU.0")
    check e.code == ecCompilationFailed
    check e.msg == "compile failed on NPU"
    check e.detail == "device=NPU.0"

  test "raiseIsvikError 可被作为 IsvikError 捕获并读回 code":
    var caught = false
    try:
      raiseIsvikError(ecCacheCorrupted, "bad blob", "path=C:/x/y.blob")
    except IsvikError as e:
      caught = true
      check e.code == ecCacheCorrupted
      check e.msg == "bad blob"
      check e.detail == "path=C:/x/y.blob"
    check caught

  test "IsvikError 可被作为 CatchableError 捕获":
    # 保证它融入 Nim 标准异常体系,调用方可以做粗粒度兜底。
    var caught = false
    try:
      raiseIsvikError(ecServerError)
    except CatchableError:
      caught = true
    check caught

suite "JSON 序列化形状符合 §22":

  test "响应恰好是 {\"error\":{\"code\":..,\"message\":..}}":
    let node = errorJson(ecNpuNotAvailable, "no NPU here")
    check node.kind == JObject
    check node.len == 1
    check node.hasKey("error")

    let err = node["error"]
    check err.kind == JObject
    check err.len == 2
    check err.hasKey("code")
    check err.hasKey("message")
    check err["code"].getStr == "NPU_NOT_AVAILABLE"
    check err["message"].getStr == "no NPU here"

  test "detail 不出现在 API 响应中(安全边界)":
    # detail 可能包含用户主目录等敏感路径,绝不允许出现在响应里。
    let secret = "C:/Users/SomeUser/.isvik/models/private.xml"
    let e = newIsvikError(ecModelInvalid, "bad model", secret)
    let json = e.toJson()
    check not json.contains(secret)
    check not json.contains("detail")
    check e.toJsonNode()["error"].len == 2

  test "detail 出现在日志行中":
    let e = newIsvikError(ecModelInvalid, "bad model", "path=x.xml")
    let line = e.logLine()
    check line.contains("MODEL_INVALID")
    check line.contains("bad model")
    check line.contains("path=x.xml")

  test "无 detail 时日志行不带 detail 段":
    let e = newIsvikError(ecServerError, "boom")
    check e.logLine() == "SERVER_ERROR: boom"

  test "message 中的特殊字符被正确转义且可回解析":
    # 真实风险:OpenVINO 的错误串常含引号、换行与路径反斜杠,
    # 若用字符串拼接生成 JSON 会产出非法 JSON。
    let nasty = "he said \"boom\"\n\tpath=C:\\models\\a.xml \\ 中文 \u0001"
    let e = newIsvikError(ecInferenceFailed, nasty)
    let text = e.toJson()
    let reparsed = parseJson(text)
    check reparsed["error"]["message"].getStr == nasty
    check reparsed["error"]["code"].getStr == "INFERENCE_FAILED"

  test "所有错误码都能生成合法 JSON":
    for code in IsvikErrorCode:
      let text = $errorJson(code, defaultMessage(code))
      let reparsed = parseJson(text)
      check reparsed["error"]["code"].getStr == $code

suite "解析":

  test "所有错误码可往返 字符串 -> 枚举":
    for code in IsvikErrorCode:
      let parsed = tryParseIsvikErrorCode($code)
      check parsed.isSome
      check parsed.get == code

  test "未知字符串返回 none 而不是静默回落":
    # 静默回落会丢掉「收到了不认识的错误码」这一事实。
    check tryParseIsvikErrorCode("NOT_A_REAL_CODE").isNone
    check tryParseIsvikErrorCode("").isNone
    check tryParseIsvikErrorCode("model_not_found").isNone  # 大小写敏感
    check tryParseIsvikErrorCode(" MODEL_NOT_FOUND").isNone # 不做 trim
