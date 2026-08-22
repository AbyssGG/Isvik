## Device Manager 与第一阶段 AUTO Policy
##
## 对应 Master Prompt §11、§12、§52。
##
## 本模块位于 Core,只接收 BackendDeviceInfo 快照,不依赖任何具体 Backend。
## Backend 负责报告真实的 rawName/fullName/properties;本模块负责把这些
## 原始信息解析成 Isvik 的统一设备模型,并执行可解释的设备选择策略。
##
## 重要边界:
##
## - `GPU` 不是单一硬件。`GPU.0`、`GPU.1` 必须逐项解析。
## - Intel GPU 资格只能由 Backend 提供的 vendor 元数据确认,不能根据
##   fullName 或设备序号猜测。无法确认 vendor 时,该 GPU 不进入 Intel 策略候选。
## - AUTO 第一阶段顺序是 NPU → Intel GPU → CPU。
## - 显式设备不可用时只报错,绝不静默回退到其它设备。
## - Device Manager 使用的是 Backend 的设备快照,不会绕过 Runtime 再次枚举。

import std/[strutils, tables]

import isvik/core/backend
import isvik/core/errors

type
  DeviceType* = enum
    ## 统一设备类型。`dtAuto` 只用于请求,实际设备不会是 AUTO。
    dtAuto = "AUTO"
    dtCpu = "CPU"
    dtGpu = "GPU"
    dtNpu = "NPU"
    dtUnknown = "UNKNOWN"

  DeviceId* = object
    ## 设备的稳定 Backend 标识及可解析的序号。
    ##
    ## `rawName` 必须原样传回 Backend,例如 `GPU.1`。
    ## `ordinal` 只对 `GPU.N` 有意义,其它设备为 -1。
    rawName*: string
    ordinal*: int

  DeviceCapability* = enum
    ## Backend 已经报告设备存在时,Device Manager 可以确认的基础能力。
    ##
    ## 这不是模型兼容性声明。模型是否能在设备上编译,仍由后续 Model
    ## Profile / Backend 编译结果确认,尤其不能从这里推断 LLM 一定可上 NPU。
    dcCompilation = "compilation"
    dcInference = "inference"

  DeviceCandidateStatus* = enum
    ## 一次策略尝试的状态。
    dcsSelected = "selected"
    dcsAvailable = "available"
    dcsMissing = "missing"
    dcsExcluded = "excluded"

  DeviceInfo* = object
    ## Isvik 的统一设备模型。
    ##
    ## `available` 表示 Backend 真实报告了该设备；`policyEligible` 表示
    ## 它是否符合当前第一阶段 Intel 目标策略。两者刻意分开,因此被策略
    ## 排除的 NVIDIA GPU 仍可显示为「已检测到」,而不是伪装成不存在。
    deviceType*: DeviceType
    deviceName*: string
      ## 稳定语义名称:CPU / GPU / NPU,不是硬件全名。
    deviceId*: DeviceId
    available*: bool
    capabilities*: set[DeviceCapability]
    backend*: string
    metadata*: Table[string, string]
    rawName*: string
      ## Backend 编译所需的原始设备名。
    fullName*: string
      ## Backend 报告的人类可读全名。为空时保持为空,不得用 rawName 冒充。
    architecture*: string
    vendor*: string
      ## 归一化名称:Intel / NVIDIA / Other / Unknown。
    vendorId*: string
      ## 例如 0x8086。无法确认时为空。
    policyEligible*: bool
    exclusionReason*: string
      ## 不进入当前策略时的结构化原因;可用且符合策略时为空。

  DeviceSelectionAttempt* = object
    ## 一次候选类型尝试,用于解释 AUTO 或显式选择结果。
    deviceType*: DeviceType
    status*: DeviceCandidateStatus
    candidateIds*: seq[string]
    excludedIds*: seq[string]
    reason*: string

  DeviceSelection* = object
    ## 设备选择结果。`device` 是实际使用的设备,不是请求中的语义名。
    requested*: string
    device*: DeviceInfo
    usedAuto*: bool
    reason*: string
    attempts*: seq[DeviceSelectionAttempt]

  DeviceManager* = ref object
    ## 设备管理器只保存一次发现得到的语义快照。
    backendName: string
    snapshot: seq[DeviceInfo]

const
  ## 配置/API 层允许的设备请求值。空字符串在请求模型中等价于 AUTO。
  DeviceRequestValues* = ["AUTO", "CPU", "GPU", "NPU"]
  DeviceRequestAuto* = "AUTO"
  DeviceRequestCpu* = "CPU"
  DeviceRequestGpu* = "GPU"
  DeviceRequestNpu* = "NPU"

  ## BackendDeviceInfo.properties 的跨 Backend 约定键。
  ##
  ## OpenVINO 使用同名属性;其它 Backend 可以提供同一契约,也可以只提供
  ## rawName/fullName。没有 architecture/vendor 证据的 GPU 不会被 Intel
  ## 策略选中。
  DevicePropertyArchitecture* = "DEVICE_ARCHITECTURE"
  DevicePropertyType* = "DEVICE_TYPE"
  DevicePropertyVendor* = "DEVICE_VENDOR"

  IntelVendorId* = "0x8086"
  NvidiaVendorId* = "0x10de"

proc `$`*(id: DeviceId): string = id.rawName

proc normalizedName(rawName: string): string =
  rawName.strip.toUpperAscii

proc classifyDeviceType*(rawName: string): DeviceType =
  ## 把 Backend rawName 解析为物理设备类型。
  ##
  ## `AUTO` 是请求策略而不是 Backend 设备,因此不会在这里被识别为物理
  ## 设备。未知 rawName 保留为 dtUnknown,不会被静默当成 CPU。
  let name = normalizedName(rawName)
  if name == "CPU":
    return dtCpu
  if name == "NPU":
    return dtNpu
  if name == "GPU" or name.startsWith("GPU."):
    return dtGpu
  dtUnknown

proc parseDeviceId*(rawName: string): DeviceId =
  ## 解析 rawName,只从 `GPU.N` 提取 ordinal,不改写 rawName。
  result = DeviceId(rawName: rawName, ordinal: -1)
  let name = normalizedName(rawName)
  if classifyDeviceType(rawName) != dtGpu or name.len <= 4:
    return

  let suffix = name[4 .. ^1]
  if suffix.len == 0:
    return
  for ch in suffix:
    if ch < '0' or ch > '9':
      return
  try:
    result.ordinal = parseInt(suffix)
  except ValueError:
    # 极大的序号不影响设备身份;保留 rawName,只放弃 ordinal。
    result.ordinal = -1

proc lookupProperty(properties: Table[string, string], wanted: string): string =
  ## 属性键按约定是大写,但对外部 Backend 做大小写不敏感读取。
  if properties.hasKey(wanted):
    return properties[wanted]
  let normalizedWanted = wanted.toUpperAscii
  for key, value in properties:
    if key.toUpperAscii == normalizedWanted:
      return value
  ""

proc isHexDigit(ch: char): bool =
  ch in {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}

proc parseHexVendorId(text: string): string =
  ## 把 `0x8086` / `8086` 解析为规范形式 `0x8086`。解析不出返回空。
  ##
  ## 不用 contains("8086"):那会把 `0x18086` 之类的其它值误判为 Intel。
  var start = 0
  if text.startsWith("0x"):
    start = 2
  if start >= text.len:
    return ""
  var finish = start
  while finish < text.len and isHexDigit(text[finish]):
    inc finish
  # 必须整段都是十六进制数字。`3720abc` 这种不是一个 vendor id。
  if finish == start or finish != text.len:
    return ""
  result = "0x" & text[start ..< finish]

proc extractVendorId(value: string, isExplicitVendorField: bool): string =
  ## 从 Backend 属性中提取规范 vendor id。取不到时返回空字符串。
  ##
  ## ---
  ##
  ## ## 为什么区分「显式 vendor 字段」与「顺带含 vendor 的字符串」
  ##
  ## OpenVINO 的 `DEVICE_ARCHITECTURE` 在不同设备上语义完全不同(本机实测):
  ##
  ## ```text
  ## CPU     intel64                            ISA 名称
  ## GPU.0   GPU: vendor=0x8086 arch=v12.70.4   含显式 vendor 字段
  ## GPU.1   GPU: vendor=0x10de arch=v12.0.0    含显式 vendor 字段
  ## NPU     3720                               NPU 代次,不是 vendor
  ## ```
  ##
  ## 最初的实现把整段字符串当候选 vendor id 解析,于是 NPU 的 `3720`
  ## 被当成十六进制读成 `0x3720`,厂商列显示成 `Other` —— 那是**凭空编造的
  ## 硬件信息**(§27 明令禁止)。`3720` 是架构代次,与 PCI vendor 无关。
  ##
  ## 因此裸十六进制**只在显式 vendor 字段里**才被接受:
  ##
  ## ```text
  ## 有 vendor= 标记        → 解析标记之后的内容
  ## DEVICE_VENDOR 属性     → 解析整个取值
  ## 其它字符串             → 只认 intel / nvidia 这类厂商名前缀,
  ##                          裸数字一律视为「没有 vendor 信息」
  ## ```
  ##
  ## 这样 CPU 的 `intel64` 仍能识别为 Intel(字符串本身就写着 intel),
  ## 而 NPU 的 `3720` 如实报告为 Unknown。
  let text = value.strip.toLowerAscii
  if text.len == 0:
    return ""

  let marker = "vendor="
  let markerPos = text.find(marker)
  if markerPos >= 0:
    let start = markerPos + marker.len
    if start >= text.len:
      return ""
    # 标记之后到下一个空白为止即为 vendor 取值。
    var tail = text[start .. ^1].strip
    let spacePos = tail.find(' ')
    if spacePos >= 0:
      tail = tail[0 ..< spacePos]
    if tail.startsWith("intel"): return "intel"
    if tail.startsWith("nvidia"): return "nvidia"
    return parseHexVendorId(tail)

  # 没有 vendor= 标记:厂商名前缀在任何来源下都可信。
  if text.startsWith("intel"):
    return "intel"
  if text.startsWith("nvidia"):
    return "nvidia"

  # 裸十六进制只在显式 vendor 字段里可信(见上文 NPU `3720` 的说明)。
  if isExplicitVendorField:
    return parseHexVendorId(text)
  result = ""

proc isIntelVendor(vendorId: string): bool =
  vendorId == IntelVendorId or vendorId == "intel"

proc vendorLabel(vendorId: string): string =
  if isIntelVendor(vendorId):
    return "Intel"
  if vendorId == NvidiaVendorId or vendorId == "nvidia":
    return "NVIDIA"
  if vendorId.len > 0:
    return "Other"
  "Unknown"

proc policyEligibility(deviceType: DeviceType, vendorId: string): tuple[
    eligible: bool, reason: string] =
  case deviceType
  of dtCpu, dtNpu:
    (true, "")
  of dtGpu:
    if isIntelVendor(vendorId):
      (true, "")
    elif vendorId.len == 0:
      (false, "gpu-vendor-unknown")
    else:
      (false, "non-intel-gpu:vendor=" & vendorId)
  of dtAuto:
    (false, "auto-is-a-request-not-a-device")
  of dtUnknown:
    (false, "unsupported-device-type")

proc toDeviceInfo(raw: BackendDeviceInfo, backendName: string): DeviceInfo =
  ## 把一条 Backend 设备报告转换为统一设备模型。
  let kind = classifyDeviceType(raw.rawName)
  let architecture = lookupProperty(raw.properties, DevicePropertyArchitecture)
  let explicitVendor = lookupProperty(raw.properties, DevicePropertyVendor)
  let vendorId =
    if explicitVendor.len > 0:
      extractVendorId(explicitVendor, isExplicitVendorField = true)
    else:
      extractVendorId(architecture, isExplicitVendorField = false)
  let eligibility = policyEligibility(kind, vendorId)
  let hasRawName = raw.rawName.strip.len > 0
  let eligible = hasRawName and eligibility.eligible

  result = DeviceInfo(
    deviceType: kind,
    deviceName: $kind,
    deviceId: parseDeviceId(raw.rawName),
    available: hasRawName,
    capabilities: {},
    backend: backendName,
    metadata: initTable[string, string](),
    rawName: raw.rawName,
    fullName: raw.fullName,
    architecture: architecture,
    vendor: vendorLabel(vendorId),
    vendorId: vendorId,
    policyEligible: eligible,
    exclusionReason: if hasRawName: eligibility.reason
                     else: "backend-returned-empty-device-name"
  )

  # OpenVINO 目前报告这些物理设备时,Backend 已证明设备可被发现。
  # 这里只表达基础的「可以交给 Backend 尝试编译/推理」能力,不宣称
  # 某个具体模型一定兼容。
  if hasRawName and kind != dtUnknown:
    result.capabilities = {dcCompilation, dcInference}

  for key, value in raw.properties:
    result.metadata[key] = value
  result.metadata["isvik.vendor"] = result.vendor
  result.metadata["isvik.vendor_id"] = result.vendorId
  result.metadata["isvik.policy_eligible"] =
    if result.policyEligible: "true" else: "false"
  if result.exclusionReason.len > 0:
    result.metadata["isvik.exclusion_reason"] = result.exclusionReason

proc newDeviceManager*(backendName: string,
                       rawDevices: openArray[BackendDeviceInfo]): DeviceManager =
  ## 从一次 Backend 发现结果创建 Device Manager。
  new(result)
  result.backendName = backendName
  result.snapshot = @[]
  for raw in rawDevices:
    result.snapshot.add(toDeviceInfo(raw, backendName))

proc updateDevices*(manager: DeviceManager,
                    rawDevices: openArray[BackendDeviceInfo]) =
  ## 用 Runtime 新的发现快照替换旧快照。
  if manager == nil:
    raiseIsvikError(ecInvalidParameter, "Device manager is nil")
  manager.snapshot = @[]
  for raw in rawDevices:
    manager.snapshot.add(toDeviceInfo(raw, manager.backendName))

proc backendName*(manager: DeviceManager): string =
  if manager == nil: "" else: manager.backendName

proc devices*(manager: DeviceManager): seq[DeviceInfo] =
  ## 返回当前语义设备快照;不会触发 Backend 枚举。
  if manager == nil:
    return @[]
  manager.snapshot

proc deviceNames(manager: DeviceManager): seq[string] =
  if manager == nil:
    return @[]
  for device in manager.snapshot:
    if device.rawName.len > 0:
      result.add(device.rawName)

proc makeAttempt(manager: DeviceManager, deviceType: DeviceType):
    DeviceSelectionAttempt =
  result = DeviceSelectionAttempt(
    deviceType: deviceType,
    status: dcsMissing,
    candidateIds: @[],
    excludedIds: @[],
    reason: "no-device-reported"
  )
  if manager == nil:
    result.reason = "device-manager-is-nil"
    return

  for device in manager.snapshot:
    if device.deviceType != deviceType:
      continue
    if not device.available:
      result.excludedIds.add(device.rawName)
      continue
    if device.policyEligible:
      result.candidateIds.add(device.rawName)
    else:
      result.excludedIds.add(device.rawName & "(" & device.exclusionReason & ")")

  if result.candidateIds.len > 0:
    result.status = dcsAvailable
    result.reason = "eligible-device-reported"
  elif result.excludedIds.len > 0:
    result.status = dcsExcluded
    result.reason = "all-devices-excluded-by-policy"

proc firstEligibleIndex(manager: DeviceManager, deviceType: DeviceType): int =
  if manager == nil:
    return -1
  for index, device in manager.snapshot:
    if device.deviceType == deviceType and device.available and
       device.policyEligible:
      return index
  -1

proc attemptSummary(attempt: DeviceSelectionAttempt): string =
  result = $attempt.deviceType & ":" & $attempt.status
  if attempt.candidateIds.len > 0:
    result.add(" candidates=" & attempt.candidateIds.join(","))
  if attempt.excludedIds.len > 0:
    result.add(" excluded=" & attempt.excludedIds.join(","))
  result.add(" reason=" & attempt.reason)

proc invalidRequest(requested: string) {.noreturn.} =
  raiseIsvikError(
    ecInvalidParameter,
    "Unknown device request",
    "requested=" & requested & " supported=" & DeviceRequestValues.join(",")
  )

proc noCandidate(manager: DeviceManager, requested: string,
                 attempts: seq[DeviceSelectionAttempt]) {.noreturn.} =
  var code = ecDeviceNotAvailable
  var reason = "no-eligible-device"
  if requested == DeviceRequestNpu:
    code = ecNpuNotAvailable
    reason = "npu-not-available"
  elif requested == DeviceRequestGpu:
    code = ecGpuNotAvailable
    reason = "no-eligible-intel-gpu"

  var detail = "requested=" & requested &
    " available=" & manager.deviceNames.join(",")
  if manager == nil or manager.deviceNames.len == 0:
    detail.add("<none>")
  detail.add(" policy=AUTO>NPU>IntelGPU>CPU")
  detail.add(" attempts=")
  var summaries: seq[string] = @[]
  for attempt in attempts:
    summaries.add(attemptSummary(attempt))
  detail.add(summaries.join(";"))
  detail.add(" reason=" & reason)
  raiseIsvikError(code, defaultMessage(code), detail)

proc parseDeviceRequest*(requested: string): DeviceType =
  ## 解析配置/API 的设备请求。空字符串按统一请求模型解释为 AUTO。
  if requested.len == 0 or requested == DeviceRequestAuto:
    return dtAuto
  case requested
  of DeviceRequestCpu: dtCpu
  of DeviceRequestGpu: dtGpu
  of DeviceRequestNpu: dtNpu
  else: invalidRequest(requested)

proc resolveDevice*(manager: DeviceManager,
                    requested: string = DeviceRequestAuto,
                    excluded: seq[string] = @[]): DeviceSelection =
  ## 解析显式设备或执行第一阶段 AUTO Policy。
  ##
  ## 显式请求只选择该类型,失败时抛对应错误码；AUTO 才允许按优先级继续
  ## 尝试下一个类型。每次尝试都保留在返回结果中,便于日志/GUI 解释决策。
  ##
  ## `excluded` 是**调用方**给出的语义设备名(CPU / GPU / NPU),AUTO 会跳过
  ## 它们。Core 刻意不关心排除的理由 —— 「该模型在某设备上编译失败过」这类
  ## 知识属于 Model Manifest,而 Core 不得依赖上层。把集合作为数据传入,
  ## 使 AUTO 的**候选顺序仍然只有这一份实现**,不必在服务层再写一遍。
  ##
  ## 排除只作用于 AUTO。显式请求某设备时一律照请求去试:用户明确指定了,
  ## 就应该看到该设备真实的成败,而不是被一条历史记录挡住。
  let request = if requested.len == 0: DeviceRequestAuto else: requested
  let requestedType = parseDeviceRequest(request)
  let auto = requestedType == dtAuto
  let order =
    if auto: @[dtNpu, dtGpu, dtCpu]
    else: @[requestedType]

  var skipped: set[DeviceType] = {}
  if auto:
    for name in excluded:
      let trimmed = name.strip().toUpperAscii()
      if trimmed.len == 0:
        continue
      # 非法名字直接报错:静默忽略会让「我明明排除了它」与实际行为不符。
      skipped.incl(parseDeviceRequest(trimmed))

  result = DeviceSelection(
    requested: request,
    device: DeviceInfo(),
    usedAuto: auto,
    reason: "",
    attempts: @[]
  )

  for candidateType in order:
    if candidateType in skipped:
      # 如实记录「跳过了它以及为什么」,而不是让这个设备从决策过程里消失 ——
      # 否则用户看到的结果会像是 Isvik 从未考虑过 NPU。
      var skippedAttempt = makeAttempt(manager, candidateType)
      skippedAttempt.status = dcsExcluded
      skippedAttempt.reason = "excluded-by-caller"
      result.attempts.add(skippedAttempt)
      continue
    var attempt = makeAttempt(manager, candidateType)
    let selectedIndex = firstEligibleIndex(manager, candidateType)
    if selectedIndex >= 0:
      attempt.status = dcsSelected
      result.attempts.add(attempt)
      result.device = manager.snapshot[selectedIndex]
      if auto:
        result.reason = "AUTO selected " & $candidateType &
          " rawName=" & result.device.rawName
      else:
        result.reason = "Explicit request selected rawName=" &
          result.device.rawName
      return
    result.attempts.add(attempt)

  noCandidate(manager, request, result.attempts)

proc selectDevice*(manager: DeviceManager,
                   requested: string = DeviceRequestAuto,
                   excluded: seq[string] = @[]): DeviceSelection =
  ## `resolveDevice` 的策略命名别名,便于上层按「选择」语义调用。
  resolveDevice(manager, requested, excluded)
