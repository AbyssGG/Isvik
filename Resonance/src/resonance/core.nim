import std/os

import c_api
import compiled_model
import errors
import infer_request
import model
import tensor

export c_api.OvElementType
export c_api.OvElementTypeDynamic
export c_api.OvElementTypeUndefined
export c_api.OvStatus
export c_api.OpenVinoUnavailableError

# Runtime availability. Exposed so that applications can report
# "OpenVINO is not available" instead of crashing at startup.
export c_api.tryLoadOpenVino
export c_api.isOpenVinoLoaded
export c_api.openVinoLoadError
export c_api.openVinoMissingSymbols
export c_api.openVinoLibraryPath
export c_api.unloadOpenVino
export c_api.dllName
export c_api.OvProfilingStatus
export c_api.OvProfilingInfo
export c_api.nv_compile_model_with_perf_count
export c_api.nv_enable_perf_count

# Property keys, so that callers do not have to spell the strings themselves.
export c_api.OvPropertyKeyEnableProfiling
export c_api.OvPropertyKeyFullDeviceName
export c_api.OvPropertyKeySupportedProperties
export c_api.OvPropertyKeyAvailableDevices
export c_api.OvPropertyKeyDeviceArchitecture
export c_api.OvPropertyKeyDeviceType
export c_api.OvPropertyKeyOptimalNumberOfInferRequests
export c_api.OvPropertyKeyRangeForAsyncInferRequests
export c_api.OvPropertyKeyRangeForStreams
export c_api.OvPropertyKeyCacheDir
export c_api.OvPropertyKeyPerformanceHint
export c_api.OvPropertyKeyNumStreams
export c_api.OvPropertyKeyInferencePrecisionHint
export compiled_model.CompiledModel
export errors.OpenVinoError
export infer_request.InferRequest
export infer_request.ProfilingInfo
export model.Model
export tensor.Tensor

type
  CoreObj* = object
    pCore*: ptr OvCore
  Core* = ref CoreObj

proc `=destroy`*(core: var CoreObj) =
  if core.pCore != nil:
    ov_core_free(core.pCore)
    core.pCore = nil

proc isClosed*(core: Core): bool =
  ## Whether the native handle has already been released.
  core == nil or core.pCore == nil

proc close*(core: Core) =
  ## Releases the native handle immediately instead of waiting for `=destroy`.
  ##
  ## Idempotent. Note that closing the Core does not invalidate models or
  ## compiled models already obtained from it -- those own their own handles and
  ## must be closed separately.
  if core != nil and core.pCore != nil:
    ov_core_free(core.pCore)
    core.pCore = nil

proc requireOpen*(core: Core, action: string) =
  ## Guards against use-after-close.
  ##
  ## Without this the nil pointer reaches the C API, where the failure mode
  ## varies by entry point: some return `INVALID_C_PARAM`, others dereference
  ## it. Failing here yields a catchable error that names the action instead of
  ## an inconsistent crash.
  if core.isClosed:
    raiseOpenVinoError(action, INVALID_C_PARAM, "core handle is closed")

proc newCore*(): Core =
  var pCore: ptr OvCore
  requireStatus(ov_core_create(addr pCore), "Create OpenVINO core")
  new(result)
  result.pCore = pCore

proc addExtension*(core: Core, libraryPath: string) =
  ## Registers a custom-operation library with this core.
  ##
  ## Required before reading a tokenizer IR: those graphs use operations from
  ## the `extension` opset (`SpecialTokensSplit`, `VocabDecoder`, ...) which the
  ## base runtime does not know. Without registration `readModel` fails with
  ## "unsupported opset: extension".
  ##
  ## Registration is **per core** -- the same core instance must later read the
  ## model. Registering on one core and reading on another does not work, and
  ## the resulting error does not hint at the real cause.
  core.requireOpen("Add extension")
  requireStatus(
    ov_core_add_extension(core.pCore, libraryPath.cstring),
    "Add extension",
    libraryPath
  )

proc getAvailableDevices*(core: Core): seq[string] =
  core.requireOpen("Get available devices")
  var devices: OvAvailableDevices
  requireStatus(ov_core_get_available_devices(core.pCore, addr devices), "Get available devices")
  try:
    result = newSeq[string](int(devices.size))
    for i in 0 ..< int(devices.size):
      result[i] = $devices.devices[i]
  finally:
    ov_available_devices_free(addr devices)

# ---------------------------------------------------------------------------
# Runtime version
# ---------------------------------------------------------------------------

type
  OpenVinoVersion* = object
    ## OpenVINO Runtime version information.
    buildNumber*: string
      ## e.g. "2026.3.0-22451-8a17657b995-releases/2026/3"
    description*: string
      ## e.g. "OpenVINO Runtime"

proc getOpenVinoVersion*(): OpenVinoVersion =
  ## Reads the OpenVINO Runtime version.
  ##
  ## This is a free function, not a `Core` method: the C API does not require a
  ## Core instance, and callers often need the version precisely when Core
  ## creation is failing.
  ##
  ## Knowing the exact runtime version is not cosmetic here — the numeric values
  ## of `ov_element_type_e` differ between releases (see c_api.nim), so
  ## downstream code may need to verify what it is talking to.
  var raw: OvVersion
  requireStatus(ov_get_openvino_version(addr raw), "Get OpenVINO version")
  try:
    result.buildNumber = if raw.buildNumber != nil: $raw.buildNumber else: ""
    result.description = if raw.description != nil: $raw.description else: ""
  finally:
    ov_version_free(addr raw)

proc `$`*(v: OpenVinoVersion): string =
  if v.description.len > 0 and v.buildNumber.len > 0:
    v.description & " " & v.buildNumber
  elif v.buildNumber.len > 0:
    v.buildNumber
  else:
    v.description

# ---------------------------------------------------------------------------
# Properties
# ---------------------------------------------------------------------------

proc getProperty*(core: Core, deviceName, key: string): string =
  core.requireOpen("Get device property")
  ## Reads a device property as a string.
  ##
  ## The value returned by OpenVINO is owned by OpenVINO and released with
  ## `ov_free`; it is copied into a Nim string first.
  var raw: cstring = nil
  requireStatus(
    ov_core_get_property(core.pCore, deviceName.cstring, key.cstring, addr raw),
    "Get device property",
    "device=" & deviceName & " key=" & key
  )
  try:
    result = if raw != nil: $raw else: ""
  finally:
    if raw != nil:
      ov_free(raw)

proc tryGetProperty*(core: Core, deviceName, key: string,
                     fallback: string = ""): string =
  ## Like `getProperty` but returns `fallback` when the property is unsupported.
  ##
  ## Not every device exposes every property, and querying an unsupported one is
  ## a normal outcome rather than a failure. Callers that are probing
  ## capabilities should not have to wrap each query in a try block.
  ##
  ## Note the deliberate asymmetry: this swallows the error, so it must only be
  ## used where "unknown" is an acceptable answer. Reporting hardware
  ## information is such a case — an empty value is honest, a fabricated one is
  ## not.
  try:
    result = core.getProperty(deviceName, key)
  except OpenVinoError:
    result = fallback

proc setProperty*(core: Core, deviceName, key, value: string) =
  core.requireOpen("Set device property")
  ## Sets a single device property (e.g. `CACHE_DIR`).
  requireStatus(
    nv_core_set_property(core.pCore, deviceName.cstring, key.cstring, value.cstring),
    "Set device property",
    "device=" & deviceName & " key=" & key & " value=" & value
  )

proc getFullDeviceName*(core: Core, deviceName: string): string =
  ## Convenience accessor for `FULL_DEVICE_NAME`.
  ##
  ## Returns an empty string when the device does not report it. Callers must
  ## **not** substitute the short device name — displaying "NPU" as if it were
  ## the full hardware name would be fabricated information.
  core.tryGetProperty(deviceName, OvPropertyKeyFullDeviceName)

proc maxPropertyPairs*(): int =
  ## Maximum number of property pairs `compileModelWithProperties` can forward.
  int(nv_max_property_pairs())

proc readModel*(core: Core, modelPath: string, binPath: string = ""): Model =
  core.requireOpen("Read model")
  var pModel: ptr OvModel
  let actualBinPath = if binPath.len > 0: binPath.cstring else: nil
  requireStatus(
    ov_core_read_model(core.pCore, modelPath.cstring, actualBinPath, addr pModel),
    "Read model",
    modelPath
  )
  new(result)
  result.pModel = pModel

proc compileModel*(core: Core, model: Model, deviceName: string): CompiledModel =
  core.requireOpen("Compile model")
  model.requireOpen("Compile model")
  var pCompiledModel: ptr OvCompiledModel
  requireStatus(
    ov_core_compile_model(core.pCore, model.pModel, deviceName.cstring, 0, addr pCompiledModel),
    "Compile model",
    deviceName
  )
  new(result)
  result.pCompiledModel = pCompiledModel

proc compileModelWithProfiling*(
  core: Core,
  model: Model,
  deviceName: string
): CompiledModel =
  core.requireOpen("Compile model with profiling")
  model.requireOpen("Compile model with profiling")
  var pCompiledModel: ptr OvCompiledModel
  requireStatus(
    nv_compile_model_with_perf_count(
      core.pCore,
      model.pModel,
      deviceName.cstring,
      addr pCompiledModel
    ),
    "Compile model with profiling",
    deviceName
  )
  new(result)
  result.pCompiledModel = pCompiledModel

proc compileModelWithProperties*(
  core: Core,
  model: Model,
  deviceName: string,
  properties: openArray[(string, string)]
): CompiledModel =
  ## Compiles a model with an arbitrary set of property pairs.
  ##
  ## Goes through the ABI shim (see perf_count_wrapper.c) because
  ## `ov_core_compile_model` is variadic. The shim supports up to
  ## `maxPropertyPairs()` pairs and reports an error beyond that instead of
  ## dropping properties silently.
  core.requireOpen("Compile model with properties")
  model.requireOpen("Compile model with properties")
  if properties.len > maxPropertyPairs():
    raise newException(
      OpenVinoError,
      "Too many compile properties: " & $properties.len &
        " (shim supports at most " & $maxPropertyPairs() & ")"
    )

  # The cstring sequences must stay alive for the duration of the call, hence
  # the explicit locals rather than temporaries inside the call expression.
  var keyStrings = newSeq[string](properties.len)
  var valueStrings = newSeq[string](properties.len)
  for i, pair in properties:
    keyStrings[i] = pair[0]
    valueStrings[i] = pair[1]

  var keys = newSeq[cstring](max(properties.len, 1))
  var values = newSeq[cstring](max(properties.len, 1))
  for i in 0 ..< properties.len:
    keys[i] = keyStrings[i].cstring
    values[i] = valueStrings[i].cstring

  var pCompiledModel: ptr OvCompiledModel
  var detail = "device=" & deviceName
  for pair in properties:
    detail.add(" " & pair[0] & "=" & pair[1])

  requireStatus(
    nv_compile_model_with_properties(
      core.pCore,
      model.pModel,
      deviceName.cstring,
      cast[ptr UncheckedArray[cstring]](addr keys[0]),
      cast[ptr UncheckedArray[cstring]](addr values[0]),
      properties.len.csize_t,
      addr pCompiledModel
    ),
    "Compile model with properties",
    detail
  )
  new(result)
  result.pCompiledModel = pCompiledModel

proc importModel*(core: Core, path: string, deviceName: string): CompiledModel =
  core.requireOpen("Import compiled model blob")
  let blob = readFile(path)
  var pCompiledModel: ptr OvCompiledModel
  requireStatus(
    ov_core_import_model(
      core.pCore,
      if blob.len > 0: unsafeAddr blob[0] else: nil,
      blob.len.csize_t,
      deviceName.cstring,
      addr pCompiledModel
    ),
    "Import compiled model blob",
    path
  )
  new(result)
  result.pCompiledModel = pCompiledModel

proc compileOrImportModel*(
  core: Core,
  modelPath: string,
  deviceName: string,
  blobCachePath: string = "",
  enableProfiling: bool = false
): tuple[compiledModel: CompiledModel, cacheHit: bool] =
  if blobCachePath.len > 0 and fileExists(blobCachePath):
    result.compiledModel = core.importModel(blobCachePath, deviceName)
    if enableProfiling:
      requireStatus(
        nv_enable_perf_count(result.compiledModel.pCompiledModel),
        "Re-enable PERF_COUNT after blob import",
        blobCachePath
      )
    result.cacheHit = true
    return

  let model = core.readModel(modelPath)
  result.compiledModel =
    if enableProfiling:
      core.compileModelWithProfiling(model, deviceName)
    else:
      core.compileModel(model, deviceName)

  if blobCachePath.len > 0:
    let parentDir = splitFile(blobCachePath).dir
    if parentDir.len > 0:
      createDir(parentDir)
    result.compiledModel.exportModelToFile(blobCachePath)
