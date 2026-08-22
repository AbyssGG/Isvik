import std/[unittest, strutils, tables]

import isvik/core/backend
import isvik/core/device_manager
import isvik/core/errors

proc simulatedDevice(rawName: string, fullName: string = "",
                     architecture: string = "",
                     vendor: string = ""): BackendDeviceInfo =
  result = BackendDeviceInfo(
    rawName: rawName,
    fullName: fullName,
    properties: initTable[string, string]()
  )
  if architecture.len > 0:
    result.properties[DevicePropertyArchitecture] = architecture
  if vendor.len > 0:
    result.properties[DevicePropertyVendor] = vendor

proc expectError(body: proc (), expected: IsvikErrorCode): string =
  var caught = false
  var detail = ""
  try:
    body()
  except IsvikError as e:
    caught = true
    check e.code == expected
    detail = e.detail
  check caught
  detail

suite "Device Manager:设备身份与元数据":

  test "解析 CPU、GPU.N、NPU 和未知 rawName":
    check classifyDeviceType("CPU") == dtCpu
    check classifyDeviceType("GPU.0") == dtGpu
    check classifyDeviceType("GPU.1") == dtGpu
    check classifyDeviceType("NPU") == dtNpu
    check classifyDeviceType("AUTO") == dtUnknown
    check classifyDeviceType("MY_ACCELERATOR") == dtUnknown

    let gpuId = parseDeviceId("GPU.7")
    check gpuId.rawName == "GPU.7"
    check gpuId.ordinal == 7
    check $gpuId == "GPU.7"
    check parseDeviceId("CPU").ordinal == -1
    check parseDeviceId("GPU.x").ordinal == -1

  test "从 DEVICE_ARCHITECTURE 区分 Intel GPU 与 NVIDIA GPU":
    let manager = newDeviceManager("mock", @[
      simulatedDevice("GPU.0", "Intel(R) Graphics (iGPU)",
        "GPU: vendor=0x8086 arch=v12.70.4"),
      simulatedDevice("GPU.1", "NVIDIA GeForce RTX 5080 (dGPU)",
        "GPU: vendor=0x10de arch=v12.0.0")
    ])
    let devices = manager.devices()

    check devices.len == 2
    check devices[0].deviceType == dtGpu
    check devices[0].deviceId.ordinal == 0
    check devices[0].vendor == "Intel"
    check devices[0].vendorId == "0x8086"
    check devices[0].policyEligible
    check devices[0].exclusionReason == ""
    check devices[0].metadata[DevicePropertyArchitecture].contains("0x8086")

    check devices[1].vendor == "NVIDIA"
    check devices[1].vendorId == "0x10de"
    check devices[1].available
    check not devices[1].policyEligible
    check devices[1].exclusionReason == "non-intel-gpu:vendor=0x10de"
    check devices[1].metadata["isvik.exclusion_reason"].contains("non-intel")

  test "fullName 缺失时保持为空,不伪造硬件名称":
    let manager = newDeviceManager("mock", @[
      simulatedDevice("CPU")
    ])
    let device = manager.devices()[0]
    check device.rawName == "CPU"
    check device.fullName == ""
    check device.deviceName == "CPU"

suite "Device Manager:显式选择":

  test "显式 NPU、GPU、CPU 都只选择请求的类型":
    let manager = newDeviceManager("mock", @[
      simulatedDevice("CPU", "Mock CPU"),
      simulatedDevice("GPU.1", "NVIDIA", "GPU: vendor=0x10de arch=v12"),
      simulatedDevice("GPU.0", "Intel GPU", "GPU: vendor=0x8086 arch=v12"),
      simulatedDevice("NPU", "Intel AI Boost")
    ])

    let npu = manager.selectDevice("NPU")
    check npu.device.rawName == "NPU"
    check npu.device.fullName == "Intel AI Boost"
    check not npu.usedAuto
    check npu.attempts.len == 1

    let gpu = manager.selectDevice("GPU")
    check gpu.device.rawName == "GPU.0"
    check gpu.device.fullName == "Intel GPU"
    check gpu.attempts[0].status == dcsSelected

    let cpu = manager.selectDevice("CPU")
    check cpu.device.rawName == "CPU"
    check cpu.device.deviceType == dtCpu

  test "显式 NPU 缺失返回 NPU_NOT_AVAILABLE,不回退 CPU":
    let manager = newDeviceManager("mock", @[
      simulatedDevice("CPU", "Mock CPU")
    ])
    let detail = expectError(proc () = discard manager.selectDevice("NPU"),
                             ecNpuNotAvailable)
    check detail.contains("requested=NPU")
    check detail.contains("available=CPU")
    check detail.contains("npu-not-available")

  test "显式 GPU 只有 NVIDIA 时返回 GPU_NOT_AVAILABLE 并报告排除原因":
    let manager = newDeviceManager("mock", @[
      simulatedDevice("GPU.1", "NVIDIA", "GPU: vendor=0x10de arch=v12"),
      simulatedDevice("CPU", "Mock CPU")
    ])
    let detail = expectError(proc () = discard manager.selectDevice("GPU"),
                             ecGpuNotAvailable)
    check detail.contains("requested=GPU")
    check detail.contains("GPU.1")
    check detail.contains("non-intel-gpu")
    check detail.contains("no-eligible-intel-gpu")

  test "空请求和非法请求分别按 AUTO 与 INVALID_PARAMETER 处理":
    let manager = newDeviceManager("mock", @[
      simulatedDevice("CPU", "Mock CPU")
    ])
    let auto = manager.selectDevice("")
    check auto.usedAuto
    check auto.requested == "AUTO"
    check auto.device.rawName == "CPU"

    let detail = expectError(proc () = discard manager.selectDevice("TPU"),
                             ecInvalidParameter)
    check detail.contains("requested=TPU")
    check detail.contains("supported=AUTO,CPU,GPU,NPU")

suite "Device Manager:AUTO Policy":

  test "AUTO 优先 NPU,结果包含实际 rawName 和 fullName":
    let manager = newDeviceManager("mock", @[
      simulatedDevice("CPU", "Mock CPU"),
      simulatedDevice("GPU.0", "Intel GPU", "GPU: vendor=0x8086 arch=v12"),
      simulatedDevice("NPU", "Intel AI Boost")
    ])
    let selected = manager.selectDevice("AUTO")
    check selected.usedAuto
    check selected.device.rawName == "NPU"
    check selected.device.fullName == "Intel AI Boost"
    check selected.device.deviceType == dtNpu
    check selected.attempts.len == 1
    check selected.attempts[0].deviceType == dtNpu
    check selected.attempts[0].status == dcsSelected

  test "AUTO 跳过 NVIDIA GPU,选择 Intel GPU 即使它不是 GPU.0":
    let manager = newDeviceManager("mock", @[
      simulatedDevice("GPU.0", "NVIDIA", "GPU: vendor=0x10de arch=v12"),
      simulatedDevice("GPU.1", "Intel Graphics", "GPU: vendor=0x8086 arch=v12"),
      simulatedDevice("CPU", "Mock CPU")
    ])
    let selected = manager.selectDevice("AUTO")
    check selected.device.rawName == "GPU.1"
    check selected.device.fullName == "Intel Graphics"
    check selected.attempts.len == 2
    check selected.attempts[0].status == dcsMissing
    check selected.attempts[1].status == dcsSelected
    check selected.attempts[1].excludedIds.len == 1
    check selected.attempts[1].excludedIds[0].contains("GPU.0")

  test "AUTO 在没有 NPU/Intel GPU 时回退 CPU":
    let manager = newDeviceManager("mock", @[
      simulatedDevice("GPU.0", "NVIDIA", "GPU: vendor=0x10de arch=v12"),
      simulatedDevice("CPU", "Mock CPU")
    ])
    let selected = manager.selectDevice("AUTO")
    check selected.device.rawName == "CPU"
    check selected.attempts.len == 3
    check selected.attempts[0].status == dcsMissing
    check selected.attempts[1].status == dcsExcluded
    check selected.attempts[2].status == dcsSelected

  test "AUTO 无候选设备时报告缺失与策略排除,不伪造 CPU":
    let manager = newDeviceManager("mock", @[
      simulatedDevice("GPU.0", "NVIDIA", "GPU: vendor=0x10de arch=v12")
    ])
    let detail = expectError(proc () = discard manager.selectDevice("AUTO"),
                             ecDeviceNotAvailable)
    check detail.contains("requested=AUTO")
    check detail.contains("available=GPU.0")
    check detail.contains("NPU:missing")
    check detail.contains("GPU:excluded")
    check detail.contains("non-intel-gpu")
    check detail.contains("CPU:missing")

  test "更新快照不会触发 Backend,并重新应用策略":
    let manager = newDeviceManager("mock", @[
      simulatedDevice("CPU", "Mock CPU")
    ])
    check manager.selectDevice("AUTO").device.rawName == "CPU"

    manager.updateDevices(@[
      simulatedDevice("NPU", "Hot-plugged NPU")
    ])
    let selected = manager.selectDevice("AUTO")
    check selected.device.rawName == "NPU"
    check selected.device.fullName == "Hot-plugged NPU"
    check manager.backendName == "mock"

# ---------------------------------------------------------------------------
# vendor 解析的来源区分
# ---------------------------------------------------------------------------
#
# 这一组用例来自一个真实缺陷:`isvik devices` 把本机 NPU 的厂商显示成
# `Other`。根因是 NPU 的 `DEVICE_ARCHITECTURE` 是 `3720`(NPU 代次),
# 而当初的解析器把任意裸数字都当十六进制 vendor id 读,于是读出 `0x3720`。
#
# 那是**凭空编造的硬件信息**(§27)。修法是:裸十六进制只在显式 vendor
# 字段里才可信;架构字符串里只认 intel / nvidia 这类厂商名前缀。

suite "vendor 解析必须区分来源":

  test "NPU 的架构代次不得被当成 vendor id":
    # 本机实测:NPU 的 DEVICE_ARCHITECTURE 是 "3720"。
    let manager = newDeviceManager("mock", @[
      simulatedDevice("NPU", "Intel(R) AI Boost", "3720")
    ])
    let npu = manager.devices()[0]
    check npu.deviceType == dtNpu
    check npu.architecture == "3720"
    # 关键断言:不能读出 0x3720,也不能显示成 Other。
    check npu.vendorId == ""
    check npu.vendor == "Unknown"
    # NPU 的策略资格不依赖 vendor,仍应是候选。
    check npu.policyEligible

  test "CPU 的 intel64 仍能识别为 Intel":
    # 这个字符串本身就写着 intel,识别它不是猜测。
    let manager = newDeviceManager("mock", @[
      simulatedDevice("CPU", "Intel(R) Core(TM) Ultra 7 270K Plus", "intel64")
    ])
    let cpu = manager.devices()[0]
    check cpu.vendorId == "intel"
    check cpu.vendor == "Intel"
    check cpu.policyEligible

  test "显式 DEVICE_VENDOR 字段里的裸十六进制可信":
    let manager = newDeviceManager("mock", @[
      simulatedDevice("GPU.0", "Some Intel GPU", "", "0x8086")
    ])
    let gpu = manager.devices()[0]
    check gpu.vendorId == "0x8086"
    check gpu.vendor == "Intel"
    check gpu.policyEligible

  test "架构字符串里的裸数字不被当成 vendor,GPU 因此按未知处理":
    # 没有 vendor 证据的 GPU 不进入 Intel 候选(不猜)。
    let manager = newDeviceManager("mock", @[
      simulatedDevice("GPU.0", "Mystery GPU", "12345")
    ])
    let gpu = manager.devices()[0]
    check gpu.vendorId == ""
    check gpu.vendor == "Unknown"
    check not gpu.policyEligible
    check gpu.exclusionReason == "gpu-vendor-unknown"

  test "vendor= 标记后的取值不会把后续字段吞进来":
    # "GPU: vendor=0x8086 arch=v12.70.4" 里的 arch 部分不能进 vendorId。
    let manager = newDeviceManager("mock", @[
      simulatedDevice("GPU.0", "Intel GPU",
        "GPU: vendor=0x8086 arch=v12.70.4")
    ])
    check manager.devices()[0].vendorId == "0x8086"

  test "vendor= 标记后是厂商名而非数字时同样识别":
    let manager = newDeviceManager("mock", @[
      simulatedDevice("GPU.1", "Some card", "GPU: vendor=NVIDIA arch=x")
    ])
    let gpu = manager.devices()[0]
    check gpu.vendor == "NVIDIA"
    check not gpu.policyEligible

  test "混入非十六进制字符的取值不被当成 vendor id":
    let manager = newDeviceManager("mock", @[
      simulatedDevice("GPU.0", "Odd GPU", "", "0x8086zz")
    ])
    check manager.devices()[0].vendorId == ""
