## Device Manager 在**真实设备快照**上的验证(Task 10 收尾)
##
## ---
##
## ## 为什么这个文件必须存在
##
## `tests/core/tdevice_manager.nim` 用的是模拟 `BackendDeviceInfo`,它能证明
## 策略逻辑正确,但**不能证明解析器认得真机的属性字符串**。vendor 是从
## `DEVICE_ARCHITECTURE` 里抠出来的,而那个字符串的格式(本机实测是
## `GPU: vendor=0x8086 arch=v12.70.4`)完全由 OpenVINO 决定 —— 一旦格式与
## 假设不符,模拟测试全绿而真机上所有 GPU 都会被判成「vendor 未知」,
## 进而永远进不了 AUTO 候选。
##
## §52 要求「获取真实设备信息」。这个文件就是那一条的证据。
##
## ---
##
## ## 它刻意不断言什么
##
## **不断言本机有 NPU 或 GPU。** 那是机器相关的,写进断言会让这个测试在
## 别人的机器上无故失败。它断言的是**不变量**:
##
## - 每个被 Backend 报告的设备都能被分类,不会落进 UNKNOWN
## - `GPU.N` 一定能解析出序号
## - 报告了 architecture 的 GPU 一定能解析出 vendor
## - AUTO 选中的设备一定真实存在于设备列表中
## - 被策略排除的设备仍然可见,不会被当作缺失

import std/unittest

import isvik/core/errors
import isvik/core/backend
import isvik/core/device_manager
import isvik/core/runtime
import isvik/backends/openvino/ov_backend

import resonance except Tensor, newTensor

let openVinoUsable = tryLoadOpenVino()

proc realDevices(): seq[BackendDeviceInfo] =
  ## 取一次真实设备快照。调用方需先确认 OpenVINO 可用。
  let b = newOpenVinoBackend()
  b.initialize()
  try:
    result = b.discoverDevices()
  finally:
    b.release()

suite "真机设备解析(需要 openvino_c.dll)":

  test "报告运行时探测结果(信息性,不判定成败)":
    if openVinoUsable:
      checkpoint("OpenVINO 可用")
    else:
      checkpoint("OpenVINO 不可用:" & openVinoLoadError())
      checkpoint("本 suite 的其余用例将跳过")
    check true

  test "Backend 报告的每个设备都能被分类,不落进 UNKNOWN":
    if not openVinoUsable:
      skip()
    else:
      let raw = realDevices()
      check raw.len > 0

      let manager = newDeviceManager("openvino", raw)
      let devices = manager.devices()
      check devices.len == raw.len

      for d in devices:
        checkpoint(d.rawName & " type=" & $d.deviceType &
                   " vendor=" & d.vendor &
                   " vendorId=" & (if d.vendorId.len > 0: d.vendorId else: "-") &
                   " eligible=" & $d.policyEligible &
                   " arch=" & (if d.architecture.len > 0: d.architecture else: "-"))
        # 失败说明 OpenVINO 报了一个 Isvik 还不认识的设备标识。
        # 那需要人来决定它该怎么归类,而不是让它悄悄落进某个默认分支。
        check d.deviceType != dtUnknown
        check d.available
        check d.rawName.len > 0

  test "GPU.N 一定能解析出序号,且序号与 rawName 一致":
    if not openVinoUsable:
      skip()
    else:
      let manager = newDeviceManager("openvino", realDevices())
      var gpuCount = 0
      for d in manager.devices():
        if d.deviceType != dtGpu:
          continue
        inc gpuCount
        if d.rawName.contains('.'):
          check d.deviceId.ordinal >= 0
          check d.rawName == "GPU." & $d.deviceId.ordinal
      checkpoint("GPU 实例数=" & $gpuCount)
      check true

  test "报告了 architecture 的 GPU 必须能解析出 vendor":
    # 本文件最核心的一条:把「解析器认得真机字符串」变成断言。
    if not openVinoUsable:
      skip()
    else:
      let manager = newDeviceManager("openvino", realDevices())
      var checked = 0
      for d in manager.devices():
        if d.deviceType != dtGpu or d.architecture.len == 0:
          continue
        inc checked
        checkpoint(d.rawName & " architecture=" & d.architecture &
                   " -> vendorId=" & d.vendorId & " vendor=" & d.vendor)
        # 解析失败会让 vendorId 为空,进而使该 GPU 永远进不了 Intel 策略。
        check d.vendorId.len > 0
        check d.vendor != "Unknown"
      if checked == 0:
        checkpoint("本机没有报告 DEVICE_ARCHITECTURE 的 GPU,该断言无对象")
      check true

  test "Intel 与非 Intel GPU 的策略资格判定一致":
    if not openVinoUsable:
      skip()
    else:
      let manager = newDeviceManager("openvino", realDevices())
      for d in manager.devices():
        if d.deviceType != dtGpu:
          continue
        if d.vendorId == IntelVendorId:
          check d.vendor == "Intel"
          check d.policyEligible
          check d.exclusionReason == ""
        elif d.vendorId.len > 0:
          # 非 Intel GPU 必须「可见但被排除」,不能被当作不存在(§27)。
          check not d.policyEligible
          check d.exclusionReason.len > 0
          check d.available
      check true

  test "AUTO 选中的设备真实存在,且报告实际 rawName":
    if not openVinoUsable:
      skip()
    else:
      let raw = realDevices()
      var rawNames: seq[string] = @[]
      for r in raw:
        rawNames.add(r.rawName)

      let manager = newDeviceManager("openvino", raw)
      let selection = manager.resolveDevice(DeviceRequestAuto)

      checkpoint("AUTO -> " & selection.device.rawName &
                 " (" & $selection.device.deviceType & ") " & selection.reason)
      # 选中的必须是 Backend 真的报告过的设备,不能是凭空构造的名字。
      check selection.device.rawName in rawNames
      check selection.usedAuto
      check selection.device.policyEligible
      check selection.device.deviceType in {dtCpu, dtGpu, dtNpu}
      # fullName 必须与 Backend 报告的一致(可以为空,但不能被改写)。
      for r in raw:
        if r.rawName == selection.device.rawName:
          check selection.device.fullName == r.fullName

  test "AUTO 的候选顺序在真机上确实是 NPU 优先":
    if not openVinoUsable:
      skip()
    else:
      let manager = newDeviceManager("openvino", realDevices())
      var hasNpu = false
      var hasIntelGpu = false
      for d in manager.devices():
        if d.deviceType == dtNpu and d.policyEligible:
          hasNpu = true
        if d.deviceType == dtGpu and d.policyEligible:
          hasIntelGpu = true

      let selection = manager.resolveDevice(DeviceRequestAuto)
      checkpoint("hasNpu=" & $hasNpu & " hasIntelGpu=" & $hasIntelGpu &
                 " selected=" & selection.device.rawName)
      if hasNpu:
        check selection.device.deviceType == dtNpu
      elif hasIntelGpu:
        check selection.device.deviceType == dtGpu
      else:
        check selection.device.deviceType == dtCpu

  test "显式请求 NPU 的结果与本机是否真有 NPU 一致":
    if not openVinoUsable:
      skip()
    else:
      let manager = newDeviceManager("openvino", realDevices())
      var hasNpu = false
      for d in manager.devices():
        if d.deviceType == dtNpu and d.policyEligible:
          hasNpu = true

      if hasNpu:
        let selection = manager.resolveDevice(DeviceRequestNpu)
        check selection.device.deviceType == dtNpu
        checkpoint("NPU 实际标识:" & selection.device.rawName &
                   " / " & selection.device.fullName)
      else:
        var code = ecServerError
        var raised = false
        try:
          discard manager.resolveDevice(DeviceRequestNpu)
        except IsvikError as e:
          raised = true
          code = e.code
        check raised
        check code == ecNpuNotAvailable

suite "Runtime 的语义设备接口(需要 openvino_c.dll)":

  test "semanticDevices 与 discoverDevices 描述同一批设备":
    if not openVinoUsable:
      skip()
    else:
      let rt = newRuntime(newOpenVinoBackend())
      rt.initialize()
      try:
        let raw = rt.discoverDevices()
        let semantic = rt.semanticDevices()
        check semantic.len == raw.len
        for i in 0 ..< raw.len:
          check semantic[i].rawName == raw[i].rawName
          check semantic[i].fullName == raw[i].fullName
          check semantic[i].backend == "openvino"
      finally:
        rt.shutdown()

  test "Runtime.resolveDevice 在真机上给出可用设备":
    if not openVinoUsable:
      skip()
    else:
      let rt = newRuntime(newOpenVinoBackend())
      rt.initialize()
      try:
        let selection = rt.resolveDevice(DeviceRequestAuto)
        checkpoint("Runtime AUTO -> " & selection.device.rawName &
                   " " & selection.reason)
        check selection.device.rawName.len > 0
        check selection.device.policyEligible

        # 显式 CPU 在任何机器上都应当可用。
        let cpu = rt.resolveDevice(DeviceRequestCpu)
        check cpu.device.deviceType == dtCpu
        check not cpu.usedAuto
        check cpu.requested == "CPU"
        check cpu.attempts.len == 1
        check cpu.attempts[0].status == dcsSelected
      finally:
        rt.shutdown()
