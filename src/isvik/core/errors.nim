## Isvik 统一错误模型
##
## 设计要点(Master Prompt §22、§20.5.7、§68):
##
## 1. **错误码是 API 契约**。`IsvikErrorCode` 的字符串表示一旦发布就不得更改,
##    GUI / CLI / HTTP 客户端依据它做本地化与分支处理。
##    枚举的声明顺序无关紧要,但字符串值是稳定契约。
##
## 2. **message 不是契约**。它面向开发者与日志,内容可能随版本变化,
##    也不保证本地化。需要本地化文案的一方应根据 `code` 查自己的 i18n 表。
##
## 3. **detail 绝不进入 API 响应**。detail 用于承载文件路径、设备名、
##    底层错误串等排查信息,可能包含用户主目录等敏感内容。
##    `toJsonNode` 只输出 code 与 message(§22 规定的响应形状),
##    detail 仅出现在 `logLine` 中。这是有意的安全边界。
##
## 4. **Backend 错误必须先翻译成 IsvikError**。上层禁止直接接触
##    OpenVINO 的 exception 或 native error(§68)。翻译发生在
##    `src/isvik/backends/*`,本模块不感知任何 Backend 类型。
##
## 本模块只依赖 std,不得 import 任何 Backend 或 Resonance。

import std/[json, options]

type
  IsvikErrorCode* = enum
    ## 稳定错误码全集。
    ##
    ## 前 16 项来自 Master Prompt 的规定:
    ##   - §22「API Error Model」列出 13 项
    ##   - §20.5.7「API Error Translation」列出 16 项(§22 是其真子集)
    ## 两处的并集正是前 16 项。
    ##
    ## 第 17 项 `ecNotImplemented` 是 **Isvik 扩展**,不在上述两处列表中。
    ## 加入它的理由:§20.5.13 第 12 条要求「未实现的第三方 API 能力必须明确
    ## 返回 Unsupported,不得伪造完全兼容」,§14 要求 Registry 未实现时
    ## `pull` 不得伪装可用。原列表中没有能表达「该能力尚未实现」的码
    ## (`MODEL_UNSUPPORTED` 表达的是模型本身不被支持,语义不同),
    ## 若复用其它码会掩盖真实原因。

    # --- 模型相关 ---
    ecModelNotFound = "MODEL_NOT_FOUND"
    ecModelInvalid = "MODEL_INVALID"
    ecModelUnsupported = "MODEL_UNSUPPORTED"

    # --- 设备相关 ---
    ecDeviceNotAvailable = "DEVICE_NOT_AVAILABLE"
    ecNpuNotAvailable = "NPU_NOT_AVAILABLE"
    ecGpuNotAvailable = "GPU_NOT_AVAILABLE"

    # --- Backend 与执行相关 ---
    ecBackendNotAvailable = "BACKEND_NOT_AVAILABLE"
    ecCompilationFailed = "COMPILATION_FAILED"
    ecInferenceFailed = "INFERENCE_FAILED"

    # --- 请求相关 ---
    ecInvalidRequest = "INVALID_REQUEST"
    ecInvalidParameter = "INVALID_PARAMETER"
    ecUnauthorized = "UNAUTHORIZED"

    # --- 工具调用与流 ---
    ecToolCallFailed = "TOOL_CALL_FAILED"
    ecStreamCancelled = "STREAM_CANCELLED"

    # --- 缓存 ---
    ecCacheInvalid = "CACHE_INVALID"
    ecCacheCorrupted = "CACHE_CORRUPTED"

    # --- 服务端 ---
    ecServerError = "SERVER_ERROR"

    # --- Isvik 扩展(见上文说明)---
    ecNotImplemented = "NOT_IMPLEMENTED"

  IsvikError* = object of CatchableError
    ## Isvik 的统一异常类型。
    ##
    ## 继承自 CatchableError,因此 `msg` 字段来自基类。
    code*: IsvikErrorCode
    detail*: string
      ## 面向排查的补充信息,**不会**出现在 API 响应中。

const
  ## Master Prompt §22 明确列出的错误码。用于规范一致性测试。
  MasterPromptSection22Codes* = [
    "MODEL_NOT_FOUND",
    "MODEL_INVALID",
    "MODEL_UNSUPPORTED",
    "DEVICE_NOT_AVAILABLE",
    "NPU_NOT_AVAILABLE",
    "GPU_NOT_AVAILABLE",
    "BACKEND_NOT_AVAILABLE",
    "COMPILATION_FAILED",
    "INFERENCE_FAILED",
    "CACHE_INVALID",
    "CACHE_CORRUPTED",
    "INVALID_REQUEST",
    "SERVER_ERROR"
  ]

  ## Master Prompt §20.5.7 明确列出的错误码。
  MasterPromptSection2057Codes* = [
    "MODEL_NOT_FOUND",
    "MODEL_INVALID",
    "MODEL_UNSUPPORTED",
    "DEVICE_NOT_AVAILABLE",
    "NPU_NOT_AVAILABLE",
    "GPU_NOT_AVAILABLE",
    "BACKEND_NOT_AVAILABLE",
    "COMPILATION_FAILED",
    "INFERENCE_FAILED",
    "INVALID_REQUEST",
    "INVALID_PARAMETER",
    "TOOL_CALL_FAILED",
    "STREAM_CANCELLED",
    "CACHE_INVALID",
    "CACHE_CORRUPTED",
    "SERVER_ERROR"
  ]

# ---------------------------------------------------------------------------
# 默认消息
# ---------------------------------------------------------------------------

proc defaultMessage*(code: IsvikErrorCode): string =
  ## 每个错误码的默认英文消息。
  ##
  ## 使用英文是有意的:message 面向开发者与日志,而面向最终用户的文案由
  ## GUI / CLI 依据 `code` 从各自的 i18n 表中取(§22「GUI 根据 Error Code 本地化」)。
  case code
  of ecModelNotFound: "The requested model was not found"
  of ecModelInvalid: "The model is malformed or failed validation"
  of ecModelUnsupported: "The model format or architecture is not supported"
  of ecDeviceNotAvailable: "The requested device is not available"
  of ecNpuNotAvailable: "No Intel NPU is available in the current environment"
  of ecGpuNotAvailable: "No Intel GPU is available in the current environment"
  of ecBackendNotAvailable: "The inference backend is not available"
  of ecCompilationFailed: "Model compilation failed"
  of ecInferenceFailed: "Inference execution failed"
  of ecInvalidRequest: "The request is malformed"
  of ecInvalidParameter: "One or more parameters are invalid"
  of ecUnauthorized: "The API key is missing or invalid"
  of ecToolCallFailed: "Tool call execution failed"
  of ecStreamCancelled: "The stream was cancelled"
  of ecCacheInvalid: "The cache entry is invalid and must be rebuilt"
  of ecCacheCorrupted: "The cache entry is corrupted"
  of ecServerError: "Internal server error"
  of ecNotImplemented: "This capability is not implemented yet"

# ---------------------------------------------------------------------------
# 构造与抛出
# ---------------------------------------------------------------------------

proc newIsvikError*(
  code: IsvikErrorCode,
  msg: string = "",
  detail: string = ""
): ref IsvikError =
  ## 构造一个 IsvikError。msg 为空时使用该 code 的默认消息。
  result = newException(IsvikError, if msg.len > 0: msg else: defaultMessage(code))
  result.code = code
  result.detail = detail

proc raiseIsvikError*(
  code: IsvikErrorCode,
  msg: string = "",
  detail: string = ""
) {.noreturn.} =
  ## 抛出 IsvikError。这是 Isvik 内部报错的标准入口。
  raise newIsvikError(code, msg, detail)

# ---------------------------------------------------------------------------
# 序列化
# ---------------------------------------------------------------------------

proc errorJson*(code: IsvikErrorCode, message: string): JsonNode =
  ## 构造 §22 规定的错误响应结构:
  ##
  ## ```json
  ## { "error": { "code": "NPU_NOT_AVAILABLE", "message": "..." } }
  ## ```
  ##
  ## 使用 std/json 构造而非字符串拼接,由它负责转义,
  ## 避免 message 中的引号、换行、控制字符破坏 JSON 结构。
  %*{
    "error": {
      "code": $code,
      "message": message
    }
  }

proc toJsonNode*(e: ref IsvikError): JsonNode =
  ## 将异常转为 API 响应结构。
  ##
  ## 注意:**不包含 detail**。detail 可能含有本地路径等敏感信息,
  ## 只允许出现在日志中(见 `logLine`)。
  errorJson(e.code, e.msg)

proc toJson*(e: ref IsvikError): string =
  ## API 响应的 JSON 字符串形式。
  $e.toJsonNode()

proc logLine*(e: ref IsvikError): string =
  ## 面向日志与开发者的单行表示,包含 detail。
  ##
  ## 绝不可用于 API 响应。
  result = $e.code & ": " & e.msg
  if e.detail.len > 0:
    result.add(" | detail: " & e.detail)

# ---------------------------------------------------------------------------
# 解析
# ---------------------------------------------------------------------------

proc tryParseIsvikErrorCode*(s: string): Option[IsvikErrorCode] =
  ## 从稳定字符串解析回错误码。用于跨进程 / 跨协议边界还原错误。
  ##
  ## 未知字符串返回 none,而不是抛异常或静默回落到某个默认码 ——
  ## 静默回落会把「收到了不认识的错误码」这一事实丢掉。
  for code in IsvikErrorCode:
    if $code == s:
      return some(code)
  result = none(IsvikErrorCode)
