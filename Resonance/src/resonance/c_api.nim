## Low-level OpenVINO C API bindings for Nim.
##
## ---
##
## ## Why the symbols are resolved manually instead of with `{.dynlib.}`
##
## Nim's `{.dynlib.}` pragma loads the library during module initialisation and
## resolves every symbol up front. When the library is missing, the generated
## code calls `nimLoadLibraryError`, which prints `could not load: <dll>` and
## **terminates the process** -- it does not raise a catchable exception.
##
## For a library that is a hard dependency that behaviour is fine. For Isvik it
## is not: an application linking this binding would refuse to start at all on
## a machine without OpenVINO installed, which means even a diagnostic command
## (`isvik doctor`) or a version query could never run. Reporting
## "OpenVINO is not available in this environment" would become impossible.
##
## Therefore the DLL is loaded with `std/dynlib`'s `loadLib`, which returns
## `nil` on failure, and every entry point is a thin Nim wrapper over a
## function pointer. Consequences:
##
## - Importing this module never terminates the process.
## - `tryLoadOpenVino()` reports availability, `openVinoLoadError()` explains
##   the failure, and calling any `ov_*` wrapper without a loaded runtime raises
##   a normal `OpenVinoError`.
## - `perf_count_wrapper.c` already used `GetProcAddress` for the same reason,
##   so the two layers are now consistent.
##
## ---
##
## ## Target OpenVINO version
##
## The enum values below are transcribed from the official header
## `src/bindings/c/include/openvino/c/ov_common.h` of **OpenVINO 2026.3**
## (build `2026.3.0-22451`, the version this project is verified against).
##
## This matters more than it may appear: `ov_element_type_e` values are **not
## stable across OpenVINO releases**:
##
## | | 2023.3 | 2025.4 | 2026.3 |
## | --- | --- | --- | --- |
## | `UNDEFINED` | 0 | 0 | **removed** |
## | `DYNAMIC` | 1 (own value) | 0 (alias of `UNDEFINED`) | **0 (own name)** |
## | `F32` | 5 | 4 | 4 |
## | `U4` | 13 | 14 | 14 |
## | `U8` | 14 | 16 | 16 |
## | `U2` / `U3` / `U6` | absent | present | present |
##
## 2026.3 keeps every numeric value of 2025.4 but drops the `UNDEFINED` spelling,
## so `DYNAMIC` is declared as the primary name here. `OvElementTypeUndefined`
## and `OvElementTypeDynamic` are provided as aliases for source compatibility.
##
## Because these are plain integers crossing the FFI boundary, a mismatch does
## not produce a compile error or a runtime exception -- it silently
## reinterprets tensor data as a different type. Verify the runtime version
## with `ov_get_openvino_version` before trusting these values.

import std/[dynlib, strutils]

{.compile: "perf_count_wrapper.c".}

type
  OvStatus* = enum
    ## Status codes, transcribed from `ov_status_e` (OpenVINO 2026.3).
    ##
    ## All 18 values are declared. The four `*_C_*` codes (-14 .. -17) are
    ## raised by the C wrapper layer itself rather than by the C++ core;
    ## `INVALID_C_PARAM` in particular is common when arguments are wrong.
    ## Omitting them would leave those statuses unrepresentable in Nim, which
    ## breaks `$status` and any `case` over the enum.
    OK = 0
    GENERAL_ERROR = -1
    NOT_IMPLEMENTED = -2
    NETWORK_NOT_LOADED = -3
    PARAMETER_MISMATCH = -4
    NOT_FOUND = -5
    OUT_OF_BOUNDS = -6
    UNEXPECTED = -7
    REQUEST_BUSY = -8
    RESULT_NOT_READY = -9
    NOT_ALLOCATED = -10
    INFER_NOT_STARTED = -11
    NETWORK_NOT_READ = -12
    INFER_CANCELLED = -13
    INVALID_C_PARAM = -14
    UNKNOWN_C_ERROR = -15
    NOT_IMPLEMENT_C_METHOD = -16
    UNKNOW_EXCEPTION = -17

  OvElementType* = enum
    ## Element types, transcribed from `ov_element_type_e` (OpenVINO 2026.3).
    ##
    ## 2026.3 removed the `UNDEFINED` spelling; the value 0 is now named
    ## `DYNAMIC`. Older headers declared `DYNAMIC = UNDEFINED` (both 0) --
    ## Nim enums cannot hold duplicate values, so only one name can live in the
    ## enum. `OvElementTypeUndefined` below keeps the old spelling usable.
    DYNAMIC = 0
    BOOLEAN = 1
    BF16 = 2
    F16 = 3
    F32 = 4
    F64 = 5
    I4 = 6
    I8 = 7
    I16 = 8
    I32 = 9
    I64 = 10
    U1 = 11
    U2 = 12
    U3 = 13
    U4 = 14
    U6 = 15
    U8 = 16
    U16 = 17
    U32 = 18
    U64 = 19
    NF4 = 20
    F8E4M3 = 21
    F8E5M3 = 22
    STRING = 23
    F4E2M1 = 24
    F8E8M0 = 25

  OvVersion* = object
    ## Mirrors `ov_version_t`. Both strings are owned by OpenVINO and must be
    ## released with `ov_version_free`.
    buildNumber*: cstring
    description*: cstring

  OvAvailableDevices* = object
    devices*: cstringArray
    size*: csize_t

  OvShape* = object
    rank*: int64
    dims*: ptr int64

  OvDimension* = object
    min*: int64
    max*: int64

  OvPartialShape* = object
    rank*: OvDimension
    dims*: ptr OvDimension

  OvOutputConstPort* = object
    ## Opaque `ov_output_const_port_t`.
    ##
    ## Represents one input or output port of a model or compiled model.
    ## Needed to read port **names**, which in turn are required to bind
    ## tensors by name -- the only workable approach for a KV-cache, where a
    ## model has dozens of `past_key_values.N.key` style inputs whose indices
    ## are not meaningful to the caller.
    ##
    ## Must be released with `ov_output_const_port_free`.

  OvCore* = object
  OvModel* = object
  OvCompiledModel* = object
  OvInferRequest* = object
  OvTensor* = object

  OvProfilingStatus* = enum
    PROFILING_NOT_RUN = 0
    PROFILING_OPTIMIZED_OUT = 1
    PROFILING_EXECUTED = 2

  OvProfilingInfo* = object
    status*: int32
    realTime*: int64
    cpuTime*: int64
    nodeName*: cstring
    execType*: cstring
    nodeType*: cstring

  OvProfilingInfoList* = object
    profilingInfos*: ptr UncheckedArray[OvProfilingInfo]
    size*: csize_t

  OpenVinoUnavailableError* = object of CatchableError
    ## Raised when an `ov_*` entry point is called while the OpenVINO runtime
    ## could not be loaded.
    ##
    ## Declared here rather than in errors.nim because errors.nim depends on
    ## this module, and the load failure has to be reportable before any status
    ## code exists to translate.

const
  OvElementTypeDynamic* = DYNAMIC
    ## Kept for source compatibility. `DYNAMIC` is now the enum's primary name,
    ## so this alias is redundant for new code but retained because it is part
    ## of the exported surface.
  OvElementTypeUndefined* = DYNAMIC
    ## The `UNDEFINED` spelling of value 0, removed from the C header in 2026.3.
    ## Headers up to 2025.4 declared `DYNAMIC = UNDEFINED`, i.e. the two names
    ## always denoted the same value -- code written against the old name stays
    ## correct.

when defined(windows):
  const dllName* = "openvino_c.dll"
elif defined(linux):
  const dllName* = "libopenvino_c.so"
else:
  const dllName* = "openvino_c.dll"

const
  OvPropertyKeyEnableProfiling* = "PERF_COUNT"
  OvPropertyKeyFullDeviceName* = "FULL_DEVICE_NAME"
  OvPropertyKeySupportedProperties* = "SUPPORTED_PROPERTIES"
  OvPropertyKeyAvailableDevices* = "AVAILABLE_DEVICES"
  OvPropertyKeyDeviceArchitecture* = "DEVICE_ARCHITECTURE"
  OvPropertyKeyDeviceType* = "DEVICE_TYPE"
  OvPropertyKeyOptimalNumberOfInferRequests* = "OPTIMAL_NUMBER_OF_INFER_REQUESTS"
  OvPropertyKeyRangeForAsyncInferRequests* = "RANGE_FOR_ASYNC_INFER_REQUESTS"
  OvPropertyKeyRangeForStreams* = "RANGE_FOR_STREAMS"
  OvPropertyKeyCacheDir* = "CACHE_DIR"
  OvPropertyKeyPerformanceHint* = "PERFORMANCE_HINT"
  OvPropertyKeyNumStreams* = "NUM_STREAMS"
  OvPropertyKeyInferencePrecisionHint* = "INFERENCE_PRECISION_HINT"

# ---------------------------------------------------------------------------
# Function pointers
# ---------------------------------------------------------------------------

var
  ovLib: LibHandle = nil
  ovLoadAttempted = false
  ovLoadErrorMsg = ""
  ovMissingSymbols: seq[string] = @[]

  fnCoreCreate: proc (core: ptr ptr OvCore): OvStatus {.cdecl, raises: [].}
  fnCoreFree: proc (core: ptr OvCore) {.cdecl, raises: [].}
  fnCoreGetAvailableDevices: proc (core: ptr OvCore,
    devices: ptr OvAvailableDevices): OvStatus {.cdecl, raises: [].}
  fnAvailableDevicesFree: proc (devices: ptr OvAvailableDevices) {.cdecl, raises: [].}
  fnCoreReadModel: proc (core: ptr OvCore, model_path: cstring,
    bin_path: cstring, model: ptr ptr OvModel): OvStatus {.cdecl, raises: [].}
  fnPartialShapeCreateDynamic: proc (rank: OvDimension,
    dims: ptr OvDimension, partial_shape: ptr OvPartialShape): OvStatus
    {.cdecl, raises: [].}
  fnPartialShapeFree: proc (partial_shape: ptr OvPartialShape)
    {.cdecl, raises: [].}
  fnModelReshape: proc (model: ptr OvModel, tensor_names: ptr cstring,
    partial_shapes: ptr OvPartialShape, size: csize_t): OvStatus
    {.cdecl, raises: [].}
  fnCoreCompileModel: proc (core: ptr OvCore, model: ptr OvModel,
    device_name: cstring, property_args_size: csize_t,
    compiled_model: ptr ptr OvCompiledModel): OvStatus {.cdecl, raises: [].}
  fnCoreImportModel: proc (core: ptr OvCore, content: pointer,
    content_size: csize_t, device_name: cstring,
    compiled_model: ptr ptr OvCompiledModel): OvStatus {.cdecl, raises: [].}
  fnCoreGetProperty: proc (core: ptr OvCore, device_name: cstring,
    property_key: cstring, property_value: ptr cstring): OvStatus {.cdecl, raises: [].}
  fnCoreAddExtension: proc (core: ptr OvCore,
    library_path: cstring): OvStatus {.cdecl, raises: [].}
    ## Registers a custom-operation library.
    ##
    ## Required for tokenizer IRs: without `openvino_tokenizers.dll` registered,
    ## `ov_core_read_model` on `openvino_tokenizer.xml` fails with
    ## "Cannot create SpecialTokensSplit layer ... from unsupported opset:
    ## extension". Verified on the real DLL: registering it makes the read
    ## succeed (see DEVLOG section 9.5).
  fnCompiledModelCreateInferRequest: proc (
    compiled_model: ptr OvCompiledModel,
    infer_request: ptr ptr OvInferRequest): OvStatus {.cdecl, raises: [].}
  fnCompiledModelExportModel: proc (compiled_model: ptr OvCompiledModel,
    export_model_path: cstring): OvStatus {.cdecl, raises: [].}
  fnInferRequestSetInputTensorByIndex: proc (
    infer_request: ptr OvInferRequest, idx: csize_t,
    tensor: ptr OvTensor): OvStatus {.cdecl, raises: [].}
  fnInferRequestGetOutputTensorByIndex: proc (
    infer_request: ptr OvInferRequest, idx: csize_t,
    tensor: ptr ptr OvTensor): OvStatus {.cdecl, raises: [].}
  fnInferRequestInfer: proc (
    infer_request: ptr OvInferRequest): OvStatus {.cdecl, raises: [].}
  fnInferRequestGetProfilingInfo: proc (infer_request: ptr OvInferRequest,
    profiling_infos: ptr OvProfilingInfoList): OvStatus {.cdecl, raises: [].}
  fnProfilingInfoListFree: proc (
    profiling_infos: ptr OvProfilingInfoList) {.cdecl, raises: [].}
  fnGetLastErrMsg: proc (): cstring {.cdecl, raises: [].}
  fnGetErrorInfo: proc (status: OvStatus): cstring {.cdecl, raises: [].}
  fnFree: proc (content: cstring) {.cdecl, raises: [].}
  fnGetOpenVinoVersion: proc (version: ptr OvVersion): OvStatus {.cdecl, raises: [].}
  fnVersionFree: proc (version: ptr OvVersion) {.cdecl, raises: [].}
  fnTensorCreateFromHostPtr: proc (typ: OvElementType, shape: OvShape,
    host_ptr: pointer, tensor: ptr ptr OvTensor): OvStatus {.cdecl, raises: [].}
  fnTensorCreate: proc (typ: OvElementType, shape: OvShape,
    tensor: ptr ptr OvTensor): OvStatus {.cdecl, raises: [].}
    ## Allocates a tensor whose memory OpenVINO owns.
    ##
    ## Needed for STRING tensors: they cannot be host-backed because the
    ## element type is not a plain byte layout.
  fnTensorSetStringData: proc (tensor: ptr OvTensor, string_data: ptr cstring,
    data_size: csize_t): OvStatus {.cdecl, raises: [].}
    ## Fills a STRING tensor from an array of C strings.
    ##
    ## The `data_size` parameter is declared even though the tensor's shape
    ## already implies the count. Rationale: under cdecl an **extra** argument
    ## is harmless (the callee simply ignores it), while a **missing** one makes
    ## the callee read garbage. If the real signature turns out to take only two
    ## parameters this declaration still works; the reverse would crash.
    ##
    ## Correctness is established empirically by a round-trip test rather than
    ## by trusting this declaration -- see `tests/tbindings.nim`.
  fnTensorData: proc (tensor: ptr OvTensor,
    data: ptr pointer): OvStatus {.cdecl, raises: [].}
  fnTensorGetShape: proc (tensor: ptr OvTensor,
    shape: ptr OvShape): OvStatus {.cdecl, raises: [].}
  fnTensorSetShape: proc (tensor: ptr OvTensor,
    shape: ptr OvShape): OvStatus {.cdecl, raises: [].}
  fnTensorGetElementType: proc (tensor: ptr OvTensor,
    typ: ptr OvElementType): OvStatus {.cdecl, raises: [].}
  fnTensorGetByteSize: proc (tensor: ptr OvTensor,
    byte_size: ptr csize_t): OvStatus {.cdecl, raises: [].}
  fnShapeFree: proc (shape: ptr OvShape): OvStatus {.cdecl, raises: [].}

  # --- Bind tensors by name, and enumerate ports ---
  #
  # Every symbol below was verified to exist in the real `openvino_c.dll`
  # (build 2026.3.0-22451) before being added. That verification matters:
  # `resolveSymbol` treats a missing symbol as a **fatal** load failure, so a
  # single mistyped name here would make the entire runtime unavailable rather
  # than just disabling one feature.
  fnInferRequestSetTensor: proc (infer_request: ptr OvInferRequest,
    tensor_name: cstring, tensor: ptr OvTensor): OvStatus {.cdecl, raises: [].}
  fnInferRequestGetTensor: proc (infer_request: ptr OvInferRequest,
    tensor_name: cstring, tensor: ptr ptr OvTensor): OvStatus {.cdecl, raises: [].}
  fnCompiledModelInputsSize: proc (compiled_model: ptr OvCompiledModel,
    size: ptr csize_t): OvStatus {.cdecl, raises: [].}
  fnCompiledModelOutputsSize: proc (compiled_model: ptr OvCompiledModel,
    size: ptr csize_t): OvStatus {.cdecl, raises: [].}
  fnCompiledModelInputByIndex: proc (compiled_model: ptr OvCompiledModel,
    index: csize_t,
    port: ptr ptr OvOutputConstPort): OvStatus {.cdecl, raises: [].}
  fnCompiledModelOutputByIndex: proc (compiled_model: ptr OvCompiledModel,
    index: csize_t,
    port: ptr ptr OvOutputConstPort): OvStatus {.cdecl, raises: [].}
  fnPortGetAnyName: proc (port: ptr OvOutputConstPort,
    tensor_name: ptr cstring): OvStatus {.cdecl, raises: [].}
  fnConstPortGetShape: proc (port: ptr OvOutputConstPort,
    shape: ptr OvShape): OvStatus {.cdecl, raises: [].}
  fnPortGetElementType: proc (port: ptr OvOutputConstPort,
    typ: ptr OvElementType): OvStatus {.cdecl, raises: [].}
  fnOutputConstPortFree: proc (
    port: ptr OvOutputConstPort) {.cdecl, raises: [].}
  fnModelFree: proc (model: ptr OvModel) {.cdecl, raises: [].}
  fnCompiledModelFree: proc (compiled_model: ptr OvCompiledModel) {.cdecl, raises: [].}
  fnInferRequestFree: proc (infer_request: ptr OvInferRequest) {.cdecl, raises: [].}
  fnTensorFree: proc (tensor: ptr OvTensor) {.cdecl, raises: [].}

# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------

template resolveSymbol(target: untyped, symbolName: string) =
  ## Resolves one symbol into `target`, recording it if absent.
  target = cast[typeof(target)](symAddr(ovLib, symbolName.cstring))
  if target == nil:
    ovMissingSymbols.add(symbolName)

proc tryLoadOpenVino*(): bool =
  ## Loads the platform OpenVINO C library and resolves all entry points.
  ##
  ## Returns whether the runtime is usable. Safe to call repeatedly: the load
  ## is attempted once and the outcome cached.
  ##
  ## Never terminates the process and never raises -- callers that merely want
  ## to *report* availability (such as a diagnostics command) can rely on that.
  if ovLoadAttempted:
    return ovLib != nil

  ovLoadAttempted = true
  ovMissingSymbols = @[]
  ovLib = loadLib(dllName)

  if ovLib == nil:
    ovLoadErrorMsg = "could not load " & dllName &
      " (not found in the library search path or a dependency is missing)"
    return false

  resolveSymbol(fnCoreCreate, "ov_core_create")
  resolveSymbol(fnCoreFree, "ov_core_free")
  resolveSymbol(fnCoreGetAvailableDevices, "ov_core_get_available_devices")
  resolveSymbol(fnAvailableDevicesFree, "ov_available_devices_free")
  resolveSymbol(fnCoreReadModel, "ov_core_read_model")
  resolveSymbol(fnPartialShapeCreateDynamic, "ov_partial_shape_create_dynamic")
  resolveSymbol(fnPartialShapeFree, "ov_partial_shape_free")
  resolveSymbol(fnModelReshape, "ov_model_reshape")
  resolveSymbol(fnCoreCompileModel, "ov_core_compile_model")
  resolveSymbol(fnCoreImportModel, "ov_core_import_model")
  resolveSymbol(fnCoreGetProperty, "ov_core_get_property")
  resolveSymbol(fnCoreAddExtension, "ov_core_add_extension")
  resolveSymbol(fnCompiledModelCreateInferRequest,
                "ov_compiled_model_create_infer_request")
  resolveSymbol(fnCompiledModelExportModel, "ov_compiled_model_export_model")
  resolveSymbol(fnInferRequestSetInputTensorByIndex,
                "ov_infer_request_set_input_tensor_by_index")
  resolveSymbol(fnInferRequestGetOutputTensorByIndex,
                "ov_infer_request_get_output_tensor_by_index")
  resolveSymbol(fnInferRequestInfer, "ov_infer_request_infer")
  resolveSymbol(fnInferRequestGetProfilingInfo,
                "ov_infer_request_get_profiling_info")
  resolveSymbol(fnProfilingInfoListFree, "ov_profiling_info_list_free")
  resolveSymbol(fnGetLastErrMsg, "ov_get_last_err_msg")
  resolveSymbol(fnGetErrorInfo, "ov_get_error_info")
  resolveSymbol(fnFree, "ov_free")
  resolveSymbol(fnGetOpenVinoVersion, "ov_get_openvino_version")
  resolveSymbol(fnVersionFree, "ov_version_free")
  resolveSymbol(fnTensorCreateFromHostPtr, "ov_tensor_create_from_host_ptr")
  resolveSymbol(fnTensorCreate, "ov_tensor_create")
  resolveSymbol(fnTensorSetStringData, "ov_tensor_set_string_data")
  resolveSymbol(fnTensorData, "ov_tensor_data")
  resolveSymbol(fnTensorGetShape, "ov_tensor_get_shape")
  resolveSymbol(fnTensorSetShape, "ov_tensor_set_shape")
  resolveSymbol(fnTensorGetElementType, "ov_tensor_get_element_type")
  resolveSymbol(fnTensorGetByteSize, "ov_tensor_get_byte_size")
  resolveSymbol(fnShapeFree, "ov_shape_free")
  resolveSymbol(fnInferRequestSetTensor, "ov_infer_request_set_tensor")
  resolveSymbol(fnInferRequestGetTensor, "ov_infer_request_get_tensor")
  resolveSymbol(fnCompiledModelInputsSize, "ov_compiled_model_inputs_size")
  resolveSymbol(fnCompiledModelOutputsSize, "ov_compiled_model_outputs_size")
  resolveSymbol(fnCompiledModelInputByIndex,
                "ov_compiled_model_input_by_index")
  resolveSymbol(fnCompiledModelOutputByIndex,
                "ov_compiled_model_output_by_index")
  resolveSymbol(fnPortGetAnyName, "ov_port_get_any_name")
  resolveSymbol(fnConstPortGetShape, "ov_const_port_get_shape")
  resolveSymbol(fnPortGetElementType, "ov_port_get_element_type")
  resolveSymbol(fnOutputConstPortFree, "ov_output_const_port_free")
  resolveSymbol(fnModelFree, "ov_model_free")
  resolveSymbol(fnCompiledModelFree, "ov_compiled_model_free")
  resolveSymbol(fnInferRequestFree, "ov_infer_request_free")
  resolveSymbol(fnTensorFree, "ov_tensor_free")

  if ovMissingSymbols.len > 0:
    # The DLL loaded but does not expose everything expected. Rather than
    # failing later at an arbitrary call site, report it now with the list of
    # missing names -- that usually means a version mismatch.
    ovLoadErrorMsg = dllName & " loaded but is missing " &
      $ovMissingSymbols.len & " expected symbol(s): " &
      ovMissingSymbols.join(", ")
    unloadLib(ovLib)
    ovLib = nil
    return false

  ovLoadErrorMsg = ""
  result = true

proc isOpenVinoLoaded*(): bool {.raises: [].} =
  ## Whether the runtime has been loaded successfully. Does not trigger a load.
  ovLib != nil

proc openVinoLoadError*(): string =
  ## Why loading failed. Empty when loaded, or when no attempt has been made.
  ovLoadErrorMsg

proc openVinoMissingSymbols*(): seq[string] =
  ## Symbols that were expected but not found in the DLL.
  ovMissingSymbols

proc openVinoLibraryPath*(): string =
  ## The library name being loaded.
  ##
  ## Deliberately returns the *name*, not a resolved absolute path: the OS
  ## search order decides which file is used, and pretending to know the exact
  ## path would be misleading. `isvik doctor` reports the search situation
  ## separately.
  dllName

proc unloadOpenVino*() =
  ## Unloads the runtime.
  ##
  ## Not called automatically. Unloading while OpenVINO objects are still alive
  ## would crash, and process exit unloads it anyway; an explicit call is only
  ## meaningful in tests that want a clean slate.
  if ovLib != nil:
    unloadLib(ovLib)
    ovLib = nil
  ovLoadAttempted = false
  ovLoadErrorMsg = ""
  ovMissingSymbols = @[]

proc requireOpenVino() {.inline.} =
  ## Ensures the runtime is usable, raising a catchable error otherwise.
  if not tryLoadOpenVino():
    raise newException(
      OpenVinoUnavailableError,
      "OpenVINO runtime is not available: " & ovLoadErrorMsg
    )

# ---------------------------------------------------------------------------
# Core
# ---------------------------------------------------------------------------

proc ov_core_create*(core: ptr ptr OvCore): OvStatus =
  requireOpenVino()
  fnCoreCreate(core)

proc ov_core_free*(core: ptr OvCore) {.raises: [].} =
  # Release paths must not raise: they are called from destructors, where an
  # exception would be worse than a leak. If the runtime is gone there is
  # nothing left to free anyway.
  if isOpenVinoLoaded() and fnCoreFree != nil:
    fnCoreFree(core)

proc ov_core_get_available_devices*(core: ptr OvCore,
                                   devices: ptr OvAvailableDevices): OvStatus =
  requireOpenVino()
  fnCoreGetAvailableDevices(core, devices)

proc ov_available_devices_free*(devices: ptr OvAvailableDevices) {.raises: [].} =
  if isOpenVinoLoaded() and fnAvailableDevicesFree != nil:
    fnAvailableDevicesFree(devices)

proc ov_core_read_model*(core: ptr OvCore, model_path: cstring,
                         bin_path: cstring, model: ptr ptr OvModel): OvStatus =
  requireOpenVino()
  fnCoreReadModel(core, model_path, bin_path, model)

proc ov_partial_shape_create_dynamic*(rank: OvDimension,
                                      dims: ptr OvDimension,
                                      partial_shape: ptr OvPartialShape): OvStatus =
  requireOpenVino()
  fnPartialShapeCreateDynamic(rank, dims, partial_shape)

proc ov_partial_shape_free*(partial_shape: ptr OvPartialShape) {.raises: [].} =
  if isOpenVinoLoaded() and fnPartialShapeFree != nil:
    fnPartialShapeFree(partial_shape)

proc ov_model_reshape*(model: ptr OvModel, tensor_names: ptr cstring,
                       partial_shapes: ptr OvPartialShape,
                       size: csize_t): OvStatus =
  requireOpenVino()
  fnModelReshape(model, tensor_names, partial_shapes, size)

proc ov_core_compile_model*(core: ptr OvCore, model: ptr OvModel,
                            device_name: cstring, property_args_size: csize_t,
                            compiled_model: ptr ptr OvCompiledModel): OvStatus =
  ## Note: the C function is variadic. This wrapper can only be used with
  ## `property_args_size == 0`; property pairs must go through
  ## `nv_compile_model_with_properties`.
  requireOpenVino()
  fnCoreCompileModel(core, model, device_name, property_args_size, compiled_model)

proc ov_core_import_model*(core: ptr OvCore, content: pointer,
                           content_size: csize_t, device_name: cstring,
                           compiled_model: ptr ptr OvCompiledModel): OvStatus =
  requireOpenVino()
  fnCoreImportModel(core, content, content_size, device_name, compiled_model)

proc ov_core_get_property*(core: ptr OvCore, device_name: cstring,
                           property_key: cstring,
                           property_value: ptr cstring): OvStatus =
  ## Reads a device property.
  ##
  ## Not variadic in the C API, so no ABI shim is needed. The returned string
  ## must be released with `ov_free`.
  requireOpenVino()
  fnCoreGetProperty(core, device_name, property_key, property_value)

proc ov_core_add_extension*(core: ptr OvCore,
                            library_path: cstring): OvStatus =
  ## Registers a custom-operation library with this core.
  ##
  ## Needed before reading a tokenizer IR. Registration is per-core, so it must
  ## happen on the same core that later reads the model.
  requireOpenVino()
  fnCoreAddExtension(core, library_path)

# ---------------------------------------------------------------------------
# Compiled model
# ---------------------------------------------------------------------------

proc ov_compiled_model_create_infer_request*(
    compiled_model: ptr OvCompiledModel,
    infer_request: ptr ptr OvInferRequest): OvStatus =
  requireOpenVino()
  fnCompiledModelCreateInferRequest(compiled_model, infer_request)

proc ov_compiled_model_export_model*(compiled_model: ptr OvCompiledModel,
                                     export_model_path: cstring): OvStatus =
  requireOpenVino()
  fnCompiledModelExportModel(compiled_model, export_model_path)

# ---------------------------------------------------------------------------
# Infer request
# ---------------------------------------------------------------------------

proc ov_infer_request_set_input_tensor_by_index*(
    infer_request: ptr OvInferRequest, idx: csize_t,
    tensor: ptr OvTensor): OvStatus =
  requireOpenVino()
  fnInferRequestSetInputTensorByIndex(infer_request, idx, tensor)

proc ov_infer_request_get_output_tensor_by_index*(
    infer_request: ptr OvInferRequest, idx: csize_t,
    tensor: ptr ptr OvTensor): OvStatus =
  requireOpenVino()
  fnInferRequestGetOutputTensorByIndex(infer_request, idx, tensor)

proc ov_infer_request_infer*(infer_request: ptr OvInferRequest): OvStatus =
  requireOpenVino()
  fnInferRequestInfer(infer_request)

proc ov_infer_request_get_profiling_info*(
    infer_request: ptr OvInferRequest,
    profiling_infos: ptr OvProfilingInfoList): OvStatus =
  requireOpenVino()
  fnInferRequestGetProfilingInfo(infer_request, profiling_infos)

proc ov_profiling_info_list_free*(profiling_infos: ptr OvProfilingInfoList) {.raises: [].} =
  if isOpenVinoLoaded() and fnProfilingInfoListFree != nil:
    fnProfilingInfoListFree(profiling_infos)

# ---------------------------------------------------------------------------
# Errors and memory
# ---------------------------------------------------------------------------

proc ov_get_last_err_msg*(): cstring {.raises: [].} =
  ## Returns nil when the runtime is unavailable, so that error-reporting code
  ## can call it unconditionally without risking a nested failure.
  if isOpenVinoLoaded() and fnGetLastErrMsg != nil:
    fnGetLastErrMsg()
  else:
    nil

proc ov_get_error_info*(status: OvStatus): cstring {.raises: [].} =
  ## Maps a status code to a static human-readable description.
  ##
  ## **Do not pass the result to `ov_free`.** Unlike most `cstring` values
  ## coming out of the C API, this one points into storage owned by OpenVINO
  ## that stays valid for the lifetime of the process. Freeing it corrupts the
  ## heap, and the corruption typically surfaces far away from this call.
  ##
  ## This is the opposite convention from `ov_core_get_property`, whose
  ## out-parameter *must* be released with `ov_free` -- hence the explicit note.
  ##
  ## Returns nil when the runtime is unavailable.
  if isOpenVinoLoaded() and fnGetErrorInfo != nil:
    fnGetErrorInfo(status)
  else:
    nil

proc ov_free*(content: cstring) {.raises: [].} =
  ## Releases a string allocated by OpenVINO (e.g. the out-parameter of
  ## `ov_core_get_property`). Do not use Nim's `dealloc` for those.
  if isOpenVinoLoaded() and fnFree != nil:
    fnFree(content)

# ---------------------------------------------------------------------------
# Runtime version
# ---------------------------------------------------------------------------

proc ov_get_openvino_version*(version: ptr OvVersion): OvStatus =
  requireOpenVino()
  fnGetOpenVinoVersion(version)

proc ov_version_free*(version: ptr OvVersion) {.raises: [].} =
  if isOpenVinoLoaded() and fnVersionFree != nil:
    fnVersionFree(version)

# ---------------------------------------------------------------------------
# Tensor and shape
# ---------------------------------------------------------------------------

proc ov_tensor_create_from_host_ptr*(typ: OvElementType, shape: OvShape,
                                     host_ptr: pointer,
                                     tensor: ptr ptr OvTensor): OvStatus =
  requireOpenVino()
  fnTensorCreateFromHostPtr(typ, shape, host_ptr, tensor)

proc ov_tensor_create*(typ: OvElementType, shape: OvShape,
                       tensor: ptr ptr OvTensor): OvStatus =
  ## Allocates a tensor with runtime-owned memory.
  ##
  ## Unlike `ov_tensor_create_from_host_ptr` this works for STRING tensors,
  ## whose elements are not a flat byte layout and therefore cannot be backed
  ## by caller memory.
  requireOpenVino()
  fnTensorCreate(typ, shape, tensor)

proc ov_tensor_set_string_data*(tensor: ptr OvTensor, string_data: ptr cstring,
                                data_size: csize_t): OvStatus =
  ## Fills a STRING tensor from an array of NUL-terminated C strings.
  ##
  ## The runtime copies the strings, so the caller's buffers only need to
  ## outlive this call.
  requireOpenVino()
  fnTensorSetStringData(tensor, string_data, data_size)

proc ov_tensor_data*(tensor: ptr OvTensor, data: ptr pointer): OvStatus =
  requireOpenVino()
  fnTensorData(tensor, data)

proc ov_tensor_get_shape*(tensor: ptr OvTensor, shape: ptr OvShape): OvStatus =
  requireOpenVino()
  fnTensorGetShape(tensor, shape)

proc ov_tensor_set_shape*(tensor: ptr OvTensor, shape: ptr OvShape): OvStatus =
  requireOpenVino()
  fnTensorSetShape(tensor, shape)

proc ov_tensor_get_element_type*(tensor: ptr OvTensor,
                                 typ: ptr OvElementType): OvStatus =
  ## Needed for *output* tensors, whose element type is decided by the model
  ## rather than by the caller and therefore cannot be assumed.
  requireOpenVino()
  fnTensorGetElementType(tensor, typ)

proc ov_tensor_get_byte_size*(tensor: ptr OvTensor,
                              byte_size: ptr csize_t): OvStatus =
  ## Authoritative allocation size of the tensor's data.
  ##
  ## Preferred over `elementCount * elementSize`: for sub-byte element types
  ## those disagree, and only OpenVINO knows the real padded size.
  requireOpenVino()
  fnTensorGetByteSize(tensor, byte_size)

# ---------------------------------------------------------------------------
# Bind by name, and port introspection
# ---------------------------------------------------------------------------

proc ov_infer_request_set_tensor*(infer_request: ptr OvInferRequest,
                                  tensor_name: cstring,
                                  tensor: ptr OvTensor): OvStatus =
  requireOpenVino()
  fnInferRequestSetTensor(infer_request, tensor_name, tensor)

proc ov_infer_request_get_tensor*(infer_request: ptr OvInferRequest,
                                  tensor_name: cstring,
                                  tensor: ptr ptr OvTensor): OvStatus =
  requireOpenVino()
  fnInferRequestGetTensor(infer_request, tensor_name, tensor)

proc ov_compiled_model_inputs_size*(compiled_model: ptr OvCompiledModel,
                                    size: ptr csize_t): OvStatus =
  requireOpenVino()
  fnCompiledModelInputsSize(compiled_model, size)

proc ov_compiled_model_outputs_size*(compiled_model: ptr OvCompiledModel,
                                     size: ptr csize_t): OvStatus =
  requireOpenVino()
  fnCompiledModelOutputsSize(compiled_model, size)

proc ov_compiled_model_input_by_index*(compiled_model: ptr OvCompiledModel,
                                       index: csize_t,
                                       port: ptr ptr OvOutputConstPort): OvStatus =
  requireOpenVino()
  fnCompiledModelInputByIndex(compiled_model, index, port)

proc ov_compiled_model_output_by_index*(compiled_model: ptr OvCompiledModel,
                                        index: csize_t,
                                        port: ptr ptr OvOutputConstPort): OvStatus =
  requireOpenVino()
  fnCompiledModelOutputByIndex(compiled_model, index, port)

proc ov_port_get_any_name*(port: ptr OvOutputConstPort,
                           tensor_name: ptr cstring): OvStatus =
  ## Reads a port's name.
  ##
  ## The returned string is allocated by OpenVINO and must be released with
  ## `ov_free` -- not with `ov_shape_free` and not with Nim's `dealloc`.
  requireOpenVino()
  fnPortGetAnyName(port, tensor_name)

proc ov_const_port_get_shape*(port: ptr OvOutputConstPort,
                              shape: ptr OvShape): OvStatus =
  ## Reads a const port's shape.
  ##
  ## Note the name: const ports use `ov_const_port_get_shape`, while mutable
  ## ports use `ov_port_get_shape`. Both exist in the DLL and they are not
  ## interchangeable.
  requireOpenVino()
  fnConstPortGetShape(port, shape)

proc ov_port_get_element_type*(port: ptr OvOutputConstPort,
                               typ: ptr OvElementType): OvStatus =
  requireOpenVino()
  fnPortGetElementType(port, typ)

proc ov_output_const_port_free*(port: ptr OvOutputConstPort) {.raises: [].} =
  if isOpenVinoLoaded() and fnOutputConstPortFree != nil:
    fnOutputConstPortFree(port)

proc ov_shape_free*(shape: ptr OvShape): OvStatus {.raises: [].} =
  if isOpenVinoLoaded() and fnShapeFree != nil:
    fnShapeFree(shape)
  else:
    OK

# ---------------------------------------------------------------------------
# Handle release
# ---------------------------------------------------------------------------

proc ov_model_free*(model: ptr OvModel) {.raises: [].} =
  if isOpenVinoLoaded() and fnModelFree != nil:
    fnModelFree(model)

proc ov_compiled_model_free*(compiled_model: ptr OvCompiledModel) {.raises: [].} =
  if isOpenVinoLoaded() and fnCompiledModelFree != nil:
    fnCompiledModelFree(compiled_model)

proc ov_infer_request_free*(infer_request: ptr OvInferRequest) {.raises: [].} =
  if isOpenVinoLoaded() and fnInferRequestFree != nil:
    fnInferRequestFree(infer_request)

proc ov_tensor_free*(tensor: ptr OvTensor) {.raises: [].} =
  if isOpenVinoLoaded() and fnTensorFree != nil:
    fnTensorFree(tensor)

# ---------------------------------------------------------------------------
# Windows x64 variadic ABI shims (see perf_count_wrapper.c)
# ---------------------------------------------------------------------------
#
# `ov_core_compile_model` and `ov_core_set_property` take property pairs
# through `...`. On Windows x64 the OpenVINO DLL is built with MSVC while Nim
# is commonly built with MinGW; variadic calls across those ABIs are fragile.
# The shims resolve the symbols with GetProcAddress and expose stable,
# non-variadic cdecl entry points.
#
# These are statically linked (compiled from perf_count_wrapper.c), so they are
# always callable. They perform their own runtime lookup and return
# GENERAL_ERROR when the DLL is unavailable, which is why they do not need the
# `requireOpenVino` guard.

proc nv_compile_model_with_perf_count*(
  core: ptr OvCore,
  model: ptr OvModel,
  device_name: cstring,
  compiled_model: ptr ptr OvCompiledModel
): OvStatus {.cdecl, importc: "nv_compile_model_with_perf_count".}
  ## Kept for backward compatibility. Equivalent to
  ## `nv_compile_model_with_properties` with a single `PERF_COUNT=YES` pair.

proc nv_enable_perf_count*(compiled_model: ptr OvCompiledModel): OvStatus
  {.cdecl, importc: "nv_enable_perf_count".}

proc nv_compile_model_with_properties*(
  core: ptr OvCore,
  model: ptr OvModel,
  device_name: cstring,
  keys: ptr UncheckedArray[cstring],
  values: ptr UncheckedArray[cstring],
  pair_count: csize_t,
  compiled_model: ptr ptr OvCompiledModel
): OvStatus {.cdecl, importc: "nv_compile_model_with_properties".}
  ## Compiles a model with an arbitrary set of property pairs.
  ##
  ## C cannot construct a variadic call with a runtime-determined argument
  ## count, so the shim switches over `pair_count`. Exceeding the supported
  ## maximum returns `INVALID_C_PARAM` rather than silently dropping
  ## properties.

proc nv_core_set_property*(
  core: ptr OvCore,
  device_name: cstring,
  key: cstring,
  value: cstring
): OvStatus {.cdecl, importc: "nv_core_set_property".}
  ## Sets a single property on a device (e.g. `CACHE_DIR`).

proc nv_max_property_pairs*(): cint {.cdecl, importc: "nv_max_property_pairs".}
  ## Maximum number of property pairs the shim can forward. Exposed so that
  ## Nim-side code and tests do not have to hardcode the C-side limit.


