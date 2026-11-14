## Tokenizer:文本 → token id。
##
## 对应 Master Prompt §15(Inference Pipeline)、§0.5.2(建在 Backend 抽象之上)。
##
## ---
##
## ## 编码走模型,解码走词表 —— 为什么不对称
##
## OpenVINO 的模型目录里有一对 IR:
##
## ```text
## openvino_tokenizer.xml     STRING[1]  -> input_ids I64[1,n], attention_mask
## openvino_detokenizer.xml   I64[1,n]   -> Result    STRING
## ```
##
## **编码用 IR,解码不用。** 原因不是设计偏好,是本机 DLL 的硬限制:
##
## | 符号 | 状态 | 后果 |
## |---|---|---|
## | `ov_tensor_set_string_data` | FOUND | 能**写** STRING 张量 → 编码可行 |
## | `ov_tensor_get_string_data` | MISSING | 不能**读** STRING 张量 |
## | `ov_tensor_data_string` | MISSING | 同上 |
## | `ov_string_tensor_data` | MISSING | 同上 |
##
## detokenizer 的输出端口类型是 STRING,而读它的符号一个都不存在,
## 所以那个 IR 在当前运行时里**无法使用**。
##
## 曾考虑用 `ov_tensor_data` 拿裸指针自己解析 `std::string`,已否决:
## `openvino_c.dll` 由 MSVC 编译、Nim 由 MinGW 编译,`std::string` 的内存布局
## 是实现细节而非 ABI 契约,跨编译器解析它属于「能跑但随时会碎」。
##
## 因此解码改用纯 Nim 的 `vocabulary.nim` 反查词表。这不是降级方案:
## 反向解码只需要 id→token 映射与字节回退处理,不需要 merges,
## 纯 Nim 实现完全够用且可测。
##
## ---
##
## ## 必须先注册扩展
##
## tokenizer IR 用了 `extension` opset 的算子(`SpecialTokensSplit` 等),
## 不注册 `openvino_tokenizers.dll` 就直接加载会失败,报错是:
##
## ```text
## Cannot create SpecialTokensSplit layer ... from unsupported opset: extension
## ```
##
## 这个错误**不会**提示「你缺扩展库」,所以注册必须由本模块主动完成,
## 且必须在 `loadModel` 之前。
##
## ---
##
## ## tokenizer IR 不加 BOS
##
## 实测:`"Hello, world!"` → `@[9259, 236764, 1902, 236888]`,没有前置 BOS(id 2)。
## Gemma 需要 BOS,所以由 `encode` 按参数补,而 BOS 的 id 来自
## `generation_config.json`,不写死。

import std/[os, strutils]

import isvik/core/errors
import isvik/core/tensor
import isvik/core/runtime

const
  TokenizerModelFile* = "openvino_tokenizer.xml"
  TokenizerExtensionFile* = when defined(linux): "libopenvino_tokenizers.so"
                            else: "openvino_tokenizers.dll"
  TokenizerExtensionEnvVar* = "ISVIK_TOKENIZERS_DLL"
    ## 显式指定 tokenizer 扩展库的环境变量。给「DLL 不在常规位置」的
    ## 环境一个不改代码的出路。

  TokenIdsPort* = "input_ids"
  AttentionMaskPort* = "attention_mask"
    ## tokenizer IR 的输出端口名(真实模型实测)。输入端口名是自动生成的
    ## (如 `Parameter_181208`),因此**必须**按索引发现,不能写死。

type
  Tokenizer* = ref object
    ## tokenizer IR 的包装。
    runtime: Runtime
    modelId: ModelId
    compiledId: CompiledModelId
    inputPortName: string
      ## 唯一输入端口的名字。自动生成,每次导出模型都可能不同,
      ## 所以在构造时从已编译模型问出来。
    hasAttentionMask: bool
      ## 该 IR 是否也输出 attention_mask。不假设一定有。
    device: string
    released: bool

proc findExtensionLibrary*(searchDirs: openArray[string]): string =
  ## 在候选目录里找 tokenizer 扩展库。找不到返回空字符串。
  ##
  ## 返回空而不抛错:调用方可能并不需要 tokenizer(例如只做纯张量推理),
  ## 把「没找到」升级成错误会让无关路径也失败。
  for dir in searchDirs:
    if dir.len == 0:
      continue
    let candidate = dir / TokenizerExtensionFile
    if fileExists(candidate):
      return candidate
  ""

proc resolveExtensionLibrary*(explicit: string, modelDir: string): string =
  ## 决定本次要用的 tokenizer 扩展库路径。找不到返回空串,由 `newTokenizer`
  ## 报出一个能自解释的错误(它知道「为什么需要这个库」)。
  ##
  ## 候选顺序按「越显式越优先」排:显式参数 → 环境变量 → 工作目录 →
  ## 可执行文件目录 → 模型目录。
  ##
  ## 这条策略住在这里而不是 CLI:HTTP Server 与 benchmark 同样要加载
  ## tokenizer,让每个前端各找一遍 DLL 会导致「命令行能跑、服务跑不起来」
  ## 这类只在某一条路径上出现的故障。
  if explicit.len > 0:
    return explicit
  let fromEnv = getEnv(TokenizerExtensionEnvVar).strip()
  if fromEnv.len > 0:
    return fromEnv
  result = findExtensionLibrary([
    getCurrentDir() / "runtime" / "openvino",
    getAppDir() / "runtime" / "openvino",
    getAppDir(),
    modelDir
  ])

proc newTokenizer*(rt: Runtime, tokenizerXmlPath: string,
                  extensionLibraryPath: string,
                  device: string = DeviceRequestAuto): Tokenizer =
  ## 加载并编译 tokenizer IR。
  ##
  ## `extensionLibraryPath` 必填且必须存在 —— 没有它这个 IR 一定加载失败,
  ## 而失败信息不会指向缺扩展。提前检查换来一个能自解释的错误。
  if rt == nil:
    raiseIsvikError(
      ecInvalidParameter,
      "Runtime must not be nil",
      "operation=newTokenizer"
    )
  if not fileExists(tokenizerXmlPath):
    raiseIsvikError(
      ecModelNotFound,
      "Tokenizer model was not found",
      "path=" & tokenizerXmlPath
    )
  if extensionLibraryPath.len == 0 or not fileExists(extensionLibraryPath):
    raiseIsvikError(
      ecBackendNotAvailable,
      "The tokenizer extension library is required to load a tokenizer model",
      "path=" & extensionLibraryPath & " model=" & tokenizerXmlPath &
        " reason=tokenizer-ir-uses-extension-opset"
    )

  # 注册必须先于加载。顺序错了会得到一个不提示缺扩展的 opset 错误。
  rt.registerExtension(extensionLibraryPath)

  let modelId = rt.loadModel(tokenizerXmlPath)
  try:
    let compiled = rt.compileModelForDevice(modelId, device)

    let inputs = rt.inputPortNames(compiled.compiled)
    if inputs.len != 1:
      raiseIsvikError(
        ecModelUnsupported,
        "A tokenizer model is expected to have exactly one input port",
        "path=" & tokenizerXmlPath & " inputCount=" & $inputs.len &
          " ports=" & inputs.join(",")
      )

    let outputs = rt.outputPortNames(compiled.compiled)
    if TokenIdsPort notin outputs:
      raiseIsvikError(
        ecModelUnsupported,
        "The tokenizer model does not expose an 'input_ids' output",
        "path=" & tokenizerXmlPath & " outputs=" & outputs.join(",")
      )

    result = Tokenizer(
      runtime: rt,
      modelId: modelId,
      compiledId: compiled.compiled,
      inputPortName: inputs[0],
      hasAttentionMask: AttentionMaskPort in outputs,
      device: compiled.selection.device.rawName,
      released: false
    )
  except CatchableError:
    let original = getCurrentException()
    try:
      # unloadModel 是本事务唯一的回滚入口；它会级联释放已编译模型。
      rt.unloadModel(modelId)
    except CatchableError:
      discard
    raise original

proc device*(t: Tokenizer): string =
  ## tokenizer 实际编译到的设备 rawName。
  if t == nil: "" else: t.device

proc inputPortName*(t: Tokenizer): string =
  if t == nil: "" else: t.inputPortName

proc producesAttentionMask*(t: Tokenizer): bool =
  t != nil and t.hasAttentionMask

proc isReleased*(t: Tokenizer): bool =
  t == nil or t.released

proc requireOpen(t: Tokenizer, action: string) =
  if t == nil or t.released:
    raiseIsvikError(
      ecInvalidParameter,
      "The tokenizer has already been released",
      "operation=" & action
    )

proc release*(t: Tokenizer) =
  ## 释放 tokenizer 持有的模型与已编译模型。可重复调用。
  if t == nil or t.released:
    return
  t.released = true
  # unloadModel 会级联释放由该模型编译出的已编译模型及其推理请求,
  # 所以不必(也不应)先单独释放 compiledId —— 那会变成二次释放。
  try:
    t.runtime.unloadModel(t.modelId)
  except CatchableError:
    # 释放路径不得把错误传播出去,否则会掩盖调用方正在处理的原始错误。
    discard

proc encodeRaw*(t: Tokenizer, text: string): seq[int] =
  ## 把文本编码成 token id,**不做**任何特殊 token 补齐。
  ##
  ## 每次调用新建并释放一个 InferRequest。tokenizer 是无状态的,复用请求
  ## 只省下极小的分配开销,却会让并发调用互相踩;这里选简单正确。
  t.requireOpen("encodeRaw")
  let requestId = t.runtime.createInferRequest(t.compiledId)
  try:
    t.runtime.setStringInputByName(requestId, t.inputPortName, @[text])
    t.runtime.infer(requestId)
    let idsTensor = t.runtime.getOutputByName(requestId, TokenIdsPort)
    if idsTensor.elementType != etI64:
      raiseIsvikError(
        ecModelUnsupported,
        "Tokenizer 'input_ids' output must be I64",
        "elementType=" & $idsTensor.elementType
      )
    let n = idsTensor.elementCount
    let data = idsTensor.data(int64)
    result = newSeq[int](n)
    for i in 0 ..< n:
      result[i] = int(data[i])
  finally:
    t.runtime.releaseInferRequest(requestId)

proc encode*(t: Tokenizer, text: string, bosTokenId: int = -1): seq[int] =
  ## 编码文本,并在需要时前置 BOS。
  ##
  ## tokenizer IR 实测**不会**自动加 BOS,而 Gemma 需要它。`bosTokenId` 为
  ## 负数表示「不加」—— 由调用方按 `generation_config.json` 决定,
  ## 这里不猜。
  ##
  ## 已经以 BOS 开头时不重复添加:重复的 BOS 会让模型看到一个训练时
  ## 没出现过的前缀。
  result = t.encodeRaw(text)
  if bosTokenId >= 0 and (result.len == 0 or result[0] != bosTokenId):
    result = @[bosTokenId] & result
