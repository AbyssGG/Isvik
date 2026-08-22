## 推理应用服务(Master Prompt §20)
##
## ---
##
## ## 它补的是哪条断链
##
## `UnifiedInferenceRequest`(§20.5.3)此前**没有执行者**:
##
## ```text
## Protocol Adapter  →  UnifiedInferenceRequest  →  ???
## ```
##
## 于是 `request.device` 被解析出来却无人使用,`parameters.temperature` 等采样
## 字段同样无人消费。声明了字段却不实现,比不声明更糟 —— 客户端会按声明去用,
## 然后得到静默错误的结果(§20.5.13 第 12 条)。
##
## 本服务是那个执行者:
##
## ```text
## UnifiedInferenceRequest
##   ├─ requireValid          §20.5.3 的校验
##   ├─ validateDeviceRequest 设备名在入口就拒非法值
##   ├─ ModelService          model → 目录(策略只有一份)
##   ├─ InferenceParameters   → SamplingConfig
##   ├─ TextGenerator         解码,逐 token 发 ContentDelta
##   └─ UnifiedInferenceResult 含**实际**设备与真实 usage
## ```
##
## ---
##
## ## 为什么不复用 ChatSession
##
## `ChatSession` 持有**自己的**多轮历史,那是交互式前端(CLI 工作台)需要的。
## API 请求是无状态的:历史由请求携带。若强行复用,服务就得在每次请求前清空
## 并重放历史,而「服务里那份历史」会成为一个随时可能与请求不一致的影子状态。
##
## 两者共享的是下面这层:同一个 `TextGenerator` 可跨请求复用已编译模型。
##
## ---
##
## ## 已知未实现(如实标注,不假装支持)
##
## ```text
## tools / toolChoice        工具调用未接入解码
## responseFormat            结构化输出未约束解码
## stopSequences             只有 EOS 与 maxTokens 会停
## input(非对话)             embeddings 路径未接入
## batch > 1                 解码层固定 batch=1
## ```
##
## 这些在 `execute` 入口显式抛 `NOT_IMPLEMENTED`,而不是忽略字段继续跑。

import std/[options, strutils, tables]

import isvik/core/errors
import isvik/core/tools
import isvik/core/inference
import isvik/core/inference_events
import isvik/core/runtime
import isvik/backends/factory
import isvik/config/paths
import isvik/config/settings
import isvik/inference/chat_format
import isvik/inference/tool_calling
import isvik/inference/sampling
import isvik/inference/tokenizer
import isvik/inference/text_generator
import isvik/services/model_service
import isvik/services/device_service
import isvik/services/model_device_policy

type
  InferenceEventCallback* = proc (e: InferenceEvent): bool {.closure.}
    ## 每条事件调用一次。返回 false 表示调用方请求停止(客户端断开)。
    ##
    ## 用返回值而不是异常表达「停止」:客户端断开是**正常**结局,
    ## 不是错误(§20.5.4)。

  InferenceService* = ref object
    ## 一次性持有一个已加载模型的推理服务。
    ##
    ## 只缓存**一个**模型是有意的:一个 4GB 的模型驻留就已经占满常见配置的
    ## 内存预算,悄悄缓存多个会让「为什么内存涨到 16GB」难以解释。需要多模型
    ## 常驻时应显式扩展并同时给出内存说明,而不是默认行为。
    models: ModelService
    rt: Runtime
    generator: TextGenerator
    loadedDirectory: string
    loadedLabel: string
    loadedDevice: string
    defaultDevice: string
    extensionPath: string
    closed: bool

# ---------------------------------------------------------------------------
# 纯映射:不需要模型,可独立测试
# ---------------------------------------------------------------------------

proc toSamplingConfig*(p: InferenceParameters): SamplingConfig =
  ## 把统一请求的采样参数映射到解码侧配置。
  ##
  ## 两处刻意的取舍:
  ##
  ## 1. `temperature` 未指定时为 0,即**贪心**。不替客户端假设 1.0 ——
  ##    那会让「没说要随机」的请求变成随机的。
  ## 2. 但只给了 `top_p` / `top_k` 而没给 `temperature` 时,温度取 1.0。
  ##    否则那两个字段在贪心下完全无效,等于静默忽略客户端的请求。
  ##    1.0 是 softmax 的恒等缩放,不是编造的模型行为。
  let wantsTruncation = p.topP.isSome or p.topK.isSome
  let temperature =
    if p.temperature.isSome: p.temperature.get
    elif wantsTruncation: 1.0
    else: 0.0

  result = initSamplingConfig(
    temperature = temperature,
    topK = (if p.topK.isSome: p.topK.get else: 0),
    topP = (if p.topP.isSome: p.topP.get else: 0.0),
    seed = (if p.seed.isSome: int64(p.seed.get) else: 0),
    seedSpecified = p.seed.isSome
  )

proc resolveMaxTokens*(p: InferenceParameters,
                       fallback: int = DefaultMaxNewTokens): int =
  ## 决定本次生成的 token 上限。未指定时用调用方给的默认值。
  if p.maxTokens.isSome: p.maxTokens.get else: fallback

proc renderPart(part: ContentPart): string =
  ## 把一个内容片段渲染成提示词里的文本。
  ##
  ## 工具类片段用 `inference/tool_calling` 的信封形状,与模型当初被要求的
  ## 输出格式一致 —— 否则多轮工具对话里,模型会看到自己没说过的话。
  case part.kind
  of cpkText: part.text
  of cpkReasoning:
    # 推理内容不进提示词正文:它不是对话的一部分。
    ""
  of cpkToolUse: renderToolCallEnvelope(part.toolCall)
  of cpkToolResult: renderToolResultText(part.toolResult)

proc toChatMessages*(messages: seq[Message]): seq[ChatMessage] =
  ## 把统一消息映射到对话模板所需的形式。
  ##
  ## `chat_format.ChatRole` 刻意不含 tool 角色(工具回合的模板远比文本回合
  ## 复杂),因此 `mrTool` 消息以 **user 回合**的形式回去,内容带
  ## `isvik_tool_result` 标记说明来源。不把它伪装成普通用户发言:
  ## 模型需要知道这是工具的输出。
  result = @[]
  for msg in messages:
    let role =
      case msg.role
      of mrSystem: crSystem
      of mrUser: crUser
      of mrAssistant: crAssistant
      # 工具结果在对话结构上占的是「用户又说话了」这一格。
      of mrTool: crUser

    var content = ""
    for part in msg.content:
      let rendered = renderPart(part)
      if rendered.len == 0:
        continue
      # 文本片段**直接拼接**:它们是同一句话被切开的,插入分隔符会改变内容。
      # 工具信封是独立的一段,需要换行与前面的文本分开。
      if content.len > 0 and part.kind in {cpkToolUse, cpkToolResult}:
        content.add("\n")
      content.add(rendered)
    result.add(ChatMessage(role: role, content: content))

proc toUnifiedStopReason*(r: text_generator.StopReason): inference.StopReason =
  ## 解码侧终止原因 → 统一模型的终止原因。
  ##
  ## `srNoEosDeclared` 映射为 `max_tokens`:统一模型没有「模型未声明 EOS」
  ## 这一档,但两者对客户端的含义相同 —— **输出可能不完整**。把它说成
  ## `end_turn` 才是真正的失真。细节仍可从解码结果里查到。
  case r
  of text_generator.srEndOfSequence: inference.srEndTurn
  of text_generator.srMaxTokens: inference.srMaxTokens
  of text_generator.srNoEosDeclared: inference.srMaxTokens
  of text_generator.srCancelled: inference.srCancelled

proc requireSupported*(req: UnifiedInferenceRequest) =
  ## 拒绝本服务尚未实现的请求形态。
  ##
  ## 显式拒绝而不是忽略字段:客户端传了某个字段却什么都没发生,
  ## 会被理解成「模型不想那样做」,而事实是这条路径根本没实现。
  ##
  ## Tool Calling 现在**已接入**(提示词方案,见 `inference/tool_calling`),
  ## 因此不在拒绝列表里。
  if req.responseFormat.kind != rfkText:
    raiseIsvikError(
      ecNotImplemented,
      "Structured output is not implemented in the inference pipeline yet",
      "responseFormat=" & $req.responseFormat.kind
    )
  if req.parameters.stopSequences.len > 0:
    raiseIsvikError(
      ecNotImplemented,
      "Stop sequences are not implemented yet; only EOS and max_tokens stop",
      "stopSequences=" & $req.parameters.stopSequences.len
    )
  if req.parameters.presencePenalty.isSome or
      req.parameters.frequencyPenalty.isSome:
    raiseIsvikError(
      ecNotImplemented,
      "Presence and frequency penalties are not implemented yet",
      "reason=penalties-unsupported"
    )
  if req.input.strip().len > 0:
    raiseIsvikError(
      ecNotImplemented,
      "Raw input (non-chat) requests are not implemented yet",
      "reason=input-path-unsupported"
    )
  if req.messages.len == 0:
    raiseIsvikError(
      ecInvalidRequest,
      "Chat requests must provide at least one message",
      "reason=empty-messages"
    )

# ---------------------------------------------------------------------------
# 生命周期
# ---------------------------------------------------------------------------

proc newInferenceService*(paths: IsvikPaths, s: Settings): InferenceService =
  ## 构造服务。**不**加载任何模型 —— 加载发生在第一次 `execute` 或显式
  ## `load` 时,使构造本身不会因为环境问题失败。
  new(result)
  result.models = newModelService(paths, s)
  result.rt = nil
  result.generator = nil
  result.loadedDirectory = ""
  result.loadedLabel = ""
  result.loadedDevice = ""
  result.defaultDevice = normalizeDeviceRequest(s.defaultDevice)
  result.extensionPath = ""
  result.closed = false

proc modelService*(svc: InferenceService): ModelService = svc.models

proc isLoaded*(svc: InferenceService): bool =
  svc != nil and not svc.closed and svc.generator != nil

proc loadedModel*(svc: InferenceService): string =
  if svc == nil: "" else: svc.loadedLabel

proc loadedDevice*(svc: InferenceService): string =
  ## **实际**执行推理的设备,不是请求值。
  if svc == nil or svc.generator == nil: "" else: svc.generator.device()

proc defaultDevice*(svc: InferenceService): string =
  ## 兼容协议没有设备字段时使用的服务端默认设备。
  if svc == nil or svc.defaultDevice.len == 0:
    DeviceRequestAuto
  else:
    svc.defaultDevice

proc loadedDirectory*(svc: InferenceService): string =
  if svc == nil: "" else: svc.loadedDirectory

proc unload*(svc: InferenceService) =
  ## 卸载当前模型并释放内存。可重复调用。
  if svc == nil:
    return
  if svc.generator != nil:
    svc.generator.release()
    svc.generator = nil
  if svc.rt != nil:
    svc.rt.shutdown()
    svc.rt = nil
  svc.loadedDirectory = ""
  svc.loadedLabel = ""
  svc.loadedDevice = ""

proc close*(svc: InferenceService) =
  ## 关闭服务。可重复调用。
  if svc == nil or svc.closed:
    return
  svc.unload()
  svc.closed = true

proc requireOpen(svc: InferenceService, operation: string) =
  if svc == nil or svc.closed:
    raiseIsvikError(ecInvalidParameter, "Inference service is closed",
                    "operation=" & operation)

proc openGenerator(svc: InferenceService, directory, device: string):
    tuple[rt: Runtime, gen: TextGenerator] =
  ## 编译一个候选模型。失败时自身清理干净,调用方可以安全保留原模型。
  let rt = newRuntime(newInferenceBackend())
  rt.initialize()
  var gen: TextGenerator = nil
  try:
    gen = newTextGenerator(rt, directory, svc.extensionPath, device)
    result = (rt, gen)
  except CatchableError:
    if gen != nil:
      gen.release()
    rt.shutdown()
    raise

proc isDeviceCapacityFailure*(detail: string): bool =
  ## 这次推理失败是否属于**设备容量上界**,而不是输入或实现问题。
  ##
  ## 为什么要专门识别这一类:一次普通的推理失败(例如全部 token 被屏蔽)与设备
  ## 无关,拿它去判定「该设备不支持」是伪造结论。而下面这些是设备**能力**的
  ## 硬上界,与输入长度一起构成确定性的失败 —— 那是可以写进 manifest 的事实。
  ##
  ## 本机实测的形态(Intel iGPU,Gemma 4 E2B,约 7200 token 上下文):
  ##
  ## ```text
  ## [GPU] Exceeded max size of memory object allocation:
  ##   requested 7549747200 bytes, but max alloc size supported by device is
  ##   4294959104 bytes
  ## ```
  ##
  ## 7549747200 / 4 / 262144 = 7200 —— 正是 logits `[1, seq, vocab]` 的大小。
  ## iGPU 的单个内存对象上限是 4 GiB(2^32),长上下文的 logits 必然越界,
  ## 而 CPU 没有这个单对象上限(只受总内存限制)。
  let lower = detail.toLowerAscii()
  lower.contains("exceed_allocatable_mem_size") or
    lower.contains("exceeded max size of memory object allocation") or
    lower.contains("out of device memory") or
    lower.contains("cannot allocate memory")

proc capacityFailureCategory(detail: string): string =
  ## Manifest 只保存稳定类别，不保存可能含驱动路径、端口或大段插件文本的错误。
  let lower = detail.toLowerAscii()
  if lower.contains("exceed_allocatable_mem_size") or
      lower.contains("exceeded max size of memory object allocation"):
    "logits-object-limit"
  elif lower.contains("out of device memory"):
    "device-out-of-memory"
  else:
    "device-allocation-failed"

proc load*(svc: InferenceService, model: string,
           device: string = DeviceRequestAuto): string =
  ## 解析并加载模型,返回**实际**使用的设备。
  ##
  ## 已加载同一个「目录 + 设备」时直接复用,不重复编译 —— 编译一个 4GB 模型
  ## 要十几秒,每个请求都重来会让 API 无法使用。
  ##
  ## 只有 AUTO 允许在编译失败后改用 CPU(判据在 `device_service`)。
  ##
  ## AUTO 还会跳过**实测过**在当前 Backend 版本下编译失败的设备:动态 shape
  ## 的模型在 NPU 上必然失败,每次启动都重试一遍只是白等几秒并刷一屏
  ## OpenVINO 的 ERROR。
  svc.requireOpen("load")
  let requested =
    if device.strip().len == 0: svc.defaultDevice()
    else: device
  validateDeviceRequest(requested)

  let resolved = svc.models.resolveRequired(model)
  let normalized = normalizeDeviceRequest(requested)

  if svc.generator != nil and
      svc.loadedDirectory == resolved.directory and
      svc.loadedDevice == normalized:
    return svc.generator.device()

  if svc.extensionPath.len == 0:
    svc.extensionPath = resolveExtensionLibrary("", resolved.directory)

  # 只有 AUTO 才需要这些:显式请求照请求去试,用户应看到该设备真实的成败。
  var backend: tuple[name, version: string] = ("", "")
  var attemptDevice = normalized
  if isAutoRequest(normalized):
    let plan = planAutoDevice(svc.models, resolved.id)
    backend = (plan.backendName, plan.backendVersion)
    attemptDevice = plan.device

  var candidate: tuple[rt: Runtime, gen: TextGenerator]
  try:
    candidate = svc.openGenerator(resolved.directory, attemptDevice)
  except IsvikError as e:
    # 回落判据既看原始请求，也看真正失败的设备。规划已经选到 CPU，或固定
    # 在 CPU 的 tokenizer 编译失败时，不能再重复编译一次 CPU。
    let failedDevice = deviceFromErrorDetail(e.detail, attemptDevice)
    if not allowsCpuFallback(e.code, normalized) or
        semanticDeviceOf(failedDevice) == DeviceRequestCpu:
      raise e
    if backend.version.len > 0:
      recordCompileFailure(
        svc.models, resolved.id, failedDevice,
        e.msg, backend.name, backend.version)
    # 回落是**可解释的降级**,不是伪造:实际设备会如实回报为 CPU。
    candidate = svc.openGenerator(resolved.directory, DeviceRequestCpu)

  # 成功后才替换,使加载失败不会毁掉当前可用的模型。
  svc.unload()
  svc.rt = candidate.rt
  svc.generator = candidate.gen
  svc.loadedDirectory = resolved.directory
  svc.loadedLabel = resolved.label
  svc.loadedDevice = normalized
  result = svc.generator.device()

# ---------------------------------------------------------------------------
# 执行
# ---------------------------------------------------------------------------

proc execute*(svc: InferenceService, req: UnifiedInferenceRequest,
              onEvent: InferenceEventCallback = nil): UnifiedInferenceResult =
  ## 执行一次统一推理请求。
  ##
  ## 事件顺序与 §20.5.4 一致:`InferenceStarted` → 若干 `ContentDelta` →
  ## `UsageUpdated` → 终止事件(`Completed` / `Cancelled` / `Error`)。
  ## 非流式调用方忽略 `onEvent` 即可,结果仍由同一条路径产生 —— 不存在
  ## 「流式一套、非流式另一套」的第二实现。
  svc.requireOpen("execute")
  req.requireValid()
  req.requireSupported()
  validateDeviceRequest(req.device)

  proc emit(e: InferenceEvent): bool =
    if onEvent == nil: true else: onEvent(e)

  var actualDevice = ""
  try:
    actualDevice = svc.load(req.model, req.device)
  except IsvikError as e:
    discard emit(inferenceErrorFrom(e))
    raise e

  result = initUnifiedInferenceResult(req.model)
  result.device = actualDevice

  var messages = toChatMessages(req.messages)

  # 工具声明作为一条 system 指令注入到最前面。
  #
  # 放在最前而不是追加到末尾:对话模板按顺序渲染,末尾的 system 会出现在
  # 用户最后一句之后,模型看到的是「先问问题,再被告知有哪些工具」——
  # 那个顺序在训练数据里不存在。
  let toolInstructions = renderToolInstructions(req.tools, req.toolChoice)
  if toolInstructions.len > 0:
    messages.insert(ChatMessage(role: crSystem, content: toolInstructions), 0)

  var options = initGenerationOptions(
    maxNewTokens = resolveMaxTokens(req.parameters),
    sampling = toSamplingConfig(req.parameters)
  )

  if not emit(inferenceStarted(req.model, actualDevice)):
    # 还没开始就被取消:如实回报 cancelled,不去跑一次白费的推理。
    discard emit(inferenceCancelled("client stopped before generation"))
    result.stopReason = inference.srCancelled
    return

  var clientStopped = false

  proc onStep(step: GenerationStep): bool =
    # isCancelled 对 nil 令牌返回 false,不必先判空。
    if req.cancellation.isCancelled:
      return false
    if step.textFragment.len > 0:
      # 带工具的输出必须先经过信封提取。否则原始
      # `{\"isvik_tool_call\":...}` 会先作为正文流出，生成结束后又作为
      # 结构化 tool_call 流出，客户端会看到重复且互相冲突的内容。
      # 当前传输层本就会缓冲完整事件流，因此这里延迟到提取完成不会增加
      # 可观察延迟；真正逐 token 投递时应换成增量工具信封解析器。
      if req.tools.len == 0 and not emit(contentDelta(step.textFragment)):
        clientStopped = true
        return false
    true

  var generated: GenerationResult
  var produced = false

  proc onStepTracked(step: GenerationStep): bool =
    if step.textFragment.len > 0:
      produced = true
    onStep(step)

  try:
    generated = svc.generator.chat(messages, options, onStepTracked)
  except IsvikError as e:
    # **设备容量类失败可以救回来。** 本机的真实形态是:AUTO 选中 iGPU,
    # 短请求正常,而长上下文的 logits 一次性超过 GPU 的 4 GiB 单对象上限。
    # CPU 没有这个上界,所以同一个请求在 CPU 上是能跑的。
    #
    # 三个前提缺一不可:
    #
    # - **原始请求是 AUTO。** 显式指定设备就该看到该设备真实的失败。
    # - **还没产出任何 token。** 这个错误发生在 prefill,通常一个 token 都没
    #   发出去;若已经流式送出了内容,换设备重跑会让客户端看到重复的文本。
    # - **当前不是 CPU。** 已经在 CPU 上失败就没有下一级可退。
    let capacity = isDeviceCapacityFailure(e.detail)
    let canRetry = capacity and isAutoRequest(normalizeDeviceRequest(req.device)) and
      not produced and not actualDevice.toUpperAscii().startsWith("CPU")

    if not canRetry:
      discard emit(inferenceErrorFrom(e))
      raise e

    # 记录诊断事实，但不把请求长度相关的容量失败当作模型级不支持；
    # 否则一次长请求会让后续本可运行的短请求也永久绕开加速器。
    # `planAutoDevice` 在这里用于取得与记录绑定的 Backend 身份。
    let modelId = svc.models.resolveReference(req.model).id
    let plan = planAutoDevice(svc.models, modelId)
    if plan.backendVersion.len > 0:
      recordCapacityFailure(
        svc.models, modelId, semanticDeviceOf(actualDevice),
        capacityFailureCategory(e.detail),
        plan.backendName, plan.backendVersion)

    try:
      # 强制换到 CPU 重新编译并重跑。回落是**可解释的降级**:结果里的 device
      # 会如实变成 CPU。
      actualDevice = svc.load(req.model, DeviceRequestCpu)
      result.device = actualDevice
      generated = svc.generator.chat(messages, options, onStepTracked)
    except IsvikError as retryError:
      discard emit(inferenceErrorFrom(retryError))
      raise retryError

  # 从输出里分离工具调用。未声明工具时这一步是空操作。
  var extraction: ToolCallExtraction
  try:
    extraction = extractToolCalls(generated.text, req.tools)
    extraction.checkToolChoiceSatisfied(req.toolChoice)
  except IsvikError as e:
    discard emit(inferenceErrorFrom(e))
    raise e

  result.content = @[]
  if extraction.text.len > 0:
    # 模型常在信封前后附一句解释,那部分仍然是给用户看的正文。
    result.content.add(textPart(extraction.text))
    # 无工具请求已经在 onStep 中逐片发过；带工具请求为了避免泄露原始信封，
    # 到提取完成后才发送清洗后的正文。
    if req.tools.len > 0:
      discard emit(contentDelta(extraction.text))
  for call in extraction.calls:
    # 事件顺序与流式一致:先 Started,参数再作为一整段 Delta 送出。
    # 这里参数是一次性拿到的(非流式解析),因此不拆片 —— 拆成假的增量
    # 会让「流式」看起来实现了而其实没有。
    discard emit(toolCallStarted(call.id, call.name))
    discard emit(toolCallDelta(call.id, call.argumentsText))
    result.content.add(toolUsePart(call))

  result.usage = Usage(inputTokens: generated.promptTokens,
                       outputTokens: generated.generatedTokens)
  result.stopReason =
    if extraction.hadCall:
      # 有工具调用时终止原因是 tool_use,而不是模型自己停下来的那个原因。
      # 客户端据此知道「该去执行工具并把结果送回来」。
      inference.srToolUse
    else:
      toUnifiedStopReason(generated.stopReason)
  # 这些耗时从编码后的模型执行入口开始，不包含 HTTP 解析、chat template
  # 渲染或 tokenizer；metadata 名称明确保持这一层的语义。
  result.metadata["prefill_ms"] = $generated.prefillMs
  result.metadata["decode_ms"] = $generated.decodeMs
  result.metadata["total_ms"] = $generated.totalMs
  result.metadata["prefill_batch_tokens"] = $generated.prefillBatchTokens
  result.metadata["tool_instruction_chars"] = $toolInstructions.len

  # 采样 seed 如实回报,使「同样的请求为什么输出不同」可以被复查。
  if generated.samplingSeed != 0:
    result.metadata["sampling_seed"] = $generated.samplingSeed

  discard emit(usageUpdated(result.usage))

  if result.stopReason == inference.srCancelled:
    let reason =
      if req.cancellation.isCancelled:
        req.cancellation.cancelReason
      elif clientStopped: "client disconnected"
      else: "generation stopped by callback"
    discard emit(inferenceCancelled(reason))
    return

  discard emit(inferenceCompleted(result))
