## Backend 抽象层
##
## 对应 Master Prompt §6(Backend Abstraction)与 §50(PHASE 3)。
##
## ---
##
## ## 定位
##
## ```text
## Isvik Core
##     ↓
## Backend Abstraction   ← 本模块
##     ↓
## OpenVINO Backend / MockBackend
## ```
##
## Core 通过本模块描述完整的推理生命周期,**不感知任何具体 Backend**。
## 本模块只依赖 core/errors 与 core/tensor,不得 import 任何 Backend 实现,
## 更不得 import resonance / openvino。
##
## ---
##
## ## 为什么用继承而不是闭包表(vtable)
##
## §6 明确要求「未来可以扩展其他 Backend,但不要过度抽象」。
## 当前只有一个真实 Backend(OpenVINO)加一个测试用 MockBackend,
## 继承 + method 分派已经够用,且比手写闭包表更易读、更易在编译期发现
## 未实现的方法。插件注册表、动态加载之类的机制在有第二个真实 Backend
## 之前不引入。
##
## ---
##
## ## 为什么操作方法挂在 Backend 上,而不是挂在各句柄类型上
##
## 更「面向对象」的写法是 `model.compile(device)`。这里没有那样做,
## 原因是具体 Backend 在执行任何操作时都需要访问自身状态(例如
## OpenVINO Backend 持有的 `ov_core_t`)。把操作集中在 Backend 上,
## 句柄退化为纯状态载体,继承体系只有一棵需要 method 分派的树,
## 避免四棵并行的继承树带来的复杂度。
##
## ---
##
## ## 资源所有权(§69)
##
## 每类原生资源都有对应的显式释放方法:
##
## ```text
## loadModel          → releaseModel
## compileModel       → releaseCompiledModel
## createInferRequest → releaseInferRequest
## initialize         → release
## ```
##
## 不依赖析构器的时机。释放操作必须可重复调用而不崩溃。

import std/tables

import isvik/core/errors
import isvik/core/tensor

type
  BackendDeviceInfo* = object
    ## Backend 报告的**原始**设备信息,尚未经过 Isvik 的语义解析。
    ##
    ## 这里有意保持「原始」:`rawName` 就是 Backend 自己使用的设备标识
    ## (OpenVINO 会给出 `CPU`、`GPU.0`、`NPU` 这类字符串)。
    ## 把它解析为 §11 的 DeviceType / DeviceId 是 Device Manager 的职责,
    ## 不是 Backend 的职责 —— 这样新增 Backend 不必理解 Isvik 的设备语义。
    rawName*: string
      ## Backend 使用的设备标识,原样保留。
    fullName*: string
      ## 人类可读的完整设备名(如具体型号)。取不到时为空字符串,
      ## **不得**用 rawName 冒充,否则 GUI 会显示伪造的硬件信息(§27)。
    properties*: Table[string, string]
      ## Backend 特有的附加属性。键名由各 Backend 定义。

  BackendModel* = ref object of RootObj
    ## 已加载但尚未编译的模型句柄。具体 Backend 派生并持有原生指针。

  BackendCompiledModel* = ref object of RootObj
    ## 已针对某设备编译完成的模型句柄。

  BackendInferRequest* = ref object of RootObj
    ## 推理请求句柄。

  Backend* = ref object of RootObj
    ## Backend 接口。所有方法由具体实现覆盖。

  CompileOptions* = object
    ## 编译选项。
    ##
    ## 保持为「字符串键值对 + 少量显式字段」而非强类型枚举集合:
    ## OpenVINO 的属性键随版本增减,强类型化会让 Isvik 每次都要跟着改。
    ## 具体键的合法性由各 Backend 校验。
    device*: string
      ## 目标设备的 rawName。
    enableProfiling*: bool
      ## 是否开启性能计数(§35 Benchmark 需要)。
    properties*: Table[string, string]
      ## 传给 Backend 的附加属性。

  ModelDimension* = object
    ## 模型输入维度的闭区间约束。minimum == maximum 表示静态维。
    minimum*: int
    maximum*: int

  ModelInputShape* = object
    ## 编译前按公开端口名施加的 bounded partial shape。
    name*: string
    dims*: seq[ModelDimension]

proc initCompileOptions*(device: string, enableProfiling: bool = false):
    CompileOptions =
  ## 构造编译选项。
  CompileOptions(
    device: device,
    enableProfiling: enableProfiling,
    properties: initTable[string, string]()
  )

# ---------------------------------------------------------------------------
# 未实现方法的统一报错
# ---------------------------------------------------------------------------

proc raiseNotImplemented(b: Backend, operation: string) {.noreturn.} =
  ## 基类方法的默认实现:明确报「该 Backend 未实现此操作」。
  ##
  ## 用 NOT_IMPLEMENTED 而不是静默 discard:静默会让调用方以为操作成功了。
  raiseIsvikError(
    ecNotImplemented,
    "Backend operation is not implemented",
    "backend=" & (if b == nil: "nil" else: $b.type) & " operation=" & operation
  )

# ---------------------------------------------------------------------------
# 元信息
# ---------------------------------------------------------------------------

method name*(b: Backend): string {.base.} =
  ## Backend 名称,如 "openvino" / "mock"。稳定标识,出现在日志与 API 中。
  raiseNotImplemented(b, "name")

method version*(b: Backend): string {.base.} =
  ## Backend 版本。
  ##
  ## 对 OpenVINO Backend,这里应是**真实的** OpenVINO Runtime 版本;
  ## 取不到时必须如实返回未知标记,不得编造(§13、§66)。
  raiseNotImplemented(b, "version")

# ---------------------------------------------------------------------------
# 生命周期(§8)
# ---------------------------------------------------------------------------

method initialize*(b: Backend) {.base.} =
  ## 初始化 Backend(创建原生 Core 等)。
  ##
  ## 底层运行时不可用时应抛 IsvikError(BACKEND_NOT_AVAILABLE),而不是崩溃。
  raiseNotImplemented(b, "initialize")

method isInitialized*(b: Backend): bool {.base.} =
  ## 是否已初始化。
  raiseNotImplemented(b, "isInitialized")

method discoverDevices*(b: Backend): seq[BackendDeviceInfo] {.base.} =
  ## 列出 Backend 报告的可用设备。
  ##
  ## 只报告**真实存在**的设备。没有 NPU 就不要返回 NPU(§13 禁止伪造设备)。
  raiseNotImplemented(b, "discoverDevices")

method registerExtension*(b: Backend, libraryPath: string) {.base.} =
  ## 注册自定义算子扩展库。
  ##
  ## Tokenizer IR **必须**先注册扩展才能加载:它的图里用了 `extension` opset
  ## 的算子(`SpecialTokensSplit`、`VocabDecoder` 等),基础运行时不认识。
  ## 未注册时的报错是
  ## `Cannot create SpecialTokensSplit layer ... from unsupported opset: extension`
  ## —— 这个错误不会提示「你缺扩展」,所以必须在编排层主动注册。
  ##
  ## 注册是**进程内 Backend 级**的:必须在 loadModel 之前调用,
  ## 且注册与加载要用同一个 Backend 实例。
  raiseNotImplemented(b, "registerExtension")

method release*(b: Backend) {.base.} =
  ## 释放 Backend 自身持有的资源。必须可重复调用。
  raiseNotImplemented(b, "release")

# ---------------------------------------------------------------------------
# 模型
# ---------------------------------------------------------------------------

method loadModel*(b: Backend, path: string): BackendModel {.base.} =
  ## 从文件加载模型。
  ##
  ## 文件不存在抛 MODEL_NOT_FOUND;格式无法解析抛 MODEL_INVALID;
  ## 格式可解析但不受支持抛 MODEL_UNSUPPORTED。
  raiseNotImplemented(b, "loadModel")

method releaseModel*(b: Backend, model: BackendModel) {.base.} =
  ## 释放已加载的模型。必须可重复调用。
  raiseNotImplemented(b, "releaseModel")

method reshapeModel*(b: Backend, model: BackendModel,
                     inputs: openArray[ModelInputShape]) {.base.} =
  ## 在编译前为模型输入设置有真实来源的 shape 上下界。
  raiseNotImplemented(b, "reshapeModel")

method compileModel*(b: Backend, model: BackendModel,
                     options: CompileOptions): BackendCompiledModel {.base.} =
  ## 针对指定设备编译模型。
  ##
  ## 设备不可用抛对应的 *_NOT_AVAILABLE;编译失败抛 COMPILATION_FAILED。
  raiseNotImplemented(b, "compileModel")

method releaseCompiledModel*(b: Backend,
                             compiled: BackendCompiledModel) {.base.} =
  ## 释放已编译模型。必须可重复调用。
  raiseNotImplemented(b, "releaseCompiledModel")

method exportCompiledModel*(b: Backend, compiled: BackendCompiledModel,
                            path: string) {.base.} =
  ## 将已编译模型导出为 blob(§17 Compiled Cache 需要)。
  raiseNotImplemented(b, "exportCompiledModel")

method importCompiledModel*(b: Backend, path: string,
                            options: CompileOptions): BackendCompiledModel
                            {.base.} =
  ## 从 blob 导入已编译模型。
  ##
  ## blob 与当前设备 / 运行时版本不匹配时抛 CACHE_INVALID;
  ## 内容损坏抛 CACHE_CORRUPTED。
  raiseNotImplemented(b, "importCompiledModel")

# ---------------------------------------------------------------------------
# 推理
# ---------------------------------------------------------------------------

method createInferRequest*(b: Backend, compiled: BackendCompiledModel):
    BackendInferRequest {.base.} =
  ## 创建推理请求。
  raiseNotImplemented(b, "createInferRequest")

method releaseInferRequest*(b: Backend,
                            request: BackendInferRequest) {.base.} =
  ## 释放推理请求。必须可重复调用。
  raiseNotImplemented(b, "releaseInferRequest")

method setInputTensor*(b: Backend, request: BackendInferRequest,
                       index: int, t: Tensor) {.base.} =
  ## 按索引绑定输入张量。
  ##
  ## 索引形式对单输入模型足够,但**不适合 KV-cache** —— 见
  ## `setInputTensorByName` 的说明。
  raiseNotImplemented(b, "setInputTensor")

method getOutputTensor*(b: Backend, request: BackendInferRequest,
                        index: int): Tensor {.base.} =
  ## 按索引读取输出张量。返回的是 Isvik 自己拥有数据的 Tensor。
  raiseNotImplemented(b, "getOutputTensor")

method setInputTensorByName*(b: Backend, request: BackendInferRequest,
                             name: string, t: Tensor) {.base.} =
  ## 按**端口名**绑定输入张量。
  ##
  ## ---
  ##
  ## ## 为什么 KV-cache 必须按名绑定
  ##
  ## 一个带 KV-cache 的 LLM 有几十个形如 `past_key_values.0.key` /
  ## `past_key_values.0.value` 的输入,外加 `input_ids`、`attention_mask`、
  ## `position_ids`。**它们的索引是模型图的实现细节** —— 同一架构的两次导出
  ## 可能给出不同顺序,模型本身也不保证顺序稳定。
  ##
  ## 按索引绑定 KV-cache 等于把一个可能变化的顺序写死。失败方式是最糟的
  ## 那一类:推理成功、输出看起来合理但其实错的 —— 因为 key 与 value 被
  ## 装反了。按名绑定从根上消除这类 bug。
  raiseNotImplemented(b, "setInputTensorByName")

method getOutputTensorByName*(b: Backend, request: BackendInferRequest,
                              name: string): Tensor {.base.} =
  ## 按端口名读取输出张量。
  ##
  ## 这是 KV-cache 循环的另一半:把本步的 present-state 输出按名读出,
  ## 作为下一步的 past-state 输入喂回去。
  raiseNotImplemented(b, "getOutputTensorByName")

method setStringInputByName*(b: Backend, request: BackendInferRequest,
                            name: string, texts: seq[string]) {.base.} =
  ## 按端口名绑定 **STRING** 输入。
  ##
  ## 单独一个方法而不是复用 `setInputTensorByName`,是因为 Isvik 的
  ## `Tensor` 只表示数值元素类型 —— STRING 元素没有扁平字节布局,
  ## 塞不进 `Tensor`。
  ##
  ## Tokenizer IR 的唯一输入端口就是 STRING(在真实模型上实测确认),
  ## 所以没有这个方法就完全无法调用 tokenizer。
  raiseNotImplemented(b, "setStringInputByName")

method inputPortNames*(b: Backend,
                       compiled: BackendCompiledModel): seq[string] {.base.} =
  ## 已编译模型的输入端口名,按索引顺序。
  ##
  ## 推理编排靠它**发现**模型有没有 KV-cache,而不是假设有。
  raiseNotImplemented(b, "inputPortNames")

method outputPortNames*(b: Backend,
                        compiled: BackendCompiledModel): seq[string] {.base.} =
  ## 已编译模型的输出端口名,按索引顺序。
  raiseNotImplemented(b, "outputPortNames")

method infer*(b: Backend, request: BackendInferRequest) {.base.} =
  ## 同步执行一次推理。
  ##
  ## 失败抛 INFERENCE_FAILED。异步推理待 Resonance 提供后再加(§70)。
  raiseNotImplemented(b, "infer")
