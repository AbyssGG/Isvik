## OpenVINO Backend
##
## 对应 Master Prompt §9(Backend Implementation)、§0.5.2(建立在 Resonance
## 之上,不重复封装 OpenVINO)、§69(资源所有权)。
##
## ---
##
## ## 位置与唯一性
##
## ```text
## Isvik Core
##     ↓
## Backend Abstraction        core/backend.nim
##     ↓
## OpenVINO Backend           ← 本模块
##     ↓
## Resonance                  Nim ↔ OpenVINO C API
## ```
##
## **`src/isvik/backends/openvino/` 是整个仓库里唯一允许 import resonance 的
## 位置**,由 `tests/architecture/tarchitecture.nim` 机械强制。Isvik 不自己另写
## 一套 FFI —— 缺的能力以上游改动补进 Resonance(§0.5.2)。
##
## ---
##
## ## 关键设计一:输入张量的生命周期
##
## Resonance 的 `newTensor` 走 `ov_tensor_create_from_host_ptr`,也就是说
## **OpenVINO 只持有指针,不拥有数据**。而 Isvik 的 `Tensor` 把数据放在自己的
## `seq[byte]` 里。两者相接处有一个必须显式处理的悬空风险:
##
## ```text
## Isvik Tensor (拥有 seq[byte])
##      │ dataPtr() 出借裸指针
##      ▼
## Resonance Tensor (host-backed 视图)
##      │ ov_infer_request_set_input_tensor_by_index
##      ▼
## OpenVINO 内部只记住那个指针
## ```
##
## 若 Isvik Tensor 被 GC 回收,OpenVINO 手里的指针就悬空;若 Resonance Tensor
## 被 GC 回收,它的 `=destroy` 会 `ov_tensor_free`,OpenVINO 内部的 tensor 对象
## 随之失效。**两者都必须被 InferRequest 句柄持有引用**,这就是
## `inputTensors` 与 `nativeInputs` 两张表存在的唯一理由 —— 它们不是缓存,
## 是防止 GC 回收的锚。
##
## 这类错误不会在 `setInputTensor` 处报错,只会在后续 `infer` 时读到垃圾数据
## 或崩溃,且现场与起因相距很远。
##
## ---
##
## ## 关键设计二:输出张量必须拷贝
##
## `core/backend.nim` 的契约要求 `getOutputTensor` 返回「Isvik 自己拥有数据的
## Tensor」。这不是洁癖:OpenVINO 输出张量的数据**只在下一次 infer 之前有效**,
## 直接把它包一层返回,调用方拿到的引用会在下一轮推理时被悄悄改写。
##
## ---
##
## ## 关键设计三:释放是显式的,不靠析构器
##
## §69 要求显式释放。Resonance 原本只有 `=destroy`,已在上游补了 `close()`。
## 理由:编译后的模型持有设备端内存,NPU 上这块内存很紧张,等 GC 决定时机
## 会让另一个本该成功的编译失败。
##
## 所有 `releaseXxx` 都必须可重复调用 —— 句柄自带 `released` 标志,
## 且 Resonance 的 `close()` 本身幂等。

import std/tables
import std/os

import isvik/core/errors
import isvik/core/tensor
import isvik/core/backend

import isvik/backends/openvino/element_type
import isvik/backends/openvino/error_mapping
import isvik/backends/openvino/ov_handles

# `Tensor` 与 `newTensor` 刻意从 Resonance 排除:Isvik 的 core/tensor.nim 与
# Resonance 的 tensor.nim 文件名相同,两个 `Tensor` 无法用模块名区分。
# 排除后这两个名字唯一指向 Isvik 的版本,Resonance 的那个通过
# ov_handles.OvTensorHandle / newOvTensor 使用。详见 ov_handles.nim。
import resonance except Tensor, newTensor

const
  OpenVinoBackendName* = "openvino"
    ## Backend 的稳定标识,出现在日志与 API 响应中。

  UnknownVersionText* = "unknown"
    ## 取不到真实 OpenVINO 版本时使用的标记。
    ##
    ## §13 / §66:不得编造版本号。返回 "unknown" 让上层能如实显示,
    ## 而不是给出一个看起来精确却是假的字符串。

type
  OvBackendModel* = ref object of BackendModel
    ## 已读取但未编译的模型。
    native*: Model
    path*: string
    released*: bool

  OvBackendCompiledModel* = ref object of BackendCompiledModel
    ## 已针对某设备编译完成的模型。
    native*: CompiledModel
    device*: string
    profilingEnabled*: bool
    fromBlob*: bool
      ## 是否来自 blob 导入而非现场编译。
      ##
      ## 需要记录是因为 NPU 驱动不允许在 import 得到的模型上启用
      ## PERF_COUNT(见 DEVLOG 第六节 6.1 第 1 条)。Task 18 的 Benchmark
      ## 必须能区分这两种来源,否则会把「驱动拒绝」误报成「没有数据」。
    released*: bool

  OvBackendInferRequest* = ref object of BackendInferRequest
    ## 推理请求。
    native*: InferRequest
    inputTensors*: Table[int, Tensor]
      ## 已绑定的 Isvik 输入张量。**持有引用以防 GC 回收其数据缓冲** ——
      ## OpenVINO 只记住了裸指针。见模块顶部「关键设计一」。
    nativeInputs*: Table[int, OvTensorHandle]
      ## 对应的 Resonance 张量包装。同样必须持有引用:
      ## 它被回收时 `=destroy` 会 `ov_tensor_free`。
    namedInputTensors*: Table[string, Tensor]
      ## 按端口名绑定的 Isvik 输入张量。与 `inputTensors` 分开是因为键空间
      ## 不同(名字 vs 索引),混用会让「先按名再按索引绑同一端口」的行为
      ## 变得不可预测。防 GC 的作用与索引版完全相同。
    namedNativeInputs*: Table[string, OvTensorHandle]
      ## 按端口名绑定的 Resonance 张量包装。
    released*: bool

  OpenVinoBackend* = ref object of Backend
    ## OpenVINO Backend 实例。
    core: Core
    initialized: bool
    versionText: string

proc newOpenVinoBackend*(): OpenVinoBackend =
  ## 创建 Backend 实例。**不触碰 OpenVINO** —— 真正的加载发生在 `initialize`。
  ##
  ## 分成两步是必需的:构造函数里加载运行时,就意味着「创建对象」这个动作
  ## 可能因为环境问题失败。`isvik doctor` 需要先构造出 Backend 再询问它
  ## 「你可用吗」,如果构造本身就会炸,doctor 反而跑不起来。
  OpenVinoBackend(
    core: nil,
    initialized: false,
    versionText: ""
  )

# ---------------------------------------------------------------------------
# 内部辅助
# ---------------------------------------------------------------------------

proc requireInitialized(b: OpenVinoBackend, op: OvOperation) =
  ## 未初始化时明确报错,而不是让 nil core 走进 Resonance。
  if not b.initialized or b.core == nil:
    raiseIsvikError(
      ecBackendNotAvailable,
      defaultMessage(ecBackendNotAvailable),
      "operation=" & $op & " reason=backend-not-initialized"
    )

proc asModel(m: BackendModel, op: OvOperation): OvBackendModel =
  ## 向下转型并校验。
  ##
  ## 传进来别的 Backend 的句柄是调用方的错误,报 INVALID_PARAMETER 而不是
  ## 让 `nil` 解引用崩掉 —— 后者的现场完全看不出起因。
  if m == nil or not (m of OvBackendModel):
    raiseIsvikError(
      ecInvalidParameter,
      defaultMessage(ecInvalidParameter),
      "operation=" & $op & " reason=handle-is-not-an-openvino-model"
    )
  result = OvBackendModel(m)
  if result.released:
    raiseIsvikError(
      ecInvalidParameter,
      defaultMessage(ecInvalidParameter),
      "operation=" & $op & " reason=model-already-released path=" & result.path
    )

proc asCompiled(c: BackendCompiledModel,
                op: OvOperation): OvBackendCompiledModel =
  if c == nil or not (c of OvBackendCompiledModel):
    raiseIsvikError(
      ecInvalidParameter,
      defaultMessage(ecInvalidParameter),
      "operation=" & $op & " reason=handle-is-not-an-openvino-compiled-model"
    )
  result = OvBackendCompiledModel(c)
  if result.released:
    raiseIsvikError(
      ecInvalidParameter,
      defaultMessage(ecInvalidParameter),
      "operation=" & $op & " reason=compiled-model-already-released"
    )

proc asRequest(r: BackendInferRequest,
               op: OvOperation): OvBackendInferRequest =
  if r == nil or not (r of OvBackendInferRequest):
    raiseIsvikError(
      ecInvalidParameter,
      defaultMessage(ecInvalidParameter),
      "operation=" & $op & " reason=handle-is-not-an-openvino-infer-request"
    )
  result = OvBackendInferRequest(r)
  if result.released:
    raiseIsvikError(
      ecInvalidParameter,
      defaultMessage(ecInvalidParameter),
      "operation=" & $op & " reason=infer-request-already-released"
    )

proc toInt64Shape(shape: seq[int]): seq[int64] =
  ## Isvik 的 shape 用 int,Resonance 用 int64。
  result = newSeq[int64](shape.len)
  for i, dim in shape:
    result[i] = dim.int64

proc buildCompileProperties(options: CompileOptions): seq[(string, string)] =
  ## 把 CompileOptions 转成 Resonance 需要的属性对序列。
  ##
  ## `enableProfiling` 是 CompileOptions 里的显式字段,这里翻译成
  ## `PERF_COUNT=YES`。若调用方同时在 `properties` 里手写了 PERF_COUNT,
  ## 以显式字段为准并不重复添加 —— 传两个同名键给 OpenVINO 的行为未定义。
  result = @[]
  if options.enableProfiling:
    result.add((OvPropertyKeyEnableProfiling, "YES"))
  for key, value in options.properties:
    if options.enableProfiling and key == OvPropertyKeyEnableProfiling:
      continue
    result.add((key, value))

# ---------------------------------------------------------------------------
# 运行时可用性探测
# ---------------------------------------------------------------------------
#
# 这两个薄封装存在的理由是**架构边界**,不是便利:
# `tests/architecture/tarchitecture.nim` 断言整个 src 下只有
# `backends/openvino/` 可以 import resonance。`backends/factory.nim` 需要
# 回答「运行时能否加载」,但它不该为此把 resonance 拉进自己的 import 列表 ——
# 那会让「唯一接触点」这个不变量失效。于是由本模块转发。

proc openVinoRuntimeAvailable*(): bool =
  ## OpenVINO Runtime 能否加载。纯探测,可重复调用,不抛异常、不退出进程。
  ##
  ## 这是 `isvik doctor` 能在缺少 OpenVINO 的机器上运行的前提。
  tryLoadOpenVino()

proc openVinoRuntimeLoadError*(): string =
  ## 加载失败的原因。可加载时返回空字符串。
  openVinoLoadError()

# ---------------------------------------------------------------------------
# 元信息
# ---------------------------------------------------------------------------

method name*(b: OpenVinoBackend): string = OpenVinoBackendName

method version*(b: OpenVinoBackend): string =
  ## 真实的 OpenVINO Runtime 版本。
  ##
  ## 结果缓存:版本在进程生命周期内不会变,而这个方法可能被日志与 API
  ## 反复调用,每次都跨 FFI 查一遍没有意义。
  ##
  ## 取不到时返回 `UnknownVersionText`,**不编造**(§13、§66)。
  ## 注意这里不抛异常:上层常在「报告环境状态」的场景调用它,
  ## 那种场景下抛异常会让整份报告都出不来。
  if b.versionText.len > 0:
    return b.versionText
  try:
    let v = getOpenVinoVersion()
    b.versionText =
      if v.buildNumber.len > 0: v.buildNumber
      else: UnknownVersionText
  except CatchableError:
    b.versionText = UnknownVersionText
  result = b.versionText

# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------

method initialize*(b: OpenVinoBackend) =
  ## 创建 OpenVINO Core。
  ##
  ## 运行时不可用时抛 BACKEND_NOT_AVAILABLE 而不是崩溃(§13)——
  ## 这条路径是 `isvik doctor` 存在的前提。
  if b.initialized:
    return
  guardOv(ovOpInitialize, ""):
    b.core = newCore()
    b.initialized = true

method isInitialized*(b: OpenVinoBackend): bool =
  b.initialized and b.core != nil

method registerExtension*(b: OpenVinoBackend, libraryPath: string) =
  ## 向本 Backend 的 Core 注册自定义算子扩展库。
  ##
  ## 注册挂在 Core 上,所以只对**本 Backend 实例**之后 loadModel 的模型生效。
  ## 重复注册同一个库是无害的,OpenVINO 会忽略。
  b.requireInitialized(ovOpRegisterExtension)
  if not fileExists(libraryPath):
    # 提前拦下来:OpenVINO 对「文件不存在」和「文件在但加载失败」返回
    # 同一个 GENERAL_ERROR,而这两种情况的处置完全不同。
    raiseIsvikError(
      ecBackendNotAvailable,
      defaultMessage(ecBackendNotAvailable),
      "operation=" & $ovOpRegisterExtension & " path=" & libraryPath &
        " reason=extension-library-not-found"
    )
  guardOv(ovOpRegisterExtension, "path=" & libraryPath):
    b.core.addExtension(libraryPath)

method discoverDevices*(b: OpenVinoBackend): seq[BackendDeviceInfo] =
  ## 枚举 OpenVINO 报告的设备。
  ##
  ## 只报告**真实存在**的设备(§13 禁止伪造)。`rawName` 原样保留 OpenVINO
  ## 的标识(`CPU` / `GPU.0` / `GPU.1` / `NPU`),把它解析成 Isvik 的
  ## DeviceType 是 Task 10 Device Manager 的职责,不在这里做。
  ##
  ## 实测提醒:本机 `GPU.1` 是 NVIDIA 独显。也就是说 `GPU.N` 不等于
  ## Intel GPU,vendor 判断必须由 Device Manager 依据 DEVICE_ARCHITECTURE
  ## 完成 —— 这也是这里刻意不做语义解析的原因之一。
  b.requireInitialized(ovOpDiscoverDevices)
  var devices: seq[string] = @[]
  guardOv(ovOpDiscoverDevices, ""):
    devices = b.core.getAvailableDevices()

  result = @[]
  for rawName in devices:
    var info = BackendDeviceInfo(
      rawName: rawName,
      fullName: "",
      properties: initTable[string, string]()
    )
    # 属性查询逐个设备容错:某个设备不报告某属性是正常情况,
    # 不应该让整份设备列表失败。tryGetProperty 取不到时返回回落值。
    info.fullName = b.core.tryGetProperty(
      rawName, OvPropertyKeyFullDeviceName, "")
    let arch = b.core.tryGetProperty(
      rawName, OvPropertyKeyDeviceArchitecture, "")
    if arch.len > 0:
      info.properties[OvPropertyKeyDeviceArchitecture] = arch
    let deviceType = b.core.tryGetProperty(
      rawName, OvPropertyKeyDeviceType, "")
    if deviceType.len > 0:
      info.properties[OvPropertyKeyDeviceType] = deviceType
    result.add(info)

method release*(b: OpenVinoBackend) =
  ## 释放 Core。可重复调用。
  if b.core != nil:
    b.core.close()
    b.core = nil
  b.initialized = false

# ---------------------------------------------------------------------------
# 模型
# ---------------------------------------------------------------------------

method loadModel*(b: OpenVinoBackend, path: string): BackendModel =
  ## 读取 IR / ONNX 模型。
  ##
  ## 刻意不在这里判断文件是否存在:OpenVINO 自己会区分「路径不存在」与
  ## 「存在但不是合法模型」,而 Isvik 侧先做一遍 fileExists 只会把两者
  ## 混成同一个错误。状态码到错误码的映射见 error_mapping.nim。
  b.requireInitialized(ovOpLoadModel)
  var native: Model
  guardOv(ovOpLoadModel, "path=" & path):
    native = b.core.readModel(path)
  result = OvBackendModel(native: native, path: path, released: false)

method releaseModel*(b: OpenVinoBackend, model: BackendModel) =
  ## 释放模型。可重复调用。
  ##
  ## 不走 asModel:那个函数会对已释放的句柄报错,而重复释放必须是允许的。
  if model == nil or not (model of OvBackendModel):
    return
  let m = OvBackendModel(model)
  if m.native != nil:
    m.native.close()
    m.native = nil
  m.released = true

method reshapeModel*(b: OpenVinoBackend, model: BackendModel,
                     inputs: openArray[backend.ModelInputShape]) =
  b.requireInitialized(ovOpCompileModel)
  let m = asModel(model, ovOpCompileModel)
  var nativeInputs: seq[resonance.ModelInputShape] = @[]
  for input in inputs:
    var dims: seq[PartialDimension] = @[]
    for dim in input.dims:
      dims.add(PartialDimension(
        minimum: dim.minimum.int64, maximum: dim.maximum.int64))
    nativeInputs.add(resonance.ModelInputShape(name: input.name, dims: dims))
  guardOv(ovOpCompileModel, "path=" & m.path & " operation=reshape"):
    m.native.reshape(nativeInputs)

method compileModel*(b: OpenVinoBackend, model: BackendModel,
                     options: CompileOptions): BackendCompiledModel =
  ## 针对指定设备编译模型。
  b.requireInitialized(ovOpCompileModel)
  let m = asModel(model, ovOpCompileModel)
  let props = buildCompileProperties(options)

  var native: CompiledModel
  let ctx = "path=" & m.path & " device=" & options.device &
    " properties=" & $props.len
  guardOv(ovOpCompileModel, ctx):
    native = b.core.compileModelWithProperties(m.native, options.device, props)

  result = OvBackendCompiledModel(
    native: native,
    device: options.device,
    profilingEnabled: options.enableProfiling,
    fromBlob: false,
    released: false
  )

method releaseCompiledModel*(b: OpenVinoBackend,
                             compiled: BackendCompiledModel) =
  ## 释放已编译模型。可重复调用。
  ##
  ## 这里的显式释放比别处更要紧:编译产物占设备端内存,GPU / NPU 上
  ## 迟迟不归还会让后续编译失败。
  if compiled == nil or not (compiled of OvBackendCompiledModel):
    return
  let cm = OvBackendCompiledModel(compiled)
  if cm.native != nil:
    cm.native.close()
    cm.native = nil
  cm.released = true

method exportCompiledModel*(b: OpenVinoBackend,
                            compiled: BackendCompiledModel, path: string) =
  ## 导出为 blob(§17 Compiled Cache)。
  b.requireInitialized(ovOpExportCompiledModel)
  let cm = asCompiled(compiled, ovOpExportCompiledModel)
  guardOv(ovOpExportCompiledModel, "path=" & path & " device=" & cm.device):
    cm.native.exportModelToFile(path)

method importCompiledModel*(b: OpenVinoBackend, path: string,
                            options: CompileOptions): BackendCompiledModel =
  ## 从 blob 导入已编译模型。
  ##
  ## **重要行为差异**:blob 不包含运行期属性,因此 `options.enableProfiling`
  ## 在这条路径上**不会**生效 —— 已实测本机 NPU 驱动会拒绝在 import 之后
  ## 设置 PERF_COUNT(返回 GENERAL_ERROR)。
  ##
  ## 这里的处理是:如实把 `profilingEnabled` 记为 `false` 并置
  ## `fromBlob = true`,让上层能区分「没开 profiling」与「开了但驱动拒绝」。
  ## 绝不能记成 true —— 那会让 Task 18 的 Benchmark 报告一份空数据却声称
  ## 采集成功,即伪造 Benchmark。
  b.requireInitialized(ovOpImportCompiledModel)
  var native: CompiledModel
  guardOv(ovOpImportCompiledModel, "path=" & path & " device=" & options.device):
    native = b.core.importModel(path, options.device)

  result = OvBackendCompiledModel(
    native: native,
    device: options.device,
    profilingEnabled: false,
    fromBlob: true,
    released: false
  )

# ---------------------------------------------------------------------------
# 推理
# ---------------------------------------------------------------------------

method createInferRequest*(b: OpenVinoBackend,
                           compiled: BackendCompiledModel): BackendInferRequest =
  b.requireInitialized(ovOpCreateInferRequest)
  let cm = asCompiled(compiled, ovOpCreateInferRequest)
  var native: InferRequest
  guardOv(ovOpCreateInferRequest, "device=" & cm.device):
    native = cm.native.createInferRequest()
  result = OvBackendInferRequest(
    native: native,
    inputTensors: initTable[int, Tensor](),
    nativeInputs: initTable[int, OvTensorHandle](),
    namedInputTensors: initTable[string, Tensor](),
    namedNativeInputs: initTable[string, OvTensorHandle](),
    released: false
  )

method releaseInferRequest*(b: OpenVinoBackend,
                            request: BackendInferRequest) =
  ## 释放推理请求。可重复调用。
  ##
  ## 释放顺序有讲究:先关 request,再放开对输入张量的引用。
  ## 反过来的话,OpenVINO 侧的 request 仍然活着且持有指向已可被回收内存的
  ## 指针,中间存在一个窗口。
  if request == nil or not (request of OvBackendInferRequest):
    return
  let r = OvBackendInferRequest(request)
  if r.native != nil:
    r.native.close()
    r.native = nil
  for _, native in r.nativeInputs:
    if native != nil:
      native.close()
  r.nativeInputs.clear()
  r.inputTensors.clear()
  # 按名绑定的那一套同样要清 —— 漏掉它会让每个 KV-cache 步骤泄漏几十个
  # ov_tensor 句柄,而自回归解码会跑成百上千步。
  for _, native in r.namedNativeInputs:
    if native != nil:
      native.close()
  r.namedNativeInputs.clear()
  r.namedInputTensors.clear()
  r.released = true

method setInputTensor*(b: OpenVinoBackend, request: BackendInferRequest,
                       index: int, t: Tensor) =
  ## 按索引绑定输入张量。
  ##
  ## 数据**零拷贝**:OpenVINO 直接使用 Isvik Tensor 的缓冲。
  ## 代价是必须由本句柄持有引用防止 GC —— 见模块顶部「关键设计一」。
  b.requireInitialized(ovOpSetInputTensor)
  let r = asRequest(request, ovOpSetInputTensor)

  if t == nil:
    raiseIsvikError(
      ecInvalidParameter,
      defaultMessage(ecInvalidParameter),
      "operation=" & $ovOpSetInputTensor & " index=" & $index &
        " reason=tensor-is-nil"
    )

  # 亚字节类型此处不可能出现:core/tensor.nim 的 newTensor 直接拒绝它们。
  # 这里仍显式取一次 ov 类型,是为了让映射错误在绑定阶段就暴露。
  let ovType = toOvElementType(t.elementType)
  let dims = toInt64Shape(t.shape)
  let dataPointer = t.dataPtr()

  if dataPointer == nil and not t.isEmpty:
    # 空张量(某维为 0)。OpenVINO 不接受 nil host 指针。
    raiseIsvikError(
      ecInvalidParameter,
      defaultMessage(ecInvalidParameter),
      "operation=" & $ovOpSetInputTensor & " index=" & $index &
        " reason=tensor-is-empty shape=" & $t.shape
    )

  var native: OvTensorHandle
  let ctx = "index=" & $index & " elementType=" & $t.elementType &
    " shape=" & $t.shape
  guardOv(ovOpSetInputTensor, ctx):
    native = newOvTensor(ovType, dims, dataPointer)
    r.native.setInputTensor(index, native)

  # 覆盖同一索引时,先关掉旧的 Resonance 包装再替换,避免累积未释放的
  # ov_tensor。旧的 Isvik Tensor 引用随之放开,可被正常回收。
  if r.nativeInputs.hasKey(index):
    let old = r.nativeInputs[index]
    if old != nil:
      old.close()
  r.nativeInputs[index] = native
  r.inputTensors[index] = t

method infer*(b: OpenVinoBackend, request: BackendInferRequest) =
  ## 同步执行一次推理。
  b.requireInitialized(ovOpInfer)
  let r = asRequest(request, ovOpInfer)
  guardOv(ovOpInfer, "boundInputs=" & $r.inputTensors.len):
    r.native.infer()

proc copyToIsvikTensor(native: OvTensorHandle, portLabel: string): Tensor =
  ## 把 OpenVINO 输出张量拷成 Isvik 自己拥有数据的 Tensor,并关闭原句柄。
  ##
  ## 提取成共用过程,是因为按索引与按名读取只在「怎么拿到 native」上不同,
  ## 后面的类型映射、大小校验、拷贝、释放完全一样。两份复制的代码迟早会
  ## 只修一处。
  try:
    var ovType: OvElementType
    var dims: seq[int64]
    var byteSize = 0
    guardOv(ovOpGetOutputTensor, portLabel):
      ovType = native.getElementType()
      dims = native.getShape()
      byteSize = native.getByteSize()

    # 元素类型无 Isvik 对应时抛 NOT_IMPLEMENTED(例如 STRING、NF4)。
    # 不做近似映射 —— 见 element_type.nim 的说明。
    let et = fromOvElementType(ovType)

    var shape = newSeq[int](dims.len)
    for i, d in dims:
      shape[i] = int(d)

    result = newTensor(et, shape)

    # 大小一致性检查。两边各自算出的字节数不同,说明对该类型的布局理解不一致
    # (亚字节类型、对齐填充都可能造成差异)。此时拷贝会读越界或写越界,
    # 必须停下而不是照着较小的那个数字拷。
    if byteSize != result.byteLen:
      raiseIsvikError(
        ecInferenceFailed,
        defaultMessage(ecInferenceFailed),
        "operation=" & $ovOpGetOutputTensor & " " & portLabel &
          " reason=byte-size-mismatch ovBytes=" & $byteSize &
          " isvikBytes=" & $result.byteLen &
          " elementType=" & $et & " shape=" & $shape
      )

    if byteSize > 0:
      var source: pointer = nil
      guardOv(ovOpGetOutputTensor, portLabel):
        source = cast[pointer](native.getData(byte))
      if source == nil:
        raiseIsvikError(
          ecInferenceFailed,
          defaultMessage(ecInferenceFailed),
          "operation=" & $ovOpGetOutputTensor & " " & portLabel &
            " reason=output-data-pointer-is-nil"
        )
      copyMem(result.dataPtr(), source, byteSize)
  finally:
    # 从拿到 native 开始的所有失败路径都必须及时释放 OpenVINO 视图。
    native.close()

method getOutputTensor*(b: OpenVinoBackend, request: BackendInferRequest,
                        index: int): Tensor =
  ## 按索引读取输出张量,返回 Isvik 拥有数据的副本。
  ##
  ## 必须拷贝:OpenVINO 的输出缓冲在下一次 infer 时会被改写。
  b.requireInitialized(ovOpGetOutputTensor)
  let r = asRequest(request, ovOpGetOutputTensor)

  var native: OvTensorHandle
  guardOv(ovOpGetOutputTensor, "index=" & $index):
    native = r.native.getOutputTensor(index)

  result = copyToIsvikTensor(native, "index=" & $index)

# ---------------------------------------------------------------------------
# 按端口名绑定与端口枚举
# ---------------------------------------------------------------------------
#
# KV-cache 的输入索引是模型图的实现细节,同一架构的两次导出可能给出不同顺序。
# 按索引绑定会把一个可能变化的顺序写死,而错装 key / value 的后果是「推理成功
# 但输出是错的」—— 见 core/backend.nim 中 setInputTensorByName 的说明。

method setInputTensorByName*(b: OpenVinoBackend, request: BackendInferRequest,
                             name: string, t: Tensor) =
  ## 按端口名绑定输入张量。
  ##
  ## 与按索引版本一样是**零拷贝**,因此同样必须持有引用防止 GC。
  ## 这里用 `nameKeyed` 表而不是复用 `nativeInputs`(键是 int):两者的键
  ## 空间不同,混在一起会让「按名绑定后又按索引绑定同一端口」的行为变得
  ## 不可预测。
  b.requireInitialized(ovOpSetInputTensor)
  let r = asRequest(request, ovOpSetInputTensor)

  if t == nil:
    raiseIsvikError(
      ecInvalidParameter,
      defaultMessage(ecInvalidParameter),
      "operation=" & $ovOpSetInputTensor & " name=" & name &
        " reason=tensor-is-nil"
    )

  let ovType = toOvElementType(t.elementType)
  let dims = toInt64Shape(t.shape)
  let dataPointer = t.dataPtr()

  if dataPointer == nil and not t.isEmpty:
    raiseIsvikError(
      ecInvalidParameter,
      defaultMessage(ecInvalidParameter),
      "operation=" & $ovOpSetInputTensor & " name=" & name &
        " reason=tensor-is-empty shape=" & $t.shape
    )

  var native: OvTensorHandle
  let ctx = "name=" & name & " elementType=" & $t.elementType &
    " shape=" & $t.shape
  guardOv(ovOpSetInputTensor, ctx):
    native = newOvTensor(ovType, dims, dataPointer)
    r.native.setTensor(name, native)

  if r.namedNativeInputs.hasKey(name):
    let old = r.namedNativeInputs[name]
    if old != nil:
      old.close()
  r.namedNativeInputs[name] = native
  r.namedInputTensors[name] = t

method setStringInputByName*(b: OpenVinoBackend, request: BackendInferRequest,
                            name: string, texts: seq[string]) =
  ## 按端口名绑定 STRING 输入。
  ##
  ## 与数值张量不同,这里是**拷贝**语义:`ov_tensor_set_string_data` 让
  ## OpenVINO 复制字符内容,所以 `texts` 不需要活过本次调用。但张量句柄
  ## 本身仍要持有到 infer 结束,因此照样登记进 `namedNativeInputs`。
  b.requireInitialized(ovOpSetInputTensor)
  let r = asRequest(request, ovOpSetInputTensor)

  var native: OvTensorHandle
  let ctx = "name=" & name & " elementType=STRING count=" & $texts.len
  guardOv(ovOpSetInputTensor, ctx):
    native = newStringTensor(texts)
    r.native.setTensor(name, native)

  if r.namedNativeInputs.hasKey(name):
    let old = r.namedNativeInputs[name]
    if old != nil:
      old.close()
  r.namedNativeInputs[name] = native
  # STRING 输入没有对应的 Isvik Tensor,所以只登记原生句柄。若该端口先前
  # 绑过数值张量,这里必须把旧的 Isvik 侧引用去掉,否则会白白钉住一块内存。
  if r.namedInputTensors.hasKey(name):
    r.namedInputTensors.del(name)

method getOutputTensorByName*(b: OpenVinoBackend, request: BackendInferRequest,
                              name: string): Tensor =
  ## 按端口名读取输出张量,返回 Isvik 拥有数据的副本。
  b.requireInitialized(ovOpGetOutputTensor)
  let r = asRequest(request, ovOpGetOutputTensor)

  var native: OvTensorHandle
  guardOv(ovOpGetOutputTensor, "name=" & name):
    native = r.native.getTensor(name)

  result = copyToIsvikTensor(native, "name=" & name)

method inputPortNames*(b: OpenVinoBackend,
                       compiled: BackendCompiledModel): seq[string] =
  ## 已编译模型的输入端口名,按索引顺序。
  b.requireInitialized(ovOpCreateInferRequest)
  let cm = asCompiled(compiled, ovOpCreateInferRequest)
  result = @[]
  guardOv(ovOpCreateInferRequest, "query=inputPortNames"):
    for port in cm.native.inputPorts():
      result.add(port.name)

method outputPortNames*(b: OpenVinoBackend,
                        compiled: BackendCompiledModel): seq[string] =
  ## 已编译模型的输出端口名,按索引顺序。
  b.requireInitialized(ovOpCreateInferRequest)
  let cm = asCompiled(compiled, ovOpCreateInferRequest)
  result = @[]
  guardOv(ovOpCreateInferRequest, "query=outputPortNames"):
    for port in cm.native.outputPorts():
      result.add(port.name)
