## 模型感知的 AUTO 设备策略。
##
## Core 的 DeviceManager 只知道设备是否存在；某个模型曾在某设备编译失败，
## 属于 manifest 知识。CLI 与 HTTP 必须共用这里，否则一条路径会跳过已知失败，
## 另一条路径却在每次启动时重新等待同一个失败。

import std/strutils

import isvik/core/device_manager
import isvik/services/device_service
import isvik/services/model_service

const
  BackendMarkerPrefix* = "[backend="
  CapacityFailureNotePrefix* =
    "Inference exceeded this device's allocation limit:"
  PrefillPipelineMarker* = "[prefill=chunked-v1]"

type
  ModelDevicePlan* = object
    ## AUTO 的模型感知计划。device 是语义设备名，不是 Backend raw name。
    device*: string
    backendName*: string
    backendVersion*: string
    excluded*: seq[string]

proc backendMarker*(backendName, backendVersion: string): string =
  BackendMarkerPrefix & backendName & "/" & backendVersion & "]"

proc semanticDeviceOf*(rawOrSemantic: string): string =
  ## `GPU.0` → `GPU`，`NPU` → `NPU`。
  let upper = rawOrSemantic.strip().toUpperAscii()
  let dot = upper.find('.')
  if dot > 0: upper[0 ..< dot] else: upper

proc deviceFromErrorDetail*(detail, fallback: string): string =
  ## 从 Backend 错误上下文中提取真正尝试过的设备。
  const Marker = "device="
  let at = detail.find(Marker)
  if at < 0:
    return semanticDeviceOf(fallback)
  var value = detail[(at + Marker.len) .. ^1]
  let space = value.find({' ', '\t', '\r', '\n'})
  if space >= 0:
    value = value[0 ..< space]
  if value.strip().len == 0:
    return semanticDeviceOf(fallback)
  semanticDeviceOf(value)

proc noteMatchesBackend(note, backendName, backendVersion: string): bool =
  note.contains(backendMarker(backendName, backendVersion))

proc noteCanExcludeDevice(note: string): bool =
  ## 编译失败是模型/设备能力结论，可以在相同 Backend 版本下排除。
  ## 容量失败取决于请求长度；manifest 目前没有可比较的 token/字节阈值，
  ## 因此只能保留为诊断记录，不能让一个长请求永久排除后续短请求。
  not note.startsWith(CapacityFailureNotePrefix)

proc verifiedSupportedDevice(models: ModelService, modelId, backendName,
                             backendVersion: string): string =
  if models == nil or modelId.len == 0:
    return ""
  try:
    let manifest = models.info(modelId).manifest
    for device in [DeviceRequestNpu, DeviceRequestGpu, DeviceRequestCpu]:
      let support = manifest.deviceSupportFor(device)
      if support.supported and support.verified and
          noteMatchesBackend(support.note, backendName, backendVersion):
        return device
  except CatchableError:
    discard
  ""

proc knownUnsupportedDevices(models: ModelService, modelId, backendName,
                             backendVersion: string): seq[string] =
  result = @[]
  if models == nil or modelId.len == 0:
    return
  for device in [DeviceRequestNpu, DeviceRequestGpu]:
    let eligibility =
      try:
        models.checkEligibility(modelId, device)
      except CatchableError:
        continue
    if eligibility.status == esUnsupported and
        noteMatchesBackend(eligibility.reason, backendName, backendVersion) and
        noteCanExcludeDevice(eligibility.reason):
      result.add(device)

proc planAutoDevice*(models: ModelService, modelId: string): ModelDevicePlan =
  ## 根据当前 Backend 版本跳过 manifest 中已验证失败的设备。
  ##
  ## Backend 版本变化后会重新验证；显式设备请求不调用此函数，因此不会被
  ## 历史结论拦截。
  result = ModelDevicePlan(device: DeviceRequestAuto, excluded: @[])
  var devices: DeviceService = nil
  try:
    devices = openDeviceService()
    result.backendName = devices.backendName
    result.backendVersion = devices.backendVersion
    if result.backendVersion.len == 0:
      return
    let verified = verifiedSupportedDevice(
      models, modelId, result.backendName, result.backendVersion)
    if verified.len > 0:
      result.device = verified
      return
    result.excluded = knownUnsupportedDevices(
      models, modelId, result.backendName, result.backendVersion)
    if result.excluded.len == 0:
      return
    let selection = devices.resolveDevice(DeviceRequestAuto, result.excluded)
    let chosen = semanticDeviceOf($selection.device.deviceType)
    if chosen.len > 0:
      result.device = chosen
  except CatchableError:
    # 规划层失败不能使模型完全无法加载；退回实时 AUTO 选择。
    result.device = DeviceRequestAuto
    result.excluded = @[]
  finally:
    if devices != nil:
      devices.close()

proc recordCompileFailure*(models: ModelService, modelId, device, reason,
                           backendName, backendVersion: string) =
  let semantic = semanticDeviceOf(device)
  if models == nil or modelId.len == 0 or
      semantic notin [DeviceRequestNpu, DeviceRequestGpu] or
      backendVersion.len == 0:
    return
  try:
    models.recordVerification(
      modelId, semantic, false,
      reason & " " & backendMarker(backendName, backendVersion))
  except CatchableError:
    discard

proc recordCapacityFailure*(models: ModelService, modelId, device, reason,
                            backendName, backendVersion: string) =
  let semantic = semanticDeviceOf(device)
  if models == nil or modelId.len == 0 or
      semantic notin [DeviceRequestNpu, DeviceRequestGpu] or
      backendVersion.len == 0:
    return
  try:
    models.recordVerification(
      modelId, semantic, false,
      CapacityFailureNotePrefix & " " & reason & " " &
        PrefillPipelineMarker & " " &
        backendMarker(backendName, backendVersion))
  except CatchableError:
    discard
