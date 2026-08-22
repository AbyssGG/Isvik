## 文本生成编排。
##
## 对应 Master Prompt §15(Inference Pipeline)、§17(Task 17 端到端生成)、
## §13(禁止伪造)、§35(不得声称未采集到的指标)。
##
## ---
##
## ## 管线(形状全部来自真实模型实测,不是推测)
##
## Gemma 4 E2B 不是单一 IR,而是一组协同的 IR:
##
## ```text
##  文本
##   │  tokenizer.xml            STRING[1] -> input_ids I64[1,n]
##   ▼
##  token id
##   ├─ text_embeddings.xml            I64[1,n] -> inputs_embeds F32[1,n,1536]
##   └─ text_embeddings_per_layer.xml  I64[1,n] -> F32[1,n,35,256]
##          │
##          ▼
##  language_model.xml
##      inputs_embeds     F32[1,n,1536]
##      per_layer_inputs  F32[1,n,35,256]
##      attention_mask    I64[1,总长]
##      position_ids      I64[1,n]
##      beam_idx          I32[1]
##          │
##          ▼
##      logits F32[1,n,262144]  ──argmax(最后位置)──▶ 下一个 token
## ```
##
## 每一个数字都是从真实模型问出来的:hidden=1536、PLE 层数=35、PLE 维=256、
## 词表=262144。层数尤其不能猜 —— `per_layer_inputs` 的那一维在
## partial shape 里是**动态**的,只有 per-layer IR 的输出端口才写着 35
## (并且与权重形状 262144×8960 = 35×256 相互印证)。
##
## 另一套已核验的 Gemma 4 26B 导出会生成 F32 `[1,n,30,0]`；其末维
## `0` 是合法的零元素 tensor 契约。实现始终执行 producer 并绑定真实输出，
## 不能按模型名猜 shape，也不能把零维强行改成非零占位。
##
## ---
##
## ## KV-cache:内部状态,不是端口
##
## 探测真实 `language_model.xml` 的结论:
##
## * **没有** `past_key_values.*` 输入,**没有** `present.*` 输出
## * 因此 KV-cache 是模型的内部状态(stateful model)
## * 而 state API(`ov_infer_request_query_state` / `reset_state` /
##   `ov_variable_state_*`)在本机 DLL 里**全部 MISSING**
##
## 两个直接后果:
##
## 1. **一次生成复用同一个 InferRequest**,让内部 cache 逐步累积;
##    第二步起只喂新 token(`seq=1`),`attention_mask` 长度用累计总长。
## 2. **不能重置状态**,所以一个 InferRequest 只能服务一次生成。
##    生成结束即释放,不复用。这不是保守,是没有别的选择 ——
##    复用会让第二次生成看到第一次的 cache,输出无声地变错。
##
## ---
##
## ## 只有贪心解码
##
## `generation_config.json` 里模型建议了 temperature / top_k / top_p,
## 但 Isvik 目前**只实现贪心**。那些值仅被读出并记录,不参与解码
## (§20.5.13:不得声明未实现的能力)。贪心的好处是确定性可测:
## 同样输入必然同样输出,回归测试才有意义。

import std/[json, os, random, strutils, times]

import isvik/core/errors
import isvik/core/tensor
import isvik/core/backend
import isvik/core/runtime
import isvik/inference/vocabulary
import isvik/inference/greedy
import isvik/inference/sampling
import isvik/inference/tokenizer
import isvik/inference/gen_defaults
import isvik/inference/chat_format
import isvik/models/manifest
import isvik/models/inspection

const
  LanguageModelFile* = "openvino_language_model.xml"
  TextEmbeddingsFile* = "openvino_text_embeddings_model.xml"
  PerLayerEmbeddingsFile* = "openvino_text_embeddings_per_layer_model.xml"

  # causal language model 的公共端口名。
  PortInputIds* = "input_ids"
  PortInputsEmbeds* = "inputs_embeds"
  PortPerLayerInputs* = "per_layer_inputs"
  PortAttentionMask* = "attention_mask"
  PortPositionIds* = "position_ids"
  PortTokenTypeIds* = "token_type_ids"
  PortBeamIdx* = "beam_idx"
  PortLogits* = "logits"

  # text_embeddings 的端口名。
  EmbeddingsInputPort* = "input"
  EmbeddingsOutputPort* = "inputs_embeds"

  DefaultMaxNewTokens* = 256
  DefaultPrefillBatchTokens* = 256
    ## Stateful LM 在 GPU/NPU 上的 prompt 物理批次上限。
    ##
    ## 语言模型虽然只会消费最后位置的 logits，但导出的 OpenVINO IR 会为本次
    ## 输入的每个位置产生 `[vocab]`。若把 7200 token 一次喂入，F32 logits
    ## 单个对象约 7.03 GiB，会直接超过常见 Intel GPU 的 4 GiB 分配上限。
    ## 像 llama.cpp 的 n_ubatch 一样分块 prefill，可把峰值限制在约
    ## `256 * vocab * sizeof(float32)`，同时继续复用同一 InferRequest 的 KV 状态。
  CpuPrefillBatchTokens* = 512
    ## CPU 没有 GPU 的 4 GiB 单对象限制。使用 512 将 14k prompt 的前向调用
    ## 从约 56 次降到约 28 次，同时把 Gemma F32 logits 控制在约 512 MiB。

  TokenizerDevice* = "CPU"
    ## tokenizer IR **固定编译到 CPU**,与语言模型的设备无关。
    ##
    ## 这不是保守选择,是硬限制。在真实 NPU 上编译 `openvino_tokenizer.xml`
    ## 直接失败:
    ##
    ## ```text
    ## intel_npu ... model_serializer.cpp:119: Incorrect precision: string
    ## ```
    ##
    ## tokenizer 的输入端口元素类型是 STRING,而 NPU 插件不支持这个精度。
    ## 就算它支持,把 tokenizer 放到加速器上也没有意义 —— 那是个字符串
    ## 切分图,不吃算力,却要为此付一次设备编译与一次主机↔设备往返。

type
  StopReason* = enum
    ## 生成为什么停下。**必须**如实回报:把「被长度截断」说成「自然结束」
    ## 会让调用方以为拿到了完整回答。
    srEndOfSequence = "end_of_sequence"
      ## 命中 `generation_config.json` 声明的某个 EOS。
    srMaxTokens = "max_tokens"
      ## 达到 maxNewTokens 上限,输出**可能不完整**。
    srNoEosDeclared = "max_tokens_no_eos_declared"
      ## 达到上限,且模型根本没声明 EOS —— 这种情况下「截断」是唯一可能的
      ## 结局,与「模型声明了 EOS 但没输出」是不同的事实,不可混为一谈。
    srCancelled = "cancelled"
      ## 调用方通过回调请求停止。

  GenerationOptions* = object
    maxNewTokens*: int
    bannedTokenIds*: seq[int]
      ## 禁止生成的 token。用于屏蔽已知会破坏输出的控制 token。
    skipSpecialTokensInText*: bool
      ## 拼接可见文本时是否跳过特殊 token。默认跳过。
      ## 注意这只影响**文本**,`tokenIds` 始终是原始序列。
    sampling*: SamplingConfig
      ## 采样参数。默认是贪心 —— 既有调用方不写它就仍然得到确定性输出。

  GenerationStep* = object
    ## 单步结果,供流式输出使用。
    index*: int
    tokenId*: int
    logit*: float
    textFragment*: string
      ## 本步新产生的**完整 UTF-8** 片段,可能为空字符串。
      ##
      ## 为空是正常的:中文等非 ASCII 字符在 Gemma 词表里是多个字节回退
      ## token(`<0xE4>` 之类),必须攒够一个完整码点才能输出。直接把不完整
      ## 字节吐给终端会让中文永久显示成乱码。

  StepCallback* = proc (step: GenerationStep): bool {.closure.}
    ## 每生成一个 token 调用一次。返回 false 表示请求停止。

  GenerationResult* = object
    text*: string
    tokenIds*: seq[int]
    promptTokenIds*: seq[int]
    stopReason*: StopReason
    samplingSeed*: int64
      ## 本次采样实际使用的 seed;贪心时为 0。
      ##
      ## 即使调用方没指定 seed 也会如实回报具体值,否则「模型有时输出乱码」
      ## 这类报告无法复查。
    promptTokens*: int
    generatedTokens*: int
    prefillBatchTokens*: int
      ## 本次按实际 LM 设备采用的 prompt 物理批次上限。
    prefillMs*: float
      ## 从开始到**第一个** token 产出的耗时(含 prompt 编码后的全部前向)。
    decodeMs*: float
      ## 第一个 token 之后的解码总耗时。生成 ≤1 个 token 时为 0。
    totalMs*: float

  TextGenerator* = ref object
    ## 组合模型的生成编排器。
    runtime: Runtime
    tokenizerRef: Tokenizer
    vocab: Vocabulary
    defaults: GenerationDefaults
    chatFmt: ChatFormat
    layout: ModelLayout
    addBosToken: bool
    contextLength: int
    usesStaticNpuShape: bool

    lmModel: ModelId
    lmCompiled: CompiledModelId
    embModel: ModelId
    embCompiled: CompiledModelId
    pleModel: ModelId
    pleCompiled: CompiledModelId

    hiddenSize: int
    pleLayers: int
    pleDim: int
    usesTokenTypeIds: bool
      ## 是否按 inspection 的真实 I64/rank-2 契约绑定 token_type_ids。
    usesPerLayer: bool
      ## 该 language_model 是否需要 `per_layer_inputs`。按端口发现,不假设。

    pleInputPort: string
    pleOutputPort: string

    device: string
    released: bool

proc initGenerationOptions*(maxNewTokens: int = DefaultMaxNewTokens,
                           bannedTokenIds: openArray[int] = [],
                           skipSpecialTokensInText: bool = true,
                           sampling: SamplingConfig = greedySamplingConfig()):
    GenerationOptions =
  ## 采样默认为贪心:既有调用方不传 `sampling` 就仍然得到确定性输出,
  ## 端到端测试的真断言因此不受影响。
  GenerationOptions(
    maxNewTokens: maxNewTokens,
    bannedTokenIds: @bannedTokenIds,
    skipSpecialTokensInText: skipSpecialTokensInText,
    sampling: sampling
  )

# ---------------------------------------------------------------------------
# 构造
# ---------------------------------------------------------------------------

proc requireFile(path, what: string) =
  if not fileExists(path):
    raiseIsvikError(
      ecModelNotFound,
      "A required model file is missing",
      "what=" & what & " path=" & path
    )

proc discoverShapes(g: TextGenerator) =
  ## 用一次最小推理问出 hidden size 与 PLE 维度。
  ##
  ## 为什么不读端口形状:那些维在真实模型上是动态的,`ov_const_port_get_shape`
  ## 对它们直接失败。而**跑一次单 token 的 embedding** 会得到完全确定的
  ## 输出形状 —— 用事实代替推断,代价是一次极小的前向。
  let probeIds = @[if g.defaults.hasBos: g.defaults.bosTokenId else: 0]

  block embeddings:
    let req = g.runtime.createInferRequest(g.embCompiled)
    try:
      var idsData = newSeq[int64](probeIds.len)
      for i, v in probeIds: idsData[i] = int64(v)
      let idsTensor = newTensor(etI64, [1, probeIds.len], idsData)
      g.runtime.setInputByName(req, EmbeddingsInputPort, idsTensor)
      g.runtime.infer(req)
      let outT = g.runtime.getOutputByName(req, EmbeddingsOutputPort)
      let shape = outT.shape
      if shape.len != 3:
        raiseIsvikError(
          ecModelUnsupported,
          "Text embeddings output is expected to be rank 3 [batch, seq, hidden]",
          "shape=" & $shape
        )
      g.hiddenSize = shape[2]
    finally:
      g.runtime.releaseInferRequest(req)

  if g.usesPerLayer:
    let req = g.runtime.createInferRequest(g.pleCompiled)
    try:
      var idsData = newSeq[int64](probeIds.len)
      for i, v in probeIds: idsData[i] = int64(v)
      let idsTensor = newTensor(etI64, [1, probeIds.len], idsData)
      g.runtime.setInputByName(req, g.pleInputPort, idsTensor)
      g.runtime.infer(req)
      let outT = g.runtime.getOutputByName(req, g.pleOutputPort)
      let shape = outT.shape
      if shape.len != 4:
        raiseIsvikError(
          ecModelUnsupported,
          "Per-layer embeddings output is expected to be rank 4 " &
            "[batch, seq, layers, dim]",
          "shape=" & $shape
        )
      g.pleLayers = shape[2]
      g.pleDim = shape[3]
    finally:
      g.runtime.releaseInferRequest(req)

proc discoverPrimaryIr(modelDir: string): string =
  ## 优先采用稳定的 OpenVINO 导出文件名；否则只在候选唯一时采用它。
  for name in [LanguageModelFile, "openvino_model.xml", "model.xml"]:
    let candidate = modelDir / name
    if fileExists(candidate):
      return candidate

  var candidates: seq[string] = @[]
  for kind, path in walkDir(modelDir):
    if kind == pcFile and path.toLowerAscii().endsWith(".xml"):
      let name = path.extractFilename.toLowerAscii()
      if "tokenizer" notin name and "embedding" notin name:
        candidates.add(path)
  if candidates.len == 1:
    return candidates[0]
  ""

proc shouldAddBos(modelDir: string, defaults: GenerationDefaults): bool =
  ## tokenizer_config.json 的显式 add_bos_token 优先。GPT-2/GPT-J 常声明
  ## bos_token_id 与 eos 相同但 add_bos_token=false，不能仅因 id 存在就前置。
  let path = modelDir / "tokenizer_config.json"
  if fileExists(path):
    try:
      let node = parseJson(readFile(path))
      if node.kind == JObject and node.hasKey("add_bos_token") and
          node["add_bos_token"].kind == JBool:
        return node["add_bos_token"].getBool
    except CatchableError:
      discard
  # 旧模型没有该配置时保持既有行为；bos id 仍来自真实 generation config。
  defaults.hasBos

proc newTextGenerator*(rt: Runtime, modelDir: string,
                      extensionLibraryPath: string = "",
                      device: string = DeviceRequestAuto,
                      tokenizerDevice: string = TokenizerDevice): TextGenerator =
  ## 从模型目录构建生成器。
  ##
  ## 会加载并编译 tokenizer、text_embeddings、language_model,以及在
  ## language_model 声明了 `per_layer_inputs` 时加载 per-layer embeddings。
  ##
  ## `per_layer_inputs` 端口的**存在性**决定是否加载那个 IR ——
  ## Gemma 4 E2B 的 per-layer 权重有 2.2 GB,不需要就不该付这个代价;
  ## 而需要却不喂,模型会拿到零张量,输出**无声地变错**。
  ##
  ## `tokenizerDevice` 与 `device` 分开,默认固定 CPU,原因见
  ## `TokenizerDevice` 的说明 —— 那不是保守选择,是硬限制。
  if rt == nil:
    raiseIsvikError(
      ecInvalidParameter,
      "Runtime must not be nil",
      "operation=newTextGenerator"
    )
  if not dirExists(modelDir):
    raiseIsvikError(
      ecModelNotFound,
      "Model directory was not found",
      "path=" & modelDir
    )

  let lmPath = discoverPrimaryIr(modelDir)
  if lmPath.len == 0:
    raiseIsvikError(
      ecModelInvalid,
      "Could not identify a unique primary OpenVINO IR",
      "path=" & modelDir
    )
  let inspection = inspectOpenVinoIr(lmPath)
  var usesTokenTypeIds = false
  for port in inspection.inputs:
    if port.name != PortTokenTypeIds:
      continue
    if port.elementType != "I64" or port.dims.len != 2:
      raiseIsvikError(
        ecModelUnsupported,
        "The token_type_ids input must use I64 with rank 2",
        "elementType=" & port.elementType & " rank=" & $port.dims.len
      )
    usesTokenTypeIds = true
  if inspection.layout notin {mlCompositeEmbeddingCausalLm,
                              mlMonolithicTokenCausalLm}:
    raiseIsvikError(
      ecModelUnsupported,
      "The detected model layout has no text generation executor",
      "layout=" & $inspection.layout & " reason=" & inspection.reason
    )

  let embPath = modelDir / TextEmbeddingsFile
  if inspection.layout == mlCompositeEmbeddingCausalLm:
    requireFile(embPath, "text_embeddings")

  var extPath = extensionLibraryPath
  if extPath.len == 0:
    extPath = findExtensionLibrary([
      getCurrentDir() / "runtime" / "openvino",
      modelDir,
      getAppDir()
    ])

  proc rollbackPartial(g: TextGenerator) =
    ## 构造尚未提交时的安静回滚。只释放已经写入对象字段的资源；模型卸载
    ## 会级联释放对应的 compiled model 与 infer request。
    if g == nil:
      return
    if g.tokenizerRef != nil:
      try:
        g.tokenizerRef.release()
      except CatchableError:
        discard
    for id in [g.pleModel, g.embModel, g.lmModel]:
      if int(id) == 0:
        continue
      try:
        g.runtime.unloadModel(id)
      except CatchableError:
        discard

  result = TextGenerator(
    runtime: rt,
    layout: inspection.layout,
    usesTokenTypeIds: usesTokenTypeIds,
    hiddenSize: -1,
    pleLayers: -1,
    pleDim: -1,
    released: false
  )

  try:
    result.defaults = loadGenerationDefaults(modelDir)
    result.addBosToken = shouldAddBos(modelDir, result.defaults)
    let fmt = loadChatFormat(modelDir)
    result.chatFmt = fmt.format
    result.vocab = loadVocabulary(modelDir / TokenizerConfigFile)

    # RHS 完整成功后才写入字段；newTokenizer 内部失败时由其自身事务回滚，
    # 此处仍为 nil，外层回滚不会再次释放同一 tokenizer 模型。
    result.tokenizerRef = newTokenizer(
      rt, modelDir / TokenizerModelFile, extPath, tokenizerDevice)

    # 先把 AUTO 解析为具体设备，再决定是否需要 NPU 静态 reshape；否则直接
    # 目录加载时 AUTO 可能最终选中 NPU，却因请求字符串仍是 AUTO 而漏掉 reshape。
    let selected = rt.resolveDevice(device)
    let selectedRaw = selected.device.rawName

    # 每个 ModelId 在取得后立即进入对象字段，之后任一步失败都能被统一回滚。
    result.lmModel = rt.loadModel(lmPath)
    result.contextLength = declaredContextLength(modelDir)
    if result.layout == mlMonolithicTokenCausalLm:
      result.usesStaticNpuShape =
        selectedRaw.toUpperAscii().startsWith(DeviceRequestNpu)
      if result.usesStaticNpuShape:
        let shapes = causalLmNpuStaticShapes(inspection, result.contextLength)
        if shapes.len == 0:
          raiseIsvikError(
            ecModelUnsupported,
            "NPU compilation requires a declared static context length",
            "layout=" & $result.layout & " contextLength=" & $result.contextLength
          )
        rt.reshapeModel(result.lmModel, shapes)
    result.lmCompiled = rt.compileModel(
      result.lmModel, initCompileOptions(selectedRaw))
    result.device = selectedRaw

    let lmInputs = rt.inputPortNames(result.lmCompiled)
    if result.usesTokenTypeIds and PortTokenTypeIds notin lmInputs:
      raiseIsvikError(
        ecModelUnsupported,
        "The inspected token_type_ids input is missing after compilation",
        "ports=" & lmInputs.join(",")
      )
    let requiredInputs =
      if result.layout == mlMonolithicTokenCausalLm:
        @[PortInputIds, PortAttentionMask, PortPositionIds]
      else:
        @[PortInputsEmbeds, PortAttentionMask, PortPositionIds]
    for required in requiredInputs:
      if required notin lmInputs:
        raiseIsvikError(
          ecModelUnsupported,
          "The language model does not expose a port required by its detected pipeline",
          "layout=" & $result.layout & " missing=" & required &
            " ports=" & lmInputs.join(",")
        )

    # 布局是执行契约，不只是「至少存在这些端口」。未知必需输入没有可证明
    # 正确的张量语义；留给 OpenVINO 默认值可能推理成功却产生错误结果。
    var supportedInputs = requiredInputs
    supportedInputs.add(PortBeamIdx)
    if result.usesTokenTypeIds:
      supportedInputs.add(PortTokenTypeIds)
    if result.layout == mlCompositeEmbeddingCausalLm:
      supportedInputs.add(PortPerLayerInputs)
    for port in lmInputs:
      if port notin supportedInputs:
        raiseIsvikError(
          ecModelUnsupported,
          "The language model exposes an input unsupported by its detected pipeline",
          "layout=" & $result.layout & " unsupported=" & port &
            " supported=" & supportedInputs.join(",")
        )

    let lmOutputs = rt.outputPortNames(result.lmCompiled)
    if PortLogits notin lmOutputs:
      raiseIsvikError(
        ecModelUnsupported,
        "The language model does not expose a 'logits' output",
        "outputs=" & lmOutputs.join(",")
      )

    result.usesPerLayer = result.layout == mlCompositeEmbeddingCausalLm and
      PortPerLayerInputs in lmInputs

    if result.layout == mlCompositeEmbeddingCausalLm:
      result.embModel = rt.loadModel(embPath)
      result.embCompiled = rt.compileModel(
        result.embModel, initCompileOptions(selectedRaw))

      if result.usesPerLayer:
        let plePath = modelDir / PerLayerEmbeddingsFile
        requireFile(plePath, "text_embeddings_per_layer")
        result.pleModel = rt.loadModel(plePath)
        result.pleCompiled = rt.compileModel(
          result.pleModel, initCompileOptions(selectedRaw))
        let pleIn = rt.inputPortNames(result.pleCompiled)
        let pleOut = rt.outputPortNames(result.pleCompiled)
        if pleIn.len != 1 or pleOut.len != 1:
          raiseIsvikError(
            ecModelUnsupported,
            "Per-layer embeddings model is expected to have one input and one output",
            "inputs=" & pleIn.join(",") & " outputs=" & pleOut.join(",")
          )
        result.pleInputPort = pleIn[0]
        result.pleOutputPort = pleOut[0]

      result.discoverShapes()
  except CatchableError:
    let original = getCurrentException()
    rollbackPartial(result)
    raise original

# ---------------------------------------------------------------------------
# 访问器
# ---------------------------------------------------------------------------

proc modelLayout*(g: TextGenerator): ModelLayout =
  if g == nil: mlUnknown else: g.layout

proc device*(g: TextGenerator): string =
  if g == nil: "" else: g.device

proc prefillBatchTokens*(g: TextGenerator): int =
  ## CPU 用较大的物理批次减少 OpenVINO infer 调用；加速器保持保守上限，
  ## 避免导出 IR 的逐位置完整 vocab logits 超过单对象容量。
  if g != nil and g.usesStaticNpuShape:
    1
  elif g != nil and g.device.toUpperAscii().startsWith("CPU"):
    CpuPrefillBatchTokens
  else:
    DefaultPrefillBatchTokens

proc generationDefaults*(g: TextGenerator): GenerationDefaults =
  if g == nil: initGenerationDefaults() else: g.defaults

proc chatFormat*(g: TextGenerator): ChatFormat =
  if g == nil: cfUnknown else: g.chatFmt

proc vocabulary*(g: TextGenerator): Vocabulary =
  if g == nil: nil else: g.vocab

proc hiddenSize*(g: TextGenerator): int =
  if g == nil: -1 else: g.hiddenSize

proc perLayerShape*(g: TextGenerator): tuple[layers, dim: int] =
  ## PLE 的层数与维度。不使用 per-layer 时为 (-1, -1)。
  if g == nil: (-1, -1) else: (g.pleLayers, g.pleDim)

proc usesPerLayerInputs*(g: TextGenerator): bool =
  g != nil and g.usesPerLayer

proc isReleased*(g: TextGenerator): bool =
  g == nil or g.released

proc release*(g: TextGenerator) =
  ## 释放全部持有的模型。可重复调用。
  if g == nil or g.released:
    return
  g.released = true
  g.tokenizerRef.release()
  for id in [g.lmModel, g.embModel, g.pleModel]:
    if int(id) == 0:
      continue
    try:
      g.runtime.unloadModel(id)
    except CatchableError:
      discard

# ---------------------------------------------------------------------------
# 生成
# ---------------------------------------------------------------------------

proc requireOpen(g: TextGenerator, action: string) =
  if g == nil or g.released:
    raiseIsvikError(
      ecInvalidParameter,
      "The text generator has already been released",
      "operation=" & action
    )

proc runEmbeddings(g: TextGenerator, ids: seq[int]): Tensor =
  ## text_embeddings 前向。返回 F32[1,n,hidden]。
  let req = g.runtime.createInferRequest(g.embCompiled)
  try:
    var data = newSeq[int64](ids.len)
    for i, v in ids: data[i] = int64(v)
    let inTensor = newTensor(etI64, [1, ids.len], data)
    g.runtime.setInputByName(req, EmbeddingsInputPort, inTensor)
    g.runtime.infer(req)
    result = g.runtime.getOutputByName(req, EmbeddingsOutputPort)
  finally:
    g.runtime.releaseInferRequest(req)

proc runPerLayerEmbeddings(g: TextGenerator, ids: seq[int]): Tensor =
  ## per-layer embeddings 前向。返回 F32[1,n,layers,dim]。
  let req = g.runtime.createInferRequest(g.pleCompiled)
  try:
    var data = newSeq[int64](ids.len)
    for i, v in ids: data[i] = int64(v)
    let inTensor = newTensor(etI64, [1, ids.len], data)
    g.runtime.setInputByName(req, g.pleInputPort, inTensor)
    g.runtime.infer(req)
    result = g.runtime.getOutputByName(req, g.pleOutputPort)
  finally:
    g.runtime.releaseInferRequest(req)

proc generateFromTokens*(g: TextGenerator, promptIds: seq[int],
                        options: GenerationOptions = initGenerationOptions(),
                        onStep: StepCallback = nil): GenerationResult =
  ## 从 token 序列生成。
  ##
  ## `promptIds` 必须已经包含 BOS(若模型需要)—— 本函数不再补,
  ## 因为「补过没补过」在这一层无法可靠判断,重复的 BOS 会让模型看到
  ## 训练时不存在的前缀。用 `generate` 走完整路径可自动处理。
  g.requireOpen("generateFromTokens")
  if promptIds.len == 0:
    raiseIsvikError(
      ecInvalidParameter,
      "The prompt must contain at least one token",
      "operation=generateFromTokens"
    )
  if options.maxNewTokens <= 0:
    raiseIsvikError(
      ecInvalidParameter,
      "maxNewTokens must be positive",
      "maxNewTokens=" & $options.maxNewTokens
    )

  options.sampling.requireValid()
  let greedyDecoding = options.sampling.isGreedy
  # RNG 在循环**外**创建:每步重建会让整轮生成用同一个随机点,
  # 表现为模型反复输出同一个 token。
  var rng: Rand
  var seedUsed: int64 = 0
  if not greedyDecoding:
    let prepared = newSamplingRng(options.sampling)
    rng = prepared.rng
    seedUsed = prepared.seed

  let started = epochTime()
  var firstTokenAt = 0.0
  var generated: seq[int] = @[]
  var utf8 = initPartialUtf8Buffer()
  var text = ""
  var reason =
    if g.defaults.hasEos: srMaxTokens else: srNoEosDeclared
  var prefillBatchTokens = 0

  let decodeOptions = initDecodeOptions(
    skipSpecialTokens = options.skipSpecialTokensInText)

  # 整轮生成复用同一个 InferRequest,让模型内部 KV-cache 累积。
  # 不能跨生成复用:state reset API 在本机运行时缺失,残留 cache 会让
  # 下一次生成无声地产出错误结果。创建成功后立即进入 finally 保护，
  # 端口发现等准备步骤失败也必须释放请求。
  let lmRequest = g.runtime.createInferRequest(g.lmCompiled)
  try:
    let usesBeamIdx = PortBeamIdx in g.runtime.inputPortNames(g.lmCompiled)
    prefillBatchTokens = g.prefillBatchTokens()

    proc inferStep(ids: seq[int], pastLen: int,
                   fetchLogits: bool): Tensor =
      ## 在同一个 stateful InferRequest 上推进一段 token。
      ##
      ## 中间 prefill 批次不读取 logits：OpenVINO 仍会执行图，但 Isvik 不再为
      ## 每个批次额外复制一份巨大的主机 Tensor。只有 prompt 最后一批和每个
      ## decode token 的输出会进入采样器。
      let seqLen = ids.len
      let totalLen = pastLen + seqLen
      if g.contextLength > 0 and totalLen > g.contextLength:
        raiseIsvikError(
          ecInvalidParameter,
          "The token sequence exceeds the model context length",
          "totalLen=" & $totalLen & " contextLength=" & $g.contextLength
        )

      if g.layout == mlMonolithicTokenCausalLm:
        var tokenData = newSeq[int64](ids.len)
        for i, value in ids:
          tokenData[i] = int64(value)
        g.runtime.setInputByName(lmRequest, PortInputIds,
          newTensor(etI64, [1, ids.len], tokenData))
      else:
        let embeds = g.runEmbeddings(ids)
        g.runtime.setInputByName(lmRequest, PortInputsEmbeds, embeds)

        if g.usesPerLayer:
          let ple = g.runPerLayerEmbeddings(ids)
          g.runtime.setInputByName(lmRequest, PortPerLayerInputs, ple)

      if g.usesTokenTypeIds:
        # 当前 text-only 路径的每个物理 token 都属于 segment 0。未来多模态
        # 路径必须传入真实的 1/2 segment 标记，不能继续沿用全零占位。
        g.runtime.setInputByName(lmRequest, PortTokenTypeIds,
          newTensor(etI64, [1, seqLen], newSeq[int64](seqLen)))

      # attention_mask 覆盖累计长度（包括 InferRequest 内部 KV cache），
      # position_ids 只覆盖本物理批次。
      let maskLen =
        if g.usesStaticNpuShape: g.contextLength
        else: totalLen
      if maskLen <= 0 or totalLen > maskLen:
        raiseIsvikError(
          ecInvalidParameter,
          "The token sequence exceeds the model context length",
          "totalLen=" & $totalLen & " contextLength=" & $g.contextLength
        )
      var maskData = newSeq[int64](maskLen)
      for i in 0 ..< totalLen:
        maskData[i] = 1
      g.runtime.setInputByName(lmRequest, PortAttentionMask,
        newTensor(etI64, [1, maskLen], maskData))

      var posData = newSeq[int64](seqLen)
      for i in 0 ..< seqLen:
        posData[i] = int64(pastLen + i)
      g.runtime.setInputByName(lmRequest, PortPositionIds,
        newTensor(etI64, [1, seqLen], posData))

      if usesBeamIdx:
        g.runtime.setInputByName(lmRequest, PortBeamIdx,
          newTensor(etI32, [1], @[0'i32]))

      g.runtime.infer(lmRequest)
      if fetchLogits:
        result = g.runtime.getOutputByName(lmRequest, PortLogits)

    # llama.cpp 只为 prompt 最后位置请求 logits；当前 OpenVINO IR 没有等价的
    # per-token output flag，因此采用物理分块并且只读取最后一块。这样既保留
    # stateful KV cache 语义，也避免 `[1, fullPrompt, vocab]` 的超大单对象。
    var logits: Tensor = nil
    var promptOffset = 0
    while promptOffset < promptIds.len:
      let chunkEnd = min(promptOffset + prefillBatchTokens, promptIds.len)
      let chunkIds = promptIds[promptOffset ..< chunkEnd]
      logits = inferStep(chunkIds, promptOffset,
                         fetchLogits = chunkEnd == promptIds.len)
      promptOffset = chunkEnd

    var pastLen = promptIds.len
    for step in 0 ..< options.maxNewTokens:
      let choice =
        if greedyDecoding: greedyChoice(logits, options.bannedTokenIds)
        else: sampleChoice(logits, options.sampling, rng,
                           options.bannedTokenIds)

      if step == 0:
        firstTokenAt = epochTime()

      if g.defaults.isEos(choice.tokenId):
        reason = srEndOfSequence
        break

      generated.add(choice.tokenId)
      let fragment = g.vocab.decodeToken(choice.tokenId, decodeOptions)
      let visible = utf8.push(fragment)
      text.add(visible)

      if onStep != nil:
        let keepGoing = onStep(GenerationStep(
          index: step,
          tokenId: choice.tokenId,
          logit: choice.logit,
          textFragment: visible
        ))
        if not keepGoing:
          reason = srCancelled
          break

      # 当前采样出的 token 是下一次 LM 调用的唯一输入。最后一个允许生成的
      # token 不再做一次无用 infer。
      if step + 1 < options.maxNewTokens:
        logits = inferStep(@[choice.tokenId], pastLen, fetchLogits = true)
        inc pastLen
  finally:
    g.runtime.releaseInferRequest(lmRequest)

  text.add(utf8.flush())
  let finished = epochTime()

  result = GenerationResult(
    text: text,
    tokenIds: generated,
    promptTokenIds: promptIds,
    stopReason: reason,
    samplingSeed: seedUsed,
    promptTokens: promptIds.len,
    generatedTokens: generated.len,
    prefillBatchTokens: prefillBatchTokens,
    prefillMs:
      if firstTokenAt > 0.0: (firstTokenAt - started) * 1000.0 else: 0.0,
    decodeMs:
      if firstTokenAt > 0.0 and generated.len > 1:
        (finished - firstTokenAt) * 1000.0
      else:
        0.0,
    totalMs: (finished - started) * 1000.0
  )

proc generate*(g: TextGenerator, prompt: string,
              options: GenerationOptions = initGenerationOptions(),
              onStep: StepCallback = nil): GenerationResult =
  ## 从**已渲染好**的提示词文本生成。
  ##
  ## BOS 仅在 tokenizer_config.json 的 add_bos_token 允许时前置；id 来自
  ## generation_config.json。声明了 bos_token_id 不等于要求自动添加。
  g.requireOpen("generate")
  let bosId =
    if g.addBosToken and g.defaults.hasBos: g.defaults.bosTokenId
    else: -1
  let ids = g.tokenizerRef.encode(prompt, bosId)
  result = g.generateFromTokens(ids, options, onStep)

proc chat*(g: TextGenerator, messages: openArray[ChatMessage],
          options: GenerationOptions = initGenerationOptions(),
          onStep: StepCallback = nil): GenerationResult =
  ## 按模型自带的对话格式生成。
  ##
  ## 格式不被识别时抛 MODEL_UNSUPPORTED —— 见 `chat_format.nim` 的说明:
  ## 猜一个格式只会让输出静默变差。
  g.requireOpen("chat")
  let prompt = renderPrompt(g.chatFmt, messages, addGenerationPrompt = true)
  result = g.generate(prompt, options, onStep)

proc decodeTokens*(g: TextGenerator, ids: openArray[int],
                  skipSpecialTokens: bool = true): string =
  ## 把 token 序列解码成文本。供调用方自行处理 `tokenIds`。
  g.requireOpen("decodeTokens")
  g.vocab.decode(ids, initDecodeOptions(skipSpecialTokens = skipSpecialTokens))
