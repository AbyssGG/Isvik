## 设备应用服务(Master Prompt §20)
##
## ---
##
## ## 它做什么
##
## ```text
## 做:   Runtime 生命周期的成对管理    initialize / shutdown 不再散落在各前端
##       语义设备枚举与 AUTO 解析      转发给 Core,但由本层负责资源配对
##       「被策略排除」的聚合          GUI / CLI / API 都要展示同一份事实
##       CPU 回落是否被允许            纯策略函数,三个前端共用同一条判据
##
## 不做: 设备分类与 AUTO 优先级        那是 core/device_manager 的职责
##       调用 OpenVINO                 §20.5.11:应用层不接触 Backend 细节
##       界面文案                      本模块不 import i18n,理由见 model_service
## ```
##
## ---
##
## ## 为什么 CPU 回落的判据必须只有一份
##
## 回落之前被实现了两遍(`cli/cmd_chat` 与 `cli/workbench`),而两遍的判据
## **并不相同**:一处只看 `--device` 是否显式给出,另一处要求请求必须是 AUTO。
## 于是同一个「settings 里写了 GPU」的用户,走 `isvik chat` 会被静默换到 CPU,
## 走工作台则会看到真实的编译失败。
##
## 本模块采纳后者:**只有 AUTO 允许回落。**
##
## 理由是 §12 —— 显式指定的设备不可用时必须报错,不得静默回落。`settings.json`
## 里的 `default_device: GPU` 同样是用户的显式选择,把它悄悄换成 CPU,
## 「这台机器的 GPU 到底能不能跑」就永远得不到答案。

import std/strutils

import isvik/core/errors
import isvik/core/device_manager
import isvik/core/runtime
import isvik/backends/factory

export device_manager

type
  DeviceService* = ref object
    ## 持有一个专用于设备查询的 Runtime。
    ##
    ## 与 `ChatSession` 相同的资源约定:构造事务化、`close` 幂等。
    ## Runtime 的 initialize 成功后必须 shutdown,否则原生 Core 会一直
    ## 留到进程退出才释放。
    rt: Runtime
    closed: bool

  ExcludedDevice* = object
    ## 存在、但不进入 AUTO 候选的设备。
    ##
    ## 必须可见(§27):被策略排除**不等于**不存在。把非 Intel GPU 直接
    ## 从列表里抹掉,用户会以为驱动没装。
    device*: string
    reason*: string

proc openDeviceService*(): DeviceService =
  ## 创建并初始化设备服务。
  let rt = newRuntime(newInferenceBackend())
  rt.initialize()
  try:
    new(result)
    result.rt = rt
    result.closed = false
  except CatchableError:
    rt.shutdown()
    raise

proc close*(svc: DeviceService) =
  ## 释放服务。可重复调用。
  if svc == nil or svc.closed:
    return
  svc.closed = true
  if svc.rt != nil:
    svc.rt.shutdown()

proc requireOpen(svc: DeviceService, operation: string) =
  if svc == nil or svc.closed or svc.rt == nil:
    raiseIsvikError(ecInvalidParameter, "Device service is closed",
                    "operation=" & operation)

proc runtime*(svc: DeviceService): Runtime =
  ## 暴露底层 Runtime,供需要编译模型的调用方复用同一个 Backend 实例。
  svc.requireOpen("runtime")
  svc.rt

proc backendName*(svc: DeviceService): string =
  if svc == nil or svc.closed or svc.rt == nil: "" else: svc.rt.backendName

proc backendVersion*(svc: DeviceService): string =
  if svc == nil or svc.closed or svc.rt == nil: "" else: svc.rt.backendVersion

proc devices*(svc: DeviceService,
              forceRefresh: bool = false): seq[DeviceInfo] =
  ## 语义设备列表。
  svc.requireOpen("devices")
  svc.rt.semanticDevices(forceRefresh)

proc resolveDevice*(svc: DeviceService,
                    requested: string = DeviceRequestAuto,
                    excluded: seq[string] = @[]): DeviceSelection =
  ## 解析语义设备请求。空串等价 AUTO。
  ##
  ## `excluded` 只对 AUTO 生效,语义见 `core/device_manager.resolveDevice`。
  svc.requireOpen("resolveDevice")
  svc.rt.resolveDevice(requested, excluded)

proc excludedDevices*(svc: DeviceService): seq[ExcludedDevice] =
  ## 汇总「可用但被策略排除」的设备。
  result = @[]
  for d in svc.devices():
    if d.available and not d.policyEligible:
      result.add(ExcludedDevice(device: d.rawName, reason: d.exclusionReason))

# ---------------------------------------------------------------------------
# 纯策略:不需要 Runtime,可独立测试
# ---------------------------------------------------------------------------

proc normalizeDeviceRequest*(requested: string): string =
  ## 规范化设备请求:去空白、转大写、空串视为 AUTO。
  ##
  ## 只做形状规范化,**不判断合法性** —— 那由 `validateDeviceRequest` 负责,
  ## 两件事分开是为了让「AUTO 是默认值」与「XPU 是非法值」不会混在一个
  ## 返回值里。
  let trimmed = requested.strip().toUpperAscii()
  if trimmed.len == 0: DeviceRequestAuto else: trimmed

proc validateDeviceRequest*(requested: string) =
  ## 在**请求入口**拒绝非法设备名。
  ##
  ## `UnifiedInferenceRequest.validate()` 有意不校验 device(那需要 Core 的
  ## 设备知识),于是非法值原本要等到编译阶段才失败。API 边界应该早拒。
  discard parseDeviceRequest(normalizeDeviceRequest(requested))

proc isAutoRequest*(requested: string): bool =
  ## 是否把设备决定权交给了 Runtime Policy。空串与 AUTO 等价。
  normalizeDeviceRequest(requested) == DeviceRequestAuto

proc isCpuRequest*(requested: string): bool =
  ## 是否请求的就是 CPU。已经在 CPU 上失败时,再回落一次没有意义。
  normalizeDeviceRequest(requested) == DeviceRequestCpu

proc allowsCpuFallback*(code: IsvikErrorCode, requested: string): bool =
  ## 这次失败是否允许改用 CPU 重试。
  ##
  ## 三个条件同时成立才允许:
  ##
  ## 1. 失败是**编译**失败。推理失败换设备无济于事,那是别的问题。
  ## 2. 请求是 AUTO。显式设备(含 settings 里配置的)必须保留原始失败(§12)。
  ## 3. 原请求不是 CPU。否则会在同一个设备上重试同一件事。
  code == ecCompilationFailed and
    isAutoRequest(requested) and
    not isCpuRequest(requested)
