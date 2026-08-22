## MockBackend —— 用于测试的完整 Backend 实现
##
## ## 为什么它不是「凑数的假实现」
##
## Isvik 的 CI 与开发环境不一定装有 OpenVINO Runtime,更不一定有 Intel NPU。
## 如果 Core 的生命周期测试必须依赖真实 Backend,那么:
##
## - 没装 OpenVINO 的机器上一个 Core 测试都跑不了
## - 「设备不可用」「编译失败」「blob 损坏」这些错误路径几乎无法稳定复现
## - NPU 相关逻辑只能在有 NPU 的机器上测,等于大部分时候不测
##
## MockBackend 让 Core 的全部生命周期与错误路径都能确定性地验证,
## 这是让 CI 有意义的唯一做法。
##
## ## 它提供的测试能力
##
## | 能力 | 用途 |
## | --- | --- |
## | 可配置设备拓扑 | 模拟「有 NPU」「无 NPU」「只有 CPU」等场景(Task 10 的 AUTO 策略) |
## | 失败注入 | 让任意操作按需失败,验证错误码与错误传播 |
## | 调用序列记录 | 断言 §8 要求的生命周期顺序真的被遵守 |
## | 重复释放计数 | 验证 Runtime 没有 double free,且重复释放不崩溃 |
##
## ## 边界
##
## 本模块**不**执行任何真实推理,也不加载真实模型文件。
## 它不得被编译进产品的默认执行路径 —— 它属于 tests 与 examples 的依赖。

import std/[tables, sets, strutils, os]

import isvik/core/errors
import isvik/core/backend
import isvik/core/tensor

type
  MockFailure* = enum
    ## 可注入的失败点。
    mfInitialize
    mfDiscoverDevices
    mfLoadModel
    mfCompileModel
    mfCreateInferRequest
    mfSetInput
    mfGetOutput
    mfInfer
    mfExportCompiledModel
    mfImportCompiledModel
    mfRelease

  MockModel* = ref object of BackendModel
    path*: string
    released*: bool

  MockCompiledModel* = ref object of BackendCompiledModel
    device*: string
    profiling*: bool
    released*: bool
    fromBlob*: bool

  MockInferRequest* = ref object of BackendInferRequest
    inputs*: Table[int, Tensor]
    namedStringInputs*: Table[string, seq[string]]
      ## 按端口名绑定的 STRING 输入。与数值输入分开保存,因为 STRING
      ## 元素装不进 `Tensor`(没有扁平字节布局)。
    namedInputs*: Table[string, Tensor]
      ## 按端口名绑定的输入。与 `inputs` 分开,键空间不同。
    inferCount*: int
    released*: bool

  MockBackend* = ref object of Backend
    reportedDevices: seq[BackendDeviceInfo]
    initialized: bool
    releasedFlag: bool
    failures: set[MockFailure]
    callLog: seq[string]
    doubleReleases: int
    strictModelPaths: bool
    knownModelPaths: HashSet[string]
    knownBlobPaths: HashSet[string]
    plannedOutputs: seq[Tensor]
    plannedNamedOutputs: Table[string, Tensor]
    inputPortNamesValue: seq[string]
    outputPortNamesValue: seq[string]
    backendVersionText: string
    registeredExtensions: seq[string]

const
  MockBackendName* = "mock"
  MockBackendVersion* = "mock-0.1.0"

  VirtualBlobScheme* = "mock://"
    ## 虚拟路径前缀。以它开头的 blob 路径只在内部登记,不写文件系统。
    ##
    ## 存在的理由:生命周期与级联释放测试不关心文件内容,给它们造真文件
    ## 只是无谓的 IO 与清理负担。而 Compiled Cache 需要真文件,那种场景
    ## 传的是真实路径。

# ---------------------------------------------------------------------------
# 构造与测试配置
# ---------------------------------------------------------------------------

proc newMockDeviceInfo*(rawName: string, fullName: string = "",
                        properties: openArray[(string, string)] = []):
    BackendDeviceInfo =
  ## 构造一个模拟设备。
  ##
  ## fullName 默认留空,与真实 Backend 取不到完整设备名时的行为一致 ——
  ## 不用 rawName 冒充完整名称(§27 禁止伪造硬件信息)。
  ##
  ## `properties` 用于模拟 Backend 的附加属性(如 `DEVICE_ARCHITECTURE`),
  ## 让 Device Manager 的 vendor 判定能在没有真实 GPU 的机器上被测试。
  ## 默认为空 —— 真实 Backend 取不到属性时同样是空表。
  result = BackendDeviceInfo(
    rawName: rawName,
    fullName: fullName,
    properties: initTable[string, string]()
  )
  for (key, value) in properties:
    result.properties[key] = value

proc newMockBackend*(devices: seq[BackendDeviceInfo] = @[]): MockBackend =
  ## 创建 MockBackend。
  ##
  ## `devices` 为空时默认只报告一个 CPU —— 这是最接近「任何机器都有」的假设,
  ## 不默认提供 GPU / NPU,避免测试无意中依赖了不存在的硬件。
  new(result)
  result.reportedDevices =
    if devices.len > 0:
      devices
    else:
      @[newMockDeviceInfo("CPU", "Mock CPU Device")]
  result.initialized = false
  result.releasedFlag = false
  result.failures = {}
  result.callLog = @[]
  result.doubleReleases = 0
  result.strictModelPaths = false
  result.knownModelPaths = initHashSet[string]()
  result.knownBlobPaths = initHashSet[string]()
  result.plannedOutputs = @[]
  result.plannedNamedOutputs = initTable[string, Tensor]()
  result.inputPortNamesValue = @[]
  result.outputPortNamesValue = @[]
  result.backendVersionText = MockBackendVersion

proc injectFailure*(b: MockBackend, failure: MockFailure) =
  ## 让指定操作在下次调用时失败。
  b.failures.incl(failure)

proc clearFailure*(b: MockBackend, failure: MockFailure) =
  b.failures.excl(failure)

proc clearAllFailures*(b: MockBackend) =
  b.failures = {}

proc setDevices*(b: MockBackend, devices: seq[BackendDeviceInfo]) =
  ## 替换报告的设备列表,用于模拟不同硬件拓扑。
  b.reportedDevices = devices

proc setStrictModelPaths*(b: MockBackend, strict: bool) =
  ## 开启后,只有通过 `registerModelPath` 登记过的路径才能加载,
  ## 其余路径抛 MODEL_NOT_FOUND。用于测试模型缺失的错误路径。
  b.strictModelPaths = strict

proc registerModelPath*(b: MockBackend, path: string) =
  b.knownModelPaths.incl(path)

proc registerBlobPath*(b: MockBackend, path: string) =
  ## 登记一个「存在且有效」的 blob 路径,供 importCompiledModel 使用。
  b.knownBlobPaths.incl(path)

proc setPlannedOutputs*(b: MockBackend, outputs: seq[Tensor]) =
  ## 预设 getOutputTensor 按索引返回的张量。
  b.plannedOutputs = outputs

proc setVersionText*(b: MockBackend, version: string) =
  b.backendVersionText = version

proc callLog*(b: MockBackend): seq[string] =
  ## 按发生顺序记录的操作名,用于断言生命周期顺序。
  b.callLog

proc doubleReleaseCount*(b: MockBackend): int =
  ## 对同一资源重复调用释放的次数。
  ##
  ## Runtime 若正确管理句柄,这个值应当保持为 0。
  b.doubleReleases

proc isReleased*(b: MockBackend): bool = b.releasedFlag

proc clearCallLog*(b: MockBackend) =
  b.callLog = @[]

proc isVirtualBlobPath*(path: string): bool =
  ## 该路径是否为「刻意不落盘」的虚拟路径。
  ##
  ## `mock://...` 形式表示测试只关心句柄语义,不关心文件系统。真实文件系统
  ## 路径则会被当作真路径处理 —— Compiled Cache 之类的调用方需要真文件。
  path.startsWith(VirtualBlobScheme)

proc record(b: MockBackend, operation: string) =
  b.callLog.add(operation)

proc failIfInjected(b: MockBackend, failure: MockFailure,
                    code: IsvikErrorCode, message: string) =
  ## 若该失败点被注入,则抛出指定错误。
  if failure in b.failures:
    raiseIsvikError(code, message, "injected=" & $failure)

# ---------------------------------------------------------------------------
# 元信息
# ---------------------------------------------------------------------------

method name*(b: MockBackend): string = MockBackendName

method version*(b: MockBackend): string = b.backendVersionText

# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------

method initialize*(b: MockBackend) =
  b.record("initialize")
  b.failIfInjected(mfInitialize, ecBackendNotAvailable,
                   "Mock backend failed to initialize")
  b.initialized = true
  b.releasedFlag = false

method isInitialized*(b: MockBackend): bool = b.initialized

method registerExtension*(b: MockBackend, libraryPath: string) =
  b.record("registerExtension")
  b.failIfInjected(mfInitialize, ecBackendNotAvailable,
                   "Mock backend failed to register the extension library")
  if libraryPath.len == 0:
    raiseIsvikError(
      ecInvalidParameter,
      "Extension library path must not be empty",
      "reason=empty-extension-path"
    )
  if libraryPath notin b.registeredExtensions:
    b.registeredExtensions.add(libraryPath)

proc extensions*(b: MockBackend): seq[string] =
  ## 已注册的扩展库路径。供测试断言编排层**确实**在读 tokenizer 前注册了扩展 ——
  ## 忘记注册的失败信息不会提到扩展,靠人看错误很难发现。
  b.registeredExtensions

method discoverDevices*(b: MockBackend): seq[BackendDeviceInfo] =
  b.record("discoverDevices")
  b.failIfInjected(mfDiscoverDevices, ecBackendNotAvailable,
                   "Mock backend failed to enumerate devices")
  result = b.reportedDevices

method release*(b: MockBackend) =
  b.record("release")
  if b.releasedFlag:
    inc b.doubleReleases
    return
  b.failIfInjected(mfRelease, ecServerError, "Mock backend failed to release")
  b.initialized = false
  b.releasedFlag = true

# ---------------------------------------------------------------------------
# 模型
# ---------------------------------------------------------------------------

method loadModel*(b: MockBackend, path: string): BackendModel =
  b.record("loadModel")
  b.failIfInjected(mfLoadModel, ecModelInvalid, "Mock model failed to load")

  if b.strictModelPaths and path notin b.knownModelPaths:
    raiseIsvikError(
      ecModelNotFound,
      "Model file was not found",
      "path=" & path
    )

  result = MockModel(path: path, released: false)

method releaseModel*(b: MockBackend, model: BackendModel) =
  b.record("releaseModel")
  let m = MockModel(model)
  if m.released:
    inc b.doubleReleases
    return
  m.released = true

method compileModel*(b: MockBackend, model: BackendModel,
                     options: CompileOptions): BackendCompiledModel =
  b.record("compileModel")
  b.failIfInjected(mfCompileModel, ecCompilationFailed,
                   "Mock model failed to compile")

  let m = MockModel(model)
  if m.released:
    # 这是真实存在的风险:对已释放的模型编译。真实 Backend 上这会是
    # use-after-free,Mock 里把它变成明确的错误,使测试能覆盖该路径。
    raiseIsvikError(
      ecCompilationFailed,
      "Cannot compile a model that has already been released",
      "path=" & m.path
    )

  var known = false
  for device in b.reportedDevices:
    if device.rawName == options.device:
      known = true
      break
  if not known:
    # Backend 只报告「这个设备我没有」。把它翻译成 NPU_NOT_AVAILABLE 之类
    # 带 Isvik 语义的错误码是 Device Manager 的职责(§11:设备语义集中管理),
    # Backend 不理解 Isvik 的设备分类。
    var available: seq[string] = @[]
    for device in b.reportedDevices:
      available.add(device.rawName)
    raiseIsvikError(
      ecDeviceNotAvailable,
      "Requested device is not available in this backend",
      "requested=" & options.device & " available=" & available.join(",")
    )

  result = MockCompiledModel(
    device: options.device,
    profiling: options.enableProfiling,
    released: false,
    fromBlob: false
  )

method releaseCompiledModel*(b: MockBackend,
                             compiled: BackendCompiledModel) =
  b.record("releaseCompiledModel")
  let cm = MockCompiledModel(compiled)
  if cm.released:
    inc b.doubleReleases
    return
  cm.released = true

method exportCompiledModel*(b: MockBackend, compiled: BackendCompiledModel,
                            path: string) =
  b.record("exportCompiledModel")
  b.failIfInjected(mfExportCompiledModel, ecServerError,
                   "Mock backend failed to export compiled model")
  let cm = MockCompiledModel(compiled)
  if cm.released:
    raiseIsvikError(
      ecServerError,
      "Cannot export a compiled model that has already been released",
      "path=" & path
    )

  # 真实文件系统路径要**真的写出一个文件**,不只是登记。
  #
  # `core/backend.nim` 的契约是「导出为 blob」,调用方(例如 Compiled Cache)
  # 理应能在之后看到这个文件。早先的实现只把路径记进 knownBlobPaths,
  # 于是缓存的 commit 步骤找不到 blob —— 这个缺陷只在接入缓存时才暴露。
  # Mock 不产出文件就会掩盖这一类集成问题,那正是 Mock 最该避免的失败方式。
  #
  # `mock://` 前缀的路径是**有意的虚拟路径**,只登记不落盘 —— 生命周期与
  # 级联释放这类测试不关心文件系统,给它们造真文件只是无谓的 IO 与清理负担。
  if not isVirtualBlobPath(path):
    # 内容是确定性的假数据,足以让完整性校验有意义(非空、可校验、可篡改)。
    let content = "mock-compiled-blob\ndevice=" & cm.device &
      "\nprofiling=" & $cm.profiling & "\n"
    try:
      createDir(path.parentDir)
      writeFile(path, content)
    except CatchableError as e:
      raiseIsvikError(
        ecServerError,
        "Mock backend failed to write the blob file",
        "path=" & path & " reason=" & e.msg
      )

  b.knownBlobPaths.incl(path)

method importCompiledModel*(b: MockBackend, path: string,
                            options: CompileOptions): BackendCompiledModel =
  b.record("importCompiledModel")
  b.failIfInjected(mfImportCompiledModel, ecCacheCorrupted,
                   "Mock blob is corrupted")

  # 真实路径要求「登记过 **且** 文件还在」:只查登记表会让「文件被删了」
  # 静默通过,而真实 Backend 一定失败。虚拟路径只查登记表。
  let missing =
    if isVirtualBlobPath(path): path notin b.knownBlobPaths
    else: path notin b.knownBlobPaths or not fileExists(path)
  if missing:
    raiseIsvikError(
      ecCacheInvalid,
      "Compiled model blob was not found or is not valid",
      "path=" & path
    )

  result = MockCompiledModel(
    device: options.device,
    profiling: options.enableProfiling,
    released: false,
    fromBlob: true
  )

# ---------------------------------------------------------------------------
# 推理
# ---------------------------------------------------------------------------

method createInferRequest*(b: MockBackend,
                           compiled: BackendCompiledModel): BackendInferRequest =
  b.record("createInferRequest")
  b.failIfInjected(mfCreateInferRequest, ecServerError,
                   "Mock backend failed to create infer request")

  let cm = MockCompiledModel(compiled)
  if cm.released:
    raiseIsvikError(
      ecServerError,
      "Cannot create an infer request from a released compiled model",
      "device=" & cm.device
    )

  result = MockInferRequest(
    inputs: initTable[int, Tensor](),
    namedStringInputs: initTable[string, seq[string]](),
    namedInputs: initTable[string, Tensor](),
    inferCount: 0,
    released: false
  )

method releaseInferRequest*(b: MockBackend, request: BackendInferRequest) =
  b.record("releaseInferRequest")
  let r = MockInferRequest(request)
  if r.released:
    inc b.doubleReleases
    return
  r.released = true

method setInputTensor*(b: MockBackend, request: BackendInferRequest,
                       index: int, t: Tensor) =
  b.record("setInputTensor")
  b.failIfInjected(mfSetInput, ecInvalidParameter,
                   "Mock backend rejected the input tensor")

  if index < 0:
    raiseIsvikError(
      ecInvalidParameter,
      "Input tensor index must not be negative",
      "index=" & $index
    )

  let r = MockInferRequest(request)
  if r.released:
    raiseIsvikError(
      ecInferenceFailed,
      "Cannot bind an input to a released infer request",
      "index=" & $index
    )
  r.inputs[index] = t

method infer*(b: MockBackend, request: BackendInferRequest) =
  b.record("infer")
  b.failIfInjected(mfInfer, ecInferenceFailed, "Mock inference failed")

  let r = MockInferRequest(request)
  if r.released:
    raiseIsvikError(
      ecInferenceFailed,
      "Cannot run inference on a released infer request",
      "inferCount=" & $r.inferCount
    )
  inc r.inferCount

method getOutputTensor*(b: MockBackend, request: BackendInferRequest,
                        index: int): Tensor =
  b.record("getOutputTensor")
  b.failIfInjected(mfGetOutput, ecInferenceFailed,
                   "Mock backend failed to produce an output tensor")

  if index < 0:
    raiseIsvikError(
      ecInvalidParameter,
      "Output tensor index must not be negative",
      "index=" & $index
    )

  let r = MockInferRequest(request)
  if r.released:
    raiseIsvikError(
      ecInferenceFailed,
      "Cannot read output from a released infer request",
      "index=" & $index
    )
  if r.inferCount == 0:
    # 未执行推理就取输出是调用顺序错误,真实 Backend 上会得到未定义内容。
    raiseIsvikError(
      ecInferenceFailed,
      "Cannot read output before inference has been executed",
      "index=" & $index
    )

  if b.plannedOutputs.len > 0:
    if index >= b.plannedOutputs.len:
      raiseIsvikError(
        ecInvalidParameter,
        "Output tensor index is out of range",
        "index=" & $index & " outputCount=" & $b.plannedOutputs.len
      )
    let planned = b.plannedOutputs[index]
    # 返回副本:调用方对输出的修改不应影响 Mock 的预设值,
    # 否则多次推理之间会相互污染。
    result = newTensor(planned.elementType, planned.shape)
    if planned.byteLen > 0:
      copyMem(result.dataPtr, planned.dataPtr, planned.byteLen)
    return

  # 默认输出:形状 [1] 的 F32,值为该请求已执行的推理次数。
  # 这样测试可以确认 infer 真的被调用过、以及被调用了几次。
  result = newTensor(etF32, [1], [float32(r.inferCount)])

# ---------------------------------------------------------------------------
# 按端口名绑定与端口枚举
# ---------------------------------------------------------------------------
#
# Mock 侧的端口拓扑是**可配置的**,因为 KV-cache 编排的正确性必须能在没有
# OpenVINO、没有 1.3 GB 语言模型的机器上验证。`setPorts` 让测试声明一个
# 模型「有哪些端口」,随后编排代码走的就是与真实 Backend 相同的发现路径。

proc setPorts*(b: MockBackend, inputs, outputs: openArray[string]) =
  ## 声明该 Backend 报告的端口名。
  ##
  ## 未设置时端口列表为空 —— 与真实 Backend 上「模型没有命名端口」一致,
  ## 不假装有一套默认端口。
  b.inputPortNamesValue = @inputs
  b.outputPortNamesValue = @outputs

proc namedInputs*(b: MockBackend, request: BackendInferRequest):
    Table[string, Tensor] =
  ## 已按名绑定的输入。供测试断言「编排到底绑了什么」。
  MockInferRequest(request).namedInputs

method setInputTensorByName*(b: MockBackend, request: BackendInferRequest,
                             name: string, t: Tensor) =
  b.record("setInputTensorByName")
  b.failIfInjected(mfSetInput, ecInvalidParameter,
                   "Mock backend rejected the named input tensor")

  if name.len == 0:
    raiseIsvikError(
      ecInvalidParameter,
      "Port name must not be empty",
      "reason=empty-port-name"
    )

  let r = MockInferRequest(request)
  if r.released:
    raiseIsvikError(
      ecInferenceFailed,
      "Cannot bind an input to a released infer request",
      "name=" & name
    )

  # 端口已声明时校验名字存在。真实 Backend 会因未知端口失败,Mock 不校验
  # 就会让「绑错端口名」的测试假通过 —— 而那正是按名绑定要防的错误。
  if b.inputPortNamesValue.len > 0 and name notin b.inputPortNamesValue:
    raiseIsvikError(
      ecInvalidParameter,
      "Unknown input port name",
      "name=" & name & " known=" & b.inputPortNamesValue.join(",")
    )

  r.namedInputs[name] = t

proc namedStringInputs*(b: MockBackend, request: BackendInferRequest):
    Table[string, seq[string]] =
  ## 已按名绑定的 STRING 输入。供测试断言编排层送进 tokenizer 的到底是什么。
  MockInferRequest(request).namedStringInputs

method setStringInputByName*(b: MockBackend, request: BackendInferRequest,
                            name: string, texts: seq[string]) =
  b.record("setStringInputByName")
  b.failIfInjected(mfSetInput, ecInvalidParameter,
                   "Mock backend rejected the named string input")

  if name.len == 0:
    raiseIsvikError(
      ecInvalidParameter,
      "Port name must not be empty",
      "reason=empty-port-name"
    )

  let r = MockInferRequest(request)
  if r.released:
    raiseIsvikError(
      ecInferenceFailed,
      "Cannot bind an input to a released infer request",
      "name=" & name
    )

  if b.inputPortNamesValue.len > 0 and name notin b.inputPortNamesValue:
    raiseIsvikError(
      ecInvalidParameter,
      "Unknown input port name",
      "name=" & name & " known=" & b.inputPortNamesValue.join(",")
    )

  r.namedStringInputs[name] = texts

method getOutputTensorByName*(b: MockBackend, request: BackendInferRequest,
                              name: string): Tensor =
  b.record("getOutputTensorByName")
  b.failIfInjected(mfGetOutput, ecInferenceFailed,
                   "Mock backend failed to produce a named output tensor")

  let r = MockInferRequest(request)
  if r.released:
    raiseIsvikError(
      ecInferenceFailed,
      "Cannot read output from a released infer request",
      "name=" & name
    )
  if r.inferCount == 0:
    raiseIsvikError(
      ecInferenceFailed,
      "Cannot read output before inference has been executed",
      "name=" & name
    )

  if b.outputPortNamesValue.len > 0 and name notin b.outputPortNamesValue:
    raiseIsvikError(
      ecInvalidParameter,
      "Unknown output port name",
      "name=" & name & " known=" & b.outputPortNamesValue.join(",")
    )

  # 预设的按名输出优先;没有预设时回落到与索引版一致的默认输出,
  # 使「infer 被调用了几次」同样可断言。
  if b.plannedNamedOutputs.hasKey(name):
    let planned = b.plannedNamedOutputs[name]
    result = newTensor(planned.elementType, planned.shape)
    if planned.byteLen > 0:
      copyMem(result.dataPtr, planned.dataPtr, planned.byteLen)
    return

  result = newTensor(etF32, [1], [float32(r.inferCount)])

proc setPlannedNamedOutput*(b: MockBackend, name: string, t: Tensor) =
  ## 预设某个输出端口的返回张量。
  ##
  ## KV-cache 测试需要它:编排会把 `present.N.key` 读出来再喂回
  ## `past_key_values.N.key`,若输出总是默认的 `[1]` F32,形状就串不起来。
  b.plannedNamedOutputs[name] = t

method inputPortNames*(b: MockBackend,
                       compiled: BackendCompiledModel): seq[string] =
  b.record("inputPortNames")
  b.inputPortNamesValue

method outputPortNames*(b: MockBackend,
                        compiled: BackendCompiledModel): seq[string] =
  b.record("outputPortNames")
  b.outputPortNamesValue
