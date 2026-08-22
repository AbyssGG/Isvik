## OpenVINO / Resonance 错误 → Isvik 统一错误模型
##
## 对应 Master Prompt §9(Backend)、§22(API Error Model)、§68(OpenVINO
## Error Handling)。
##
## ---
##
## ## 为什么需要这一层
##
## `core/errors.nim` 定义的 17 个错误码是 Isvik 对外的**稳定契约**,会出现在
## API 响应、日志与 GUI 的本地化查表中。OpenVINO 的 `ov_status_e` 是另一套
## 18 个值的枚举,且**跨版本变动**。两者必须解耦:
##
## ```text
## OpenVinoError(status: OvStatus)  ──►  IsvikError(code: IsvikErrorCode)
## OpenVinoUnavailableError         ──►  IsvikError(BACKEND_NOT_AVAILABLE)
## ```
##
## 不这么做的后果:OpenVINO 升级改了状态码数值,Isvik 的对外错误码就跟着变,
## 而那是承诺稳定的东西。
##
## ---
##
## ## 关键设计:上下文优先于状态码
##
## 同一个 `ov_status_e` 在不同调用点意味着完全不同的问题。最典型的是
## `NOT_FOUND`:
##
## - 出现在 `readModel` 时 → 模型文件找不到 → `MODEL_NOT_FOUND`
## - 出现在 `compileModel` 时 → 设备名不存在 → `DEVICE_NOT_AVAILABLE`
## - 出现在 `importModel` 时 → blob 文件找不到 → `CACHE_INVALID`
##
## 所以映射函数**以操作上下文为主参数**,状态码只用于在同一上下文内细分。
## 反过来做(先按状态码分流)会得到一堆无法区分的 `SERVER_ERROR`。
##
## ---
##
## ## detail 里放什么,不放什么
##
## `IsvikError.detail` 只进日志、绝不进 API 响应(见 core/errors.nim)。
## 因此这里可以放原始状态码、OpenVINO 的原始错误串、以及路径 ——
## 这些是排查所必需的,但把路径暴露到 HTTP 响应里等于泄漏文件系统布局。

import std/strutils

import isvik/core/errors

import resonance

type
  OvOperation* = enum
    ## Backend 操作上下文。决定同一个状态码该映射成哪个 Isvik 错误码。
    ##
    ## 与 `Backend` 的方法一一对应,而不是与 OpenVINO 的 C 函数对应 ——
    ## 上层关心的是「哪个操作失败了」。
    ovOpInitialize = "initialize"
    ovOpRegisterExtension = "registerExtension"
    ovOpDiscoverDevices = "discoverDevices"
    ovOpQueryVersion = "queryVersion"
    ovOpLoadModel = "loadModel"
    ovOpCompileModel = "compileModel"
    ovOpExportCompiledModel = "exportCompiledModel"
    ovOpImportCompiledModel = "importCompiledModel"
    ovOpCreateInferRequest = "createInferRequest"
    ovOpSetInputTensor = "setInputTensor"
    ovOpGetOutputTensor = "getOutputTensor"
    ovOpInfer = "infer"
    ovOpRelease = "release"

proc defaultCodeFor*(op: OvOperation): IsvikErrorCode =
  ## 各操作失败时的默认错误码(状态码无法提供更精确信息时使用)。
  case op
  of ovOpInitialize, ovOpDiscoverDevices, ovOpQueryVersion:
    ecBackendNotAvailable
  of ovOpRegisterExtension:
    # 扩展注册失败几乎总是「DLL 找不到 / 位数不对 / 依赖缺失」,
    # 也就是运行时环境不完整,而不是模型有问题。
    ecBackendNotAvailable
  of ovOpLoadModel:
    ecModelInvalid
  of ovOpCompileModel:
    ecCompilationFailed
  of ovOpExportCompiledModel:
    # 导出失败最常见的原因是磁盘写不进去(权限 / 空间 / 路径非法),
    # 而不是缓存内容有问题 —— 那时缓存还不存在。
    ecServerError
  of ovOpImportCompiledModel:
    ecCacheInvalid
  of ovOpCreateInferRequest, ovOpSetInputTensor, ovOpGetOutputTensor, ovOpInfer:
    ecInferenceFailed
  of ovOpRelease:
    ecServerError

proc mapStatus*(op: OvOperation, status: OvStatus): IsvikErrorCode =
  ## 在给定操作上下文下,把 OpenVINO 状态码映射为 Isvik 错误码。
  ##
  ## 只对「状态码确实能提供比上下文更精确的信息」的组合做细分,
  ## 其余一律回落到 `defaultCodeFor(op)`。刻意不为每个状态码都编一个映射:
  ## 猜出来的精确度比诚实的笼统更有害。
  case op
  of ovOpLoadModel:
    case status
    of NOT_FOUND, NETWORK_NOT_READ:
      # 文件不存在,或存在但读不成模型。前者是 NOT_FOUND,
      # 后者 OpenVINO 也常报 NETWORK_NOT_READ —— 两者对用户是同一类问题:
      # 「这个路径给不出一个可用的模型」。
      ecModelNotFound
    of NOT_IMPLEMENTED, NOT_IMPLEMENT_C_METHOD:
      # 格式能识别但这个版本的 OpenVINO 不支持。
      ecModelUnsupported
    else:
      ecModelInvalid
  of ovOpCompileModel:
    case status
    of NOT_FOUND:
      # 编译阶段的 NOT_FOUND 通常是设备名不存在,而不是模型不见了 ——
      # 模型在这一步已经是内存里的对象了。
      ecDeviceNotAvailable
    of NOT_IMPLEMENTED, NOT_IMPLEMENT_C_METHOD:
      # 模型里有该设备不支持的算子。
      ecModelUnsupported
    else:
      ecCompilationFailed
  of ovOpImportCompiledModel:
    case status
    of NOT_FOUND:
      ecCacheInvalid
    of NETWORK_NOT_READ, UNEXPECTED:
      # blob 读进来了但内容不对 —— 版本不匹配或文件损坏。
      # 两者难以从状态码区分,统一报 CORRUPTED 并把状态码放进 detail。
      ecCacheCorrupted
    else:
      ecCacheInvalid
  of ovOpInfer, ovOpSetInputTensor, ovOpGetOutputTensor:
    case status
    of INFER_CANCELLED:
      # Isvik 的码表里没有独立的 INFERENCE_CANCELLED,取消语义统一由
      # STREAM_CANCELLED 表达(§20.5.7)。这是合理的对齐:推理被取消在
      # Isvik 里只可能源自调用方取消了请求/流,不存在「推理自己取消了」
      # 这种情况。刻意不为此新增第 18 个错误码 —— 错误码是对外稳定契约,
      # 能用现有语义表达就不该扩张。
      ecStreamCancelled
    of PARAMETER_MISMATCH, INVALID_C_PARAM, OUT_OF_BOUNDS:
      # 张量形状 / 类型 / 索引与模型端口不匹配 —— 这是调用方传错了,
      # 不是推理本身失败,报 INVALID_PARAMETER 才能让调用方知道该改什么。
      ecInvalidParameter
    else:
      ecInferenceFailed
  else:
    defaultCodeFor(op)

proc describeStatus(status: OvStatus): string =
  ## 状态码的可读描述,含数值。
  ##
  ## 数值必须带上:跨版本枚举漂移时,数值是唯一能对上官方头文件的线索。
  ## 同时附上 OpenVINO 自己的静态描述(若可取)。
  result = $status & "(" & $ord(status) & ")"
  let info = ov_get_error_info(status)
  # 注意:ov_get_error_info 返回的指针由 OpenVINO 拥有且进程生命周期有效,
  # 禁止 ov_free —— 见 Resonance c_api.nim 该函数的注释。
  if info != nil:
    let text = $info
    if text.len > 0:
      result.add(" " & text)

proc raiseMapped*(op: OvOperation, e: ref OpenVinoError,
                  context: string = "") {.noreturn.} =
  ## 把 Resonance 的 `OpenVinoError` 转成 `IsvikError` 并抛出。
  ##
  ## `context` 是调用点补充的信息(路径、设备名、索引等),会进入 detail。
  let code = mapStatus(op, e.status)
  var detail = "operation=" & $op &
    " ovStatus=" & describeStatus(e.status) &
    " ovAction=" & e.action
  if context.len > 0:
    detail.add(" " & context)
  # 原始消息里含 OpenVINO 的 last-error 串,是排查的主要依据。
  # 换行会破坏单行日志格式,压成空格。
  detail.add(" ovMessage=" & e.msg.replace("\n", " ").replace("\r", ""))
  raiseIsvikError(code, defaultMessage(code), detail)

proc raiseUnavailable*(op: OvOperation, e: ref CatchableError,
                       context: string = "") {.noreturn.} =
  ## OpenVINO 运行时根本不可用(DLL 缺失 / 符号缺失)时的映射。
  ##
  ## 一律是 `BACKEND_NOT_AVAILABLE`,与具体操作无关 —— 这不是某个操作的问题,
  ## 是整个 Backend 用不了。§13 要求这种情况如实上报而不是崩溃。
  var detail = "operation=" & $op & " reason=runtime-unavailable"
  if context.len > 0:
    detail.add(" " & context)
  detail.add(" message=" & e.msg.replace("\n", " ").replace("\r", ""))
  raiseIsvikError(ecBackendNotAvailable, defaultMessage(ecBackendNotAvailable),
                  detail)

template guardOv*(op: OvOperation, context: string, body: untyped) =
  ## 把一段调用 Resonance 的代码包成「只会抛 IsvikError」。
  ##
  ## 存在的理由:`backends/openvino/` 是唯一能看到 `OpenVinoError` 的地方,
  ## 它**不能泄漏到 Core**(§5:OpenVINO 相关类型不得泄漏到上层)。
  ## 每个 method 手写 try/except 会重复十几遍,漏一个就是一个泄漏点。
  ##
  ## 捕获顺序有讲究:`OpenVinoUnavailableError` 必须排在
  ## `CatchableError` 之前,而它**不是** `OpenVinoError` 的子类
  ## (两者都直接继承 `CatchableError`),所以必须单独一个分支。
  try:
    body
  except OpenVinoUnavailableError as e:
    raiseUnavailable(op, e, context)
  except OpenVinoError as e:
    raiseMapped(op, e, context)
  except IsvikError:
    # 已经是 Isvik 错误(例如元素类型映射抛出的 NOT_IMPLEMENTED),
    # 原样放行 —— 再包一层只会丢失原本更精确的错误码。
    raise
