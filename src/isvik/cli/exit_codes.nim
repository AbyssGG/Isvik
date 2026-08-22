## 错误码 → 进程退出码
##
## ---
##
## ## 为什么需要这张表
##
## 脚本与 CI 只能看到退出码。如果所有失败都返回 1,调用方无法区分
## 「用户传错了参数」和「运行时炸了」—— 前者应当停下来改命令,
## 后者可能值得重试或去查环境。这两类需要完全不同的处理。
##
## 这条经验来自 NimVoice(见 DEVLOG 第六节第 5 条),Isvik 沿用同一约定。
##
## ---
##
## ## 分组依据是「调用方接下来该做什么」,不是错误的技术分类
##
## ```text
## 2    改命令              参数 / 请求本身不对
## 3    换模型或先导入      模型找不到、损坏、不受支持
## 4    换设备或查驱动      设备不可用
## 5    装或修运行时        Backend 加载不起来
## 6    看模型与设备组合    编译 / 推理 / 工具调用失败
## 7    清缓存后重试        缓存失效或损坏
## 8    别再试              该能力尚未实现
## 130  不是故障            用户主动取消
## 1    其它内部错误
## ```
##
## 这样分组的好处是脚本可以直接按退出码分支,不必解析 stderr 文本 ——
## 文本会随版本和语言变化,退出码是契约。
##
## `130` 沿用 Unix 的 `128 + SIGINT(2)` 约定,让「被取消」不被误判为故障。

import isvik/core/errors

const
  ExitSuccess* = 0
    ## 成功。

  ExitFailure* = 1
    ## 未分类的内部错误(SERVER_ERROR 及非 IsvikError 的意外异常)。

  ExitUsage* = 2
    ## 用法错误:未知命令、缺参数、非法参数取值。
    ## 与多数 Unix 工具的约定一致。

  ExitModel* = 3
    ## 模型相关:找不到、格式错误、不受支持。

  ExitDevice* = 4
    ## 设备相关:请求的设备不可用(含 NPU / GPU 专用错误码)。

  ExitBackend* = 5
    ## 推理 Backend 不可用(通常是运行时缺失或加载失败)。

  ExitExecution* = 6
    ## 执行阶段失败:编译、推理、工具调用。

  ExitCache* = 7
    ## 缓存失效或损坏。

  ExitNotImplemented* = 8
    ## 该能力尚未实现。与「失败」明确区分 —— 重试没有意义。

  ExitCancelled* = 130
    ## 被取消。128 + SIGINT(2),不视为故障。

proc exitCodeFor*(code: IsvikErrorCode): int =
  ## 错误码到退出码的映射。
  ##
  ## 使用穷尽的 `case`(**没有 else**)是有意的:新增错误码时编译器会在这里
  ## 报「不是所有分支都覆盖」,强制作者决定它归哪一类。写
  ## `else: ExitFailure` 会让新错误码悄悄落进「未分类」。
  case code
  of ecModelNotFound, ecModelInvalid, ecModelUnsupported:
    ExitModel
  of ecDeviceNotAvailable, ecNpuNotAvailable, ecGpuNotAvailable:
    ExitDevice
  of ecBackendNotAvailable:
    ExitBackend
  of ecCompilationFailed, ecInferenceFailed, ecToolCallFailed:
    ExitExecution
  of ecInvalidRequest, ecInvalidParameter, ecUnauthorized:
    ExitUsage
  of ecStreamCancelled:
    ExitCancelled
  of ecCacheInvalid, ecCacheCorrupted:
    ExitCache
  of ecServerError:
    ExitFailure
  of ecNotImplemented:
    ExitNotImplemented

proc exitCodeFor*(e: ref IsvikError): int =
  ## 异常到退出码。nil 视为成功,便于调用方无分支处理。
  if e == nil: ExitSuccess else: exitCodeFor(e.code)
