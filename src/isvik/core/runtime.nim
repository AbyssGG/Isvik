## Isvik Runtime
##
## 对应 Master Prompt §8(Runtime 生命周期)与 §49(PHASE 2)。
##
## ---
##
## ## 生命周期
##
## ```text
## Initialize → Discover Devices → Load Model → Compile
##            → Create Request → Inference → Unload → Shutdown
## ```
##
## ---
##
## ## 为什么返回不透明 ID 而不是直接返回句柄对象
##
## §8 要求保证 no use-after-free、no double free、no dangling pointer。
## 如果把 `BackendModel` 直接交给调用方,调用方在释放之后仍然持有一个
## 看起来有效的引用,再次使用就会触碰已释放的原生内存 —— 这类崩溃很难定位。
##
## 因此 Runtime 只交出 `ModelId` / `CompiledModelId` / `InferRequestId`
## 这类不透明整数句柄,真实对象保存在 Runtime 内部的表中。释放时从表里删除,
## 之后再用该 ID 会得到一个明确的 `INVALID_PARAMETER` 错误,而不是内存崩溃。
##
## 这不是为了抽象而抽象,而是把「悬空指针」降级成「可诊断的错误码」。
##
## ---
##
## ## 级联释放
##
## 原生资源之间存在依赖:InferRequest 依赖 CompiledModel,
## CompiledModel 派生自 Model。释放父资源时会**级联释放**其子资源,
## 保证不留下引用了已释放对象的句柄。
##
## ```text
## releaseModel(m)          → 释放由 m 编译出的所有 CompiledModel
##                           → 以及它们创建的所有 InferRequest
## releaseCompiledModel(cm) → 释放 cm 创建的所有 InferRequest
## ```
##
## ---
##
## Runtime 当前是单线程的:没有加锁。并发推理需要在引入 worker / async 时
## (§70)显式设计同步,而不是假装现在就是线程安全的。

import std/[tables, times, json, monotimes]

import isvik/core/errors
import isvik/core/events
import isvik/core/backend
import isvik/core/device_manager
import isvik/core/tensor

# Runtime 的设备接口返回 device_manager 的类型,调用方需要它们才能使用返回值。
# 重导出的是 Core 自己的模块,不涉及任何 Backend 类型泄漏。
export device_manager

type
  RuntimeState* = enum
    ## Runtime 的粗粒度状态。
    ##
    ## 有意保持只有三个状态:§8 描述的是操作序列而不是复杂状态机,
    ## 把每个操作阶段都做成状态会带来大量无意义的状态迁移校验。
    rsUninitialized = "UNINITIALIZED"
    rsReady = "READY"
    rsShutdown = "SHUTDOWN"

  ModelId* = distinct int
  CompiledModelId* = distinct int
  InferRequestId* = distinct int

  ModelEntry = object
    handle: BackendModel
    path: string

  CompiledEntry = object
    handle: BackendCompiledModel
    modelId: int      ## 来源模型 ID;0 表示由 blob 导入,无来源模型
    device: string
      ## 实际用于编译的 Backend rawName。
    requestedDevice: string
      ## 调用方请求的值。走语义入口时是 AUTO / CPU / GPU / NPU;
      ## 走 rawName 低层入口时与 `device` 相同。
    deviceType: string
      ## 解析出的 DeviceType。低层入口未经解析时为空字符串。
    deviceFullName: string
      ## Backend 报告的设备全名。取不到时为空,不用 rawName 冒充(§27)。

  RequestEntry = object
    handle: BackendInferRequest
    compiledId: int

  RuntimeObj = object
    backend: Backend
    bus: EventBus
    state: RuntimeState
    models: Table[int, ModelEntry]
    compiled: Table[int, CompiledEntry]
    requests: Table[int, RequestEntry]
    nextId: int
    devices: seq[BackendDeviceInfo]
    devicesDiscovered: bool
    deviceManager: DeviceManager
      ## 语义设备快照。与 `devices` 来自同一次发现结果,
      ## 因此设备选择始终绑定在同一 snapshot 上,不会与缓存脱节。

  Runtime* = ref RuntimeObj

proc `==`*(a, b: ModelId): bool {.borrow.}
proc `==`*(a, b: CompiledModelId): bool {.borrow.}
proc `==`*(a, b: InferRequestId): bool {.borrow.}
proc `$`*(id: ModelId): string {.borrow.}
proc `$`*(id: CompiledModelId): string {.borrow.}
proc `$`*(id: InferRequestId): string {.borrow.}

# ---------------------------------------------------------------------------
# 构造
# ---------------------------------------------------------------------------

proc newRuntime*(backend: Backend, bus: EventBus = nil): Runtime =
  ## 创建 Runtime。**不会**自动初始化 Backend,需显式调用 `initialize`。
  ##
  ## `bus` 可为 nil(不需要事件时),此处不强制要求事件总线,
  ## 以便单元测试用最小依赖构造 Runtime。
  doAssert backend != nil, "Runtime 需要一个 Backend"
  new(result)
  result.backend = backend
  result.bus = bus
  result.state = rsUninitialized
  result.models = initTable[int, ModelEntry]()
  result.compiled = initTable[int, CompiledEntry]()
  result.requests = initTable[int, RequestEntry]()
  result.nextId = 1
  result.devices = @[]
  result.devicesDiscovered = false
  result.deviceManager = newDeviceManager(
    backend.name(), newSeq[BackendDeviceInfo]())

proc state*(rt: Runtime): RuntimeState = rt.state
proc backendName*(rt: Runtime): string = rt.backend.name()
proc backendVersion*(rt: Runtime): string = rt.backend.version()

proc loadedModelCount*(rt: Runtime): int = rt.models.len
proc compiledModelCount*(rt: Runtime): int = rt.compiled.len
proc activeRequestCount*(rt: Runtime): int = rt.requests.len

# ---------------------------------------------------------------------------
# 内部辅助
# ---------------------------------------------------------------------------

proc emit(rt: Runtime, kind: RuntimeEventKind, message: string,
          payload: JsonNode = nil) =
  ## 发布事件。总线为 nil 时静默跳过。
  if rt.bus != nil:
    rt.bus.publish(kind, message, payload)

proc emitError(rt: Runtime, operation: string, e: ref IsvikError) =
  ## 把错误作为结构化事件发布,供 GUI Activity 展示(§29)。
  ##
  ## 只放入错误码与 message;detail 可能含敏感路径,不进入事件 payload
  ## (与 core/errors 中 detail 不进 API 响应的边界保持一致)。
  rt.emit(rekError, e.msg, %*{
    "operation": operation,
    "code": $e.code
  })

template guardedOperation(rt: Runtime, operation: string, body: untyped) =
  ## 执行 body,若抛出 IsvikError 则先发布错误事件再原样重抛。
  ##
  ## 重抛而不是吞掉:调用方必须知道操作失败了。事件只是额外的可观测性。
  try:
    body
  except IsvikError as e:
    rt.emitError(operation, e)
    raise

proc requireReady(rt: Runtime, operation: string) =
  ## 校验 Runtime 处于可用状态。
  if rt.state == rsReady:
    return
  raiseIsvikError(
    ecBackendNotAvailable,
    "Runtime is not ready for this operation",
    "operation=" & operation & " state=" & $rt.state
  )

proc nextHandleId(rt: Runtime): int =
  ## 分配下一个句柄 ID。
  ##
  ## 三类句柄共用一个计数器:这样任意两个句柄的数值永不相同,
  ## 即使调用方错误地把 ModelId 的数值当成 RequestId 使用,
  ## 也只会命中「不存在」而不会误命中另一个真实资源。
  result = rt.nextId
  inc rt.nextId

proc lookupModel(rt: Runtime, id: ModelId): ModelEntry =
  let key = int(id)
  if not rt.models.hasKey(key):
    raiseIsvikError(
      ecInvalidParameter,
      "Unknown or already released model handle",
      "modelId=" & $key
    )
  result = rt.models[key]

proc lookupCompiled(rt: Runtime, id: CompiledModelId): CompiledEntry =
  let key = int(id)
  if not rt.compiled.hasKey(key):
    raiseIsvikError(
      ecInvalidParameter,
      "Unknown or already released compiled model handle",
      "compiledModelId=" & $key
    )
  result = rt.compiled[key]

proc lookupRequest(rt: Runtime, id: InferRequestId): RequestEntry =
  let key = int(id)
  if not rt.requests.hasKey(key):
    raiseIsvikError(
      ecInvalidParameter,
      "Unknown or already released infer request handle",
      "inferRequestId=" & $key
    )
  result = rt.requests[key]

# ---------------------------------------------------------------------------
# 初始化与关闭
# ---------------------------------------------------------------------------

proc initialize*(rt: Runtime) =
  ## 初始化 Backend 并进入 READY 状态。
  ##
  ## 已就绪时重复调用是无操作(幂等)。已关闭后不允许重新初始化 ——
  ## 复用一个 shutdown 过的 Runtime 会让资源归属变得含糊,
  ## 需要新实例时应显式创建。
  if rt.state == rsReady:
    return
  if rt.state == rsShutdown:
    raiseIsvikError(
      ecBackendNotAvailable,
      "Runtime has been shut down and cannot be reinitialized",
      "state=" & $rt.state
    )

  guardedOperation(rt, "initialize"):
    rt.backend.initialize()
    rt.state = rsReady

  rt.emit(rekRuntimeStarted, "Isvik runtime initialized")
  rt.emit(rekBackendLoaded, "Backend loaded", %*{
    "backend": rt.backend.name(),
    "version": rt.backend.version()
  })

proc releaseInferRequest*(rt: Runtime, id: InferRequestId) =
  ## 释放推理请求。ID 无效时抛 INVALID_PARAMETER。
  let entry = rt.lookupRequest(id)
  # 先从表中删除,再释放原生资源:即使释放过程抛错,
  # 该 ID 也不会留在表里指向一个状态未知的对象。
  rt.requests.del(int(id))
  rt.backend.releaseInferRequest(entry.handle)

proc releaseCompiledModel*(rt: Runtime, id: CompiledModelId) =
  ## 释放已编译模型,并级联释放由它创建的所有推理请求。
  let entry = rt.lookupCompiled(id)
  let key = int(id)

  var dependents: seq[int] = @[]
  for reqId, reqEntry in rt.requests:
    if reqEntry.compiledId == key:
      dependents.add(reqId)
  for reqId in dependents:
    rt.releaseInferRequest(InferRequestId(reqId))

  rt.compiled.del(key)
  rt.backend.releaseCompiledModel(entry.handle)

proc unloadModel*(rt: Runtime, id: ModelId) =
  ## 卸载模型,并级联释放由它编译出的所有已编译模型(及其推理请求)。
  let entry = rt.lookupModel(id)
  let key = int(id)

  var dependents: seq[int] = @[]
  for compiledId, compiledEntry in rt.compiled:
    if compiledEntry.modelId == key:
      dependents.add(compiledId)
  for compiledId in dependents:
    rt.releaseCompiledModel(CompiledModelId(compiledId))

  rt.models.del(key)
  rt.backend.releaseModel(entry.handle)

proc shutdown*(rt: Runtime) =
  ## 释放全部资源并关闭 Backend。可重复调用。
  ##
  ## 释放顺序为 请求 → 已编译模型 → 模型 → Backend,与依赖方向相反,
  ## 保证不会在释放父资源后再去访问子资源。
  if rt.state == rsShutdown:
    return

  # 逐层收集键再释放,避免在迭代表的过程中修改它。
  var requestIds: seq[int] = @[]
  for id in rt.requests.keys:
    requestIds.add(id)
  for id in requestIds:
    try:
      rt.releaseInferRequest(InferRequestId(id))
    except CatchableError:
      # shutdown 必须尽力清理完所有资源。单个释放失败不应中断后续清理,
      # 否则会泄漏更多资源。
      discard

  var compiledIds: seq[int] = @[]
  for id in rt.compiled.keys:
    compiledIds.add(id)
  for id in compiledIds:
    try:
      rt.releaseCompiledModel(CompiledModelId(id))
    except CatchableError:
      discard

  var modelIds: seq[int] = @[]
  for id in rt.models.keys:
    modelIds.add(id)
  for id in modelIds:
    try:
      rt.unloadModel(ModelId(id))
    except CatchableError:
      discard

  try:
    rt.backend.release()
  except CatchableError:
    discard

  rt.state = rsShutdown
  rt.devicesDiscovered = false
  rt.devices = @[]
  rt.deviceManager.updateDevices(newSeq[BackendDeviceInfo]())

# ---------------------------------------------------------------------------
# 设备发现
# ---------------------------------------------------------------------------

proc discoverDevices*(rt: Runtime, forceRefresh: bool = false):
    seq[BackendDeviceInfo] =
  ## 列出 Backend 报告的设备。结果被缓存,`forceRefresh` 可强制重新发现。
  ##
  ## 缓存的理由:设备枚举在 OpenVINO 上有实际开销,而 CLI / GUI 会频繁查询。
  ## 设备热插拔(如外接 GPU)需要显式 refresh,不做隐式轮询。
  rt.requireReady("discoverDevices")

  if rt.devicesDiscovered and not forceRefresh:
    return rt.devices

  guardedOperation(rt, "discoverDevices"):
    rt.devices = rt.backend.discoverDevices()
    rt.devicesDiscovered = true
    # 语义快照必须与原始快照同步更新,否则设备选择会基于过期信息。
    rt.deviceManager.updateDevices(rt.devices)

  for device in rt.devices:
    rt.emit(rekDeviceDetected, "Device detected", %*{
      "device": device.rawName,
      "fullName": device.fullName
    })

  result = rt.devices

proc semanticDevices*(rt: Runtime, forceRefresh: bool = false):
    seq[DeviceInfo] =
  ## 经 Device Manager 解析后的设备列表(§11 的统一设备模型)。
  ##
  ## 需要时自动触发一次发现,因此 CLI / Services 不必先手动调用
  ## `discoverDevices`。语义信息包含 DeviceType、vendor 与策略资格,
  ## 而 `rawName` / `fullName` 仍是 Backend 的原始值。
  discard rt.discoverDevices(forceRefresh)
  result = rt.deviceManager.devices()

proc resolveDevice*(rt: Runtime, requested: string = DeviceRequestAuto,
                    excluded: seq[string] = @[]):
    DeviceSelection =
  ## 把语义设备请求(AUTO / CPU / GPU / NPU,空串等价 AUTO)解析为实际设备。
  ##
  ## 这是 §12 AUTO Policy 在 Runtime 上的入口。放在 `guardedOperation` 内
  ## 执行,使设备选择失败也会发布 Runtime 错误事件,与其它操作一致 ——
  ## 否则「AUTO 选不出设备」这种事在 Activity 里看不见。
  rt.requireReady("resolveDevice")
  discard rt.discoverDevices()

  var selection: DeviceSelection
  guardedOperation(rt, "resolveDevice"):
    selection = rt.deviceManager.resolveDevice(requested, excluded)
  result = selection

# ---------------------------------------------------------------------------
# 模型
# ---------------------------------------------------------------------------

proc loadModel*(rt: Runtime, path: string): ModelId =
  ## 加载模型,返回句柄。
  rt.requireReady("loadModel")

  var handle: BackendModel
  guardedOperation(rt, "loadModel"):
    handle = rt.backend.loadModel(path)

  let id = rt.nextHandleId()
  rt.models[id] = ModelEntry(handle: handle, path: path)

  rt.emit(rekModelLoaded, "Model loaded", %*{
    "modelId": id,
    "path": path
  })
  result = ModelId(id)

proc modelPath*(rt: Runtime, id: ModelId): string =
  ## 该模型句柄对应的加载路径。
  rt.lookupModel(id).path

proc reshapeModel*(rt: Runtime, id: ModelId,
                   inputs: openArray[ModelInputShape]) =
  ## 在首次编译前为动态输入设置有依据的上下界。
  rt.requireReady("reshapeModel")
  let entry = rt.lookupModel(id)
  for _, compiledEntry in rt.compiled:
    if compiledEntry.modelId == int(id):
      raiseIsvikError(
        ecInvalidParameter,
        "A model cannot be reshaped after it has been compiled",
        "modelId=" & $int(id)
      )
  guardedOperation(rt, "reshapeModel"):
    rt.backend.reshapeModel(entry.handle, inputs)

proc compileModel*(rt: Runtime, id: ModelId,
                   options: CompileOptions): CompiledModelId =
  ## 针对指定设备编译模型。
  rt.requireReady("compileModel")
  let entry = rt.lookupModel(id)

  rt.emit(rekCompiling, "Compiling model", %*{
    "modelId": int(id),
    "device": options.device
  })

  let started = getMonoTime()
  var handle: BackendCompiledModel
  guardedOperation(rt, "compileModel"):
    handle = rt.backend.compileModel(entry.handle, options)
  let elapsedMs = (getMonoTime() - started).inMilliseconds

  let compiledId = rt.nextHandleId()
  rt.compiled[compiledId] = CompiledEntry(
    handle: handle,
    modelId: int(id),
    device: options.device,
    requestedDevice: options.device,
    deviceType: "",
    deviceFullName: ""
  )

  rt.emit(rekCompiling, "Model compiled", %*{
    "modelId": int(id),
    "compiledModelId": compiledId,
    "device": options.device,
    "elapsedMs": elapsedMs
  })
  result = CompiledModelId(compiledId)

proc compileModelForDevice*(rt: Runtime, id: ModelId,
                            requested: string = DeviceRequestAuto,
                            enableProfiling: bool = false,
                            properties: Table[string, string] =
                              initTable[string, string]()):
    tuple[compiled: CompiledModelId, selection: DeviceSelection] =
  ## 按**语义**设备请求编译模型(§11 / §12 的正式入口)。
  ##
  ## 与 `compileModel` 的分工:
  ##
  ## ```text
  ## compileModel           device 必须是 Backend rawName(如 GPU.0)
  ## compileModelForDevice  device 是语义值(AUTO / CPU / GPU / NPU)
  ## ```
  ##
  ## 两个入口都保留:低层入口是 Backend 测试与精确控制所需,语义入口是
  ## 配置与 API 所需。返回值同时给出选择结果,使调用方能如实上报
  ## 「实际跑在哪个设备上」—— 只返回句柄的话这个信息就丢了。
  let selection = rt.resolveDevice(requested)

  var options = initCompileOptions(selection.device.rawName, enableProfiling)
  for key, value in properties:
    options.properties[key] = value

  let compiledId = rt.compileModel(id, options)

  # 补齐语义信息:compileModel 只知道 rawName。
  let key = int(compiledId)
  var entry = rt.compiled[key]
  entry.requestedDevice = selection.requested
  entry.deviceType = $selection.device.deviceType
  entry.deviceFullName = selection.device.fullName
  rt.compiled[key] = entry

  # 刻意复用 rekCompiling 而不新增事件种类:§29 的 10 种事件是稳定契约
  # (tests/core/tevents.nim 断言总数为 10),而设备解析本身就是编译流程的
  # 一部分,不是独立的生命周期阶段。
  rt.emit(rekCompiling, "Device selected for compilation", %*{
    "compiledModelId": key,
    "requested": selection.requested,
    "device": selection.device.rawName,
    "deviceType": $selection.device.deviceType,
    "fullName": selection.device.fullName,
    "usedAuto": selection.usedAuto,
    "reason": selection.reason
  })

  result = (compiled: compiledId, selection: selection)

proc compiledModelDevice*(rt: Runtime, id: CompiledModelId): string =
  ## 该已编译模型实际绑定的 Backend rawName。
  rt.lookupCompiled(id).device

proc compiledModelRequestedDevice*(rt: Runtime, id: CompiledModelId): string =
  ## 编译时调用方请求的设备值。
  ##
  ## 与 `compiledModelDevice` 分开是必需的:「请求 GPU」和「实际跑在 GPU.0」
  ## 这两件事都要能查到,只保留一个就无法如实上报。
  rt.lookupCompiled(id).requestedDevice

proc compiledModelDeviceType*(rt: Runtime, id: CompiledModelId): string =
  ## 解析出的 DeviceType。经 rawName 低层入口编译时为空字符串。
  rt.lookupCompiled(id).deviceType

proc compiledModelDeviceFullName*(rt: Runtime, id: CompiledModelId): string =
  ## Backend 报告的设备全名。取不到时为空,不用 rawName 冒充(§27)。
  rt.lookupCompiled(id).deviceFullName

proc exportCompiledModel*(rt: Runtime, id: CompiledModelId, path: string) =
  ## 将已编译模型导出为 blob(供 Compiled Cache 使用)。
  rt.requireReady("exportCompiledModel")
  let entry = rt.lookupCompiled(id)
  guardedOperation(rt, "exportCompiledModel"):
    rt.backend.exportCompiledModel(entry.handle, path)

proc importCompiledModel*(rt: Runtime, path: string,
                          options: CompileOptions): CompiledModelId =
  ## 从 blob 导入已编译模型。
  ##
  ## 导入得到的已编译模型没有来源 Model,因此不会被任何 `unloadModel` 级联释放。
  rt.requireReady("importCompiledModel")

  var handle: BackendCompiledModel
  guardedOperation(rt, "importCompiledModel"):
    handle = rt.backend.importCompiledModel(path, options)

  let compiledId = rt.nextHandleId()
  rt.compiled[compiledId] = CompiledEntry(
    handle: handle,
    modelId: 0,      # 无来源模型
    device: options.device,
    requestedDevice: options.device,
    deviceType: "",
    deviceFullName: ""
  )

  rt.emit(rekCacheHit, "Compiled model imported from blob", %*{
    "compiledModelId": compiledId,
    "device": options.device,
    "path": path
  })
  result = CompiledModelId(compiledId)

# ---------------------------------------------------------------------------
# 推理
# ---------------------------------------------------------------------------

proc createInferRequest*(rt: Runtime, id: CompiledModelId): InferRequestId =
  ## 创建推理请求。
  rt.requireReady("createInferRequest")
  let entry = rt.lookupCompiled(id)

  var handle: BackendInferRequest
  guardedOperation(rt, "createInferRequest"):
    handle = rt.backend.createInferRequest(entry.handle)

  let requestId = rt.nextHandleId()
  rt.requests[requestId] = RequestEntry(handle: handle, compiledId: int(id))
  result = InferRequestId(requestId)

proc setInput*(rt: Runtime, id: InferRequestId, index: int, t: Tensor) =
  ## 按索引绑定输入张量。
  rt.requireReady("setInput")
  if t == nil:
    raiseIsvikError(
      ecInvalidParameter,
      "Input tensor must not be nil",
      "inferRequestId=" & $int(id) & " index=" & $index
    )
  let entry = rt.lookupRequest(id)
  guardedOperation(rt, "setInput"):
    rt.backend.setInputTensor(entry.handle, index, t)

proc getOutput*(rt: Runtime, id: InferRequestId, index: int): Tensor =
  ## 按索引读取输出张量。
  rt.requireReady("getOutput")
  let entry = rt.lookupRequest(id)
  guardedOperation(rt, "getOutput"):
    result = rt.backend.getOutputTensor(entry.handle, index)

proc setInputByName*(rt: Runtime, id: InferRequestId, name: string,
                     t: Tensor) =
  ## 按**端口名**绑定输入张量。
  ##
  ## KV-cache 必须走这个入口:端口索引是模型图的实现细节,按索引绑定
  ## 等于把一个可能变化的顺序写死,而错装 key/value 只会表现为
  ## 「推理成功但输出是错的」。详见 `core/backend.nim` 的说明。
  rt.requireReady("setInputByName")
  if t == nil:
    raiseIsvikError(
      ecInvalidParameter,
      "Input tensor must not be nil",
      "inferRequestId=" & $int(id) & " name=" & name
    )
  if name.len == 0:
    raiseIsvikError(
      ecInvalidParameter,
      "Input port name must not be empty",
      "inferRequestId=" & $int(id)
    )
  let entry = rt.lookupRequest(id)
  guardedOperation(rt, "setInputByName"):
    rt.backend.setInputTensorByName(entry.handle, name, t)

proc setStringInputByName*(rt: Runtime, id: InferRequestId, name: string,
                          texts: seq[string]) =
  ## 按端口名绑定 **STRING** 输入。
  ##
  ## 只有 tokenizer IR 需要它 —— 那种模型的唯一输入端口元素类型是 STRING,
  ## 而 Isvik 的 `Tensor` 只表示数值类型,装不下。
  ##
  ## 允许 `texts` 为空序列:那对应「批大小 0」,是模型该自己拒绝的输入,
  ## 不是 Isvik 该猜的。
  rt.requireReady("setStringInputByName")
  if name.len == 0:
    raiseIsvikError(
      ecInvalidParameter,
      "Input port name must not be empty",
      "inferRequestId=" & $int(id)
    )
  let entry = rt.lookupRequest(id)
  guardedOperation(rt, "setStringInputByName"):
    rt.backend.setStringInputByName(entry.handle, name, texts)

proc registerExtension*(rt: Runtime, libraryPath: string) =
  ## 注册自定义算子扩展库。
  ##
  ## 必须在 `loadModel` **之前**调用,否则 tokenizer IR 会以
  ## 「unsupported opset: extension」失败,而那个错误不会提示缺扩展。
  rt.requireReady("registerExtension")
  if libraryPath.len == 0:
    raiseIsvikError(
      ecInvalidParameter,
      "Extension library path must not be empty",
      "operation=registerExtension"
    )
  guardedOperation(rt, "registerExtension"):
    rt.backend.registerExtension(libraryPath)

proc getOutputByName*(rt: Runtime, id: InferRequestId, name: string): Tensor =
  ## 按端口名读取输出张量。
  rt.requireReady("getOutputByName")
  let entry = rt.lookupRequest(id)
  guardedOperation(rt, "getOutputByName"):
    result = rt.backend.getOutputTensorByName(entry.handle, name)

proc inputPortNames*(rt: Runtime, id: CompiledModelId): seq[string] =
  ## 已编译模型的输入端口名。
  ##
  ## 推理编排靠它**发现**模型有没有 KV-cache,而不是假设有。
  rt.requireReady("inputPortNames")
  let entry = rt.lookupCompiled(id)
  guardedOperation(rt, "inputPortNames"):
    result = rt.backend.inputPortNames(entry.handle)

proc outputPortNames*(rt: Runtime, id: CompiledModelId): seq[string] =
  ## 已编译模型的输出端口名。
  rt.requireReady("outputPortNames")
  let entry = rt.lookupCompiled(id)
  guardedOperation(rt, "outputPortNames"):
    result = rt.backend.outputPortNames(entry.handle)

proc infer*(rt: Runtime, id: InferRequestId) =
  ## 同步执行一次推理,并发布起止事件。
  rt.requireReady("infer")
  let entry = rt.lookupRequest(id)

  rt.emit(rekInferenceStarted, "Inference started", %*{
    "inferRequestId": int(id)
  })

  let started = getMonoTime()
  guardedOperation(rt, "infer"):
    rt.backend.infer(entry.handle)
  let elapsedMs = (getMonoTime() - started).inMilliseconds

  rt.emit(rekInferenceFinished, "Inference finished", %*{
    "inferRequestId": int(id),
    "elapsedMs": elapsedMs
  })
