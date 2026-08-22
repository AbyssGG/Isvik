## Device Service 测试
##
## 分两档:
##
## ```text
## 第 1 档  纯策略      无条件。CPU 回落判据、设备请求规范化与合法性
## 第 2 档  真机查询    需要 openvino_c.dll,缺失时 SKIP 而不是 FAILED
## ```
##
## 第 1 档是本文件的重点。CPU 回落此前在 CLI 里被实现了两遍且判据不同,
## 下沉到服务后必须只有一条判据,而且这条判据要能被无硬件地反复验证。

import std/unittest

import isvik/core/errors
import isvik/services/device_service

import resonance except Tensor, newTensor

let openVinoUsable = tryLoadOpenVino()

suite "Device Service:设备请求规范化":

  test "空串等价 AUTO,大小写与空白被规范化":
    check normalizeDeviceRequest("") == DeviceRequestAuto
    check normalizeDeviceRequest("   ") == DeviceRequestAuto
    check normalizeDeviceRequest("auto") == DeviceRequestAuto
    check normalizeDeviceRequest("  cpu  ") == DeviceRequestCpu
    check normalizeDeviceRequest("Npu") == DeviceRequestNpu

  test "规范化不判断合法性,非法值原样返回":
    # 规范化与校验分开:否则「AUTO 是默认值」与「XPU 是非法值」会混在
    # 同一个返回值里,调用方无法区分。
    check normalizeDeviceRequest("xpu") == "XPU"

  test "合法设备请求通过校验":
    for value in ["", "  ", "auto", "AUTO", "cpu", "CPU", "gpu", "npu"]:
      validateDeviceRequest(value)
    check true

  test "非法设备请求在入口就报 INVALID_PARAMETER":
    # UnifiedInferenceRequest.validate() 有意不校验 device,于是非法值原本
    # 要等到编译阶段才失败。API 边界应该早拒。
    for bad in ["XPU", "cuda", "GPU.0", "npu2"]:
      var code = ecServerError
      var raised = false
      try:
        validateDeviceRequest(bad)
      except IsvikError as e:
        raised = true
        code = e.code
      check raised
      check code == ecInvalidParameter

  test "AUTO 与 CPU 判定":
    check isAutoRequest("")
    check isAutoRequest("auto")
    check not isAutoRequest("CPU")
    check isCpuRequest("cpu")
    check not isCpuRequest("")

suite "Device Service:CPU 回落判据只有一条":

  test "只有 AUTO 的编译失败允许回落":
    check allowsCpuFallback(ecCompilationFailed, "AUTO")
    check allowsCpuFallback(ecCompilationFailed, "auto")
    # 空串等价 AUTO,也允许。
    check allowsCpuFallback(ecCompilationFailed, "")
    check allowsCpuFallback(ecCompilationFailed, "  ")

  test "显式设备保留原始失败,不静默换 CPU":
    # §12:显式指定的设备不可用时必须报错。settings.json 里的
    # default_device: GPU 同样是用户的显式选择 —— 悄悄换成 CPU,
    # 「这台机器的 GPU 到底能不能跑」就永远得不到答案。
    check not allowsCpuFallback(ecCompilationFailed, "GPU")
    check not allowsCpuFallback(ecCompilationFailed, "NPU")

  test "已经是 CPU 时不再回落":
    # 否则会在同一个设备上重试同一件事。
    check not allowsCpuFallback(ecCompilationFailed, "CPU")

  test "非编译失败一律不回落":
    # 推理失败换设备无济于事,那是别的问题。
    for code in [ecInferenceFailed, ecModelNotFound, ecModelInvalid,
                 ecDeviceNotAvailable, ecNpuNotAvailable, ecGpuNotAvailable,
                 ecBackendNotAvailable, ecStreamCancelled, ecServerError,
                 ecCacheCorrupted, ecNotImplemented]:
      check not allowsCpuFallback(code, "AUTO")

suite "Device Service:关闭后的行为":

  test "nil 与已关闭服务的访问器不崩溃":
    let svc: DeviceService = nil
    check svc.backendName() == ""
    check svc.backendVersion() == ""
    # close 对 nil 安全,且可重复调用。
    svc.close()
    svc.close()
    check true

  test "已关闭服务上的查询报可诊断错误而不是崩溃":
    if not openVinoUsable:
      skip()
    else:
      let svc = openDeviceService()
      svc.close()
      svc.close()
      var code = ecServerError
      var raised = false
      try:
        discard svc.devices()
      except IsvikError as e:
        raised = true
        code = e.code
      check raised
      check code == ecInvalidParameter

suite "Device Service:真机查询(需要 openvino_c.dll)":

  test "报告运行时探测结果(信息性,不判定成败)":
    if openVinoUsable:
      checkpoint("OpenVINO 可用")
    else:
      checkpoint("OpenVINO 不可用:" & openVinoLoadError())
      checkpoint("本 suite 的其余用例将跳过")
    check true

  test "枚举设备并报告真实 Backend 版本":
    if not openVinoUsable:
      skip()
    else:
      let svc = openDeviceService()
      try:
        let devices = svc.devices()
        check devices.len > 0
        check svc.backendName().len > 0
        # 版本必须是真实读到的,不是编造的占位符。
        check svc.backendVersion().len > 0
        checkpoint("backend=" & svc.backendName() &
                   " version=" & svc.backendVersion())
        for d in devices:
          check d.rawName.len > 0
      finally:
        svc.close()

  test "AUTO 解析出的设备真实存在于枚举结果中":
    if not openVinoUsable:
      skip()
    else:
      let svc = openDeviceService()
      try:
        var names: seq[string] = @[]
        for d in svc.devices():
          names.add(d.rawName)
        let selection = svc.resolveDevice()
        checkpoint("AUTO -> " & selection.device.rawName)
        check selection.device.rawName in names
        check selection.usedAuto
        check selection.device.policyEligible
      finally:
        svc.close()

  test "显式 CPU 在任何机器上都可解析,且不算 AUTO":
    if not openVinoUsable:
      skip()
    else:
      let svc = openDeviceService()
      try:
        let cpu = svc.resolveDevice(DeviceRequestCpu)
        check cpu.device.deviceType == dtCpu
        check not cpu.usedAuto
      finally:
        svc.close()

  test "被策略排除的设备仍然可见,并带排除原因":
    # §27:被排除不等于不存在。把非 Intel GPU 抹掉会让用户以为驱动没装。
    if not openVinoUsable:
      skip()
    else:
      let svc = openDeviceService()
      try:
        let excluded = svc.excludedDevices()
        var names: seq[string] = @[]
        for d in svc.devices():
          names.add(d.rawName)
        for e in excluded:
          checkpoint("excluded " & e.device & ": " & e.reason)
          check e.device in names
          check e.reason.len > 0
        if excluded.len == 0:
          checkpoint("本机没有被策略排除的设备,该断言无对象")
        check true
      finally:
        svc.close()
