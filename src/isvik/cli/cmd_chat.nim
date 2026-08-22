## `isvik chat` —— 与模型对话
##
## 对应 Master Prompt §23(CLI)、§15/§17(推理编排)、§13(不伪造)。
##
## ---
##
## ## 两种用法
##
## ```text
## isvik chat                        交互式,进入 REPL
## isvik chat --prompt "你好"        单轮问答后退出(便于脚本)
## ```
##
## `--json` **只能**与 `--prompt` 一起用:交互式会话是多轮流式输出,
## 拼不成一个合法的 JSON 文档。硬要输出「每轮一个 JSON」会得到
## JSON Lines,那是另一种格式,不该用同一个开关表示。
##
## ---
##
## ## 模型从哪来
##
## 参数既接受**已导入的模型标识**(`isvik list` 里的 id),也接受**模型目录**。
## 判定顺序是「先看是不是存在的目录」——因为目录路径不可能与 id 冲突时
## 造成歧义,而反过来(先查库)会让一个恰好同名的 id 遮住用户给的路径。
##
## 不给参数时:库里恰好一个模型就用它;多个则**报错并列出 id**,不替用户挑。
##
## ---
##
## ## 架构约束(§23)
##
## 本模块不 import resonance / openvino,推理经 `Runtime` + `inference/`
## 编排层。由 `tests/architecture/tarchitecture.nim` 机械强制。
##
## ---
##
## ## 如实上报,不粉饰
##
## - 停止原因区分「自然结束」「达到上限」「模型未声明终止 token」三种,
##   后两者会让用户知道**输出可能不完整**,而不是以为模型答完了。
## - 每轮打印真实计时(首字延迟、解码速率)。这些是实测值,不是估算。
## - 只实现贪心解码。`/info` 会明确写出温度 / top-p / top-k **未实现**,
##   模型建议值仅作记录(§20.5.13 第 12 条)。
## - 非 CPU 设备上生成**未经验证**,`/info` 与启动横幅都会照实提示。

import std/[json, strutils, times]

import isvik/core/errors
import isvik/core/runtime
import isvik/backends/factory
import isvik/services/model_service
import isvik/services/device_service
import isvik/services/model_device_policy
import isvik/inference/chat_format
import isvik/inference/gen_defaults
import isvik/inference/tokenizer
import isvik/inference/text_generator
import isvik/cli/context
import isvik/cli/output
import isvik/cli/exit_codes

const
  ChatDefaultMaxTokens* = 512
    ## 单轮生成上限。比 `text_generator.DefaultMaxNewTokens`(256)大一些:
    ## 交互对话里 256 经常正好在一段话中间截断,而截断的输出比慢一点更糟。

  TokenizersDllEnvVar* = TokenizerExtensionEnvVar
    ## 兼容别名。真正的定义在 `inference/tokenizer`,那里同时住着查找逻辑。

  SlashPrefix* = "/"

type
  ChatArgs = object
    model: string
    device: string
    deviceExplicit: bool
      ## 设备是否由 `--device` 显式指定。决定编译失败时**是否**回落到 CPU:
      ## 显式请求的设备不回落,否则「这个设备到底能不能跑」永远得不到答案。
    maxTokens: int
    system: string
    prompt: string
    stream: bool
    plain: bool
    extension: string

proc initChatArgs(defaultDevice: string): ChatArgs =
  ChatArgs(
    model: "",
    device: defaultDevice,
    deviceExplicit: false,
    maxTokens: ChatDefaultMaxTokens,
    system: "",
    prompt: "",
    stream: true,
    plain: false,
    extension: ""
  )

# ---------------------------------------------------------------------------
# 扩展库定位
# ---------------------------------------------------------------------------

proc resolveExtensionPath*(explicit: string, modelDir: string): string =
  ## 找 `openvino_tokenizers.dll`。
  ##
  ## 策略已下沉到 `inference/tokenizer.resolveExtensionLibrary`,让 CLI 与
  ## HTTP Server 用同一条查找顺序。这里保留原名以免改动既有调用点。
  resolveExtensionLibrary(explicit, modelDir)

# ---------------------------------------------------------------------------
# 模型定位
# ---------------------------------------------------------------------------

proc raiseUnresolved*(ctx: CliContext, res: ModelResolution) =
  ## 把 Model Service 的解析失败渲染成界面语言的错误。
  ##
  ## 策略在服务层,文案在这里:服务不 import i18n,因为同一种失败在 CLI 与
  ## HTTP 上该说的话不一样(§20.5.10 只要求逻辑不重复,不要求文案统一)。
  case res.status
  of mrsResolved:
    discard
  of mrsNotFound:
    raiseIsvikError(
      ecModelNotFound,
      ctx.t("chat.modelNotFound", [res.requested]),
      "requested=" & res.requested
    )
  of mrsStoreEmpty:
    raiseIsvikError(
      ecModelNotFound,
      ctx.t("chat.noModel"),
      "modelDirectory=" & res.rootDirectory
    )
  of mrsAmbiguous:
    # 不替用户挑。随便选一个会让「我明明想用另一个」这种困惑很难排查。
    raiseIsvikError(
      ecInvalidParameter,
      ctx.t("chat.multipleModels", [$res.ids.len, res.ids.join(", ")]),
      "ids=" & res.ids.join(",")
    )
  of mrsIndexOutOfRange:
    raiseIsvikError(
      ecInvalidParameter,
      ctx.t("workbench.modelIndexNotFound",
            [res.requested, $res.ids.len]),
      "requested=" & res.requested & " count=" & $res.ids.len
    )

proc resolveModelReference*(ctx: CliContext, requested: string):
    ModelResolution =
  ## 保留规范 model id，供 manifest-aware 设备策略使用。
  let svc = newModelService(ctx.paths, ctx.settings)
  result = svc.resolveReference(requested)
  ctx.raiseUnresolved(result)

proc resolveModelDir*(ctx: CliContext, requested: string):
    tuple[dir: string, label: string] =
  ## 兼容只需要目录与显示名的调用方。
  let res = resolveModelReference(ctx, requested)
  result = (res.directory, res.label)

# ---------------------------------------------------------------------------
# 展示
# ---------------------------------------------------------------------------

proc stopReasonText(ctx: CliContext, reason: StopReason): string =
  case reason
  of srEndOfSequence: ctx.t("chat.stop.eos")
  of srMaxTokens: ctx.t("chat.stop.maxTokens")
  of srNoEosDeclared: ctx.t("chat.stop.noEos")
  of srCancelled: ctx.t("chat.stop.cancelled")

proc msText(value: float): string =
  ## 毫秒取整成字符串。
  ##
  ## 不用 `formatFloat(v, ffDecimal, 0)`:那会产出 `993.` 这种带尾点的形式。
  if value <= 0.0: "0" else: $int(value + 0.5)

proc deviceFromDetail*(detail, fallback: string): string =
  ## 从错误 detail 里取出**实际尝试**的设备名。
  ##
  ## 请求 `AUTO` 时用户真正需要知道的是「AUTO 挑中了谁、在谁上面失败了」——
  ## 提示他「显式加 --device AUTO」毫无帮助。detail 的形状由 ov_backend 的
  ## guardOv 上下文决定,含 `device=<rawName>`。
  ##
  ## 解析失败就回落到用户请求的值:宁可少说,不要说错。
  const marker = "device="
  let at = detail.find(marker)
  if at < 0:
    return fallback
  var i = at + marker.len
  var value = ""
  while i < detail.len and detail[i] notin {' ', '\t'}:
    value.add(detail[i])
    inc i
  if value.len == 0: fallback else: value

proc statsLine*(ctx: CliContext, r: GenerationResult): string =
  ## 一行紧凑的真实计时。
  ##
  ## 只生成 1 个 token 时**不报速率**:那时 decodeMs 为 0,算出来的
  ## 「tok/s」是个凭空造出来的数字(§35 不得声称未采集到的指标)。
  let tokens = $r.generatedTokens
  let prefill = msText(r.prefillMs)
  let reason = stopReasonText(ctx, r.stopReason)
  if r.generatedTokens > 1 and r.decodeMs > 0.0:
    let rate = formatFloat(
      float(r.generatedTokens - 1) / (r.decodeMs / 1000.0), ffDecimal, 1)
    ctx.t("chat.stats", [tokens, prefill, rate, reason])
  else:
    ctx.t("chat.statsNoRate", [tokens, prefill, reason])

proc printSessionInfo(ctx: CliContext, gen: TextGenerator, args: ChatArgs,
                     label, dir, systemPrompt: string) =
  let d = gen.generationDefaults()
  echo kvLine(ctx.t("chat.field.model"), label)
  echo kvLine(ctx.t("chat.field.directory"), dir)
  echo kvLine(ctx.t("chat.field.device"), gen.device)
  echo kvLine(ctx.t("chat.field.tokenizerDevice"), TokenizerDevice)
  echo kvLine(ctx.t("chat.field.hidden"), $gen.hiddenSize)
  if gen.usesPerLayerInputs():
    let s = gen.perLayerShape()
    echo kvLine(ctx.t("chat.field.perLayer"),
                $s.layers & " x " & $s.dim)
  else:
    echo kvLine(ctx.t("chat.field.perLayer"), ctx.t("common.no"))
  echo kvLine(ctx.t("chat.field.format"),
              (if args.plain: $cfPlain else: $gen.chatFormat()))
  echo kvLine(ctx.t("chat.field.eos"),
              (if d.hasEos: $d.eosTokenIds else: ctx.t("common.none")))
  echo kvLine(ctx.t("chat.field.maxTokens"), $args.maxTokens)
  if systemPrompt.len > 0:
    echo kvLine(ctx.t("chat.field.system"), systemPrompt)
  echo kvLine(ctx.t("chat.field.sampling"), ctx.t("chat.samplingGreedy"))
  # tokenizer 被钉在 CPU 是个会让人意外的事实,必须说出来而不是藏着 ——
  # 否则用户看到「设备 NPU」会以为整条管线都在 NPU 上。
  if not gen.device.startsWith(TokenizerDevice):
    echo "  " & ctx.t("chat.tokenizerOnCpu")
  # 只在 CPU 之外提示:CPU 上的生成本项目已实测,其余设备没有证据(§13)。
  if not gen.device.startsWith("CPU"):
    echo "  " & ctx.t("chat.notVerifiedOnDevice")

proc printSlashHelp(ctx: CliContext) =
  echo ctx.t("chat.help.title")
  echo kvLine("/exit, /quit", ctx.t("chat.help.exit"), 16)
  echo kvLine("/new", ctx.t("chat.help.new"), 16)
  echo kvLine("/history", ctx.t("chat.help.history"), 16)
  echo kvLine("/info", ctx.t("chat.help.info"), 16)
  echo kvLine("/system [文本]", ctx.t("chat.help.system"), 16)
  echo kvLine("/help", ctx.t("chat.help.cmd"), 16)

# ---------------------------------------------------------------------------
# 单轮生成
# ---------------------------------------------------------------------------

proc buildMessages(system: string,
                  history: seq[ChatMessage]): seq[ChatMessage] =
  ## 组装送给模板的消息序列。系统提示每次都放在最前 ——
  ## 它不是历史的一部分,而是整段对话的前置条件。
  result = @[]
  if system.len > 0:
    result.add(ChatMessage(role: crSystem, content: system))
  for m in history:
    result.add(m)

proc runTurn(ctx: CliContext, gen: TextGenerator, args: ChatArgs,
            format: ChatFormat, system: string,
            history: var seq[ChatMessage]): GenerationResult =
  ## 跑一轮生成,并把结果追加进历史。
  ##
  ## 每轮都重新渲染**完整**对话再送进模型:KV-cache 是模型内部状态且无法
  ## 跨 InferRequest 复用(state API 在本机运行时缺失),所以多轮的代价是
  ## 每轮重新预填充。这是当前 C API 下唯一正确的做法,不是疏漏。
  ##
  ## `cfPlain` 只送**最后一条**用户输入:基座模型的续写没有多轮结构,
  ## 把历史拼进去等于凭空发明一种它没见过的格式。
  let options = initGenerationOptions(maxNewTokens = args.maxTokens)

  if args.stream and not ctx.isJson:
    var streamed = ""
    proc onStep(step: GenerationStep): bool =
      if step.textFragment.len > 0:
        stdout.write(step.textFragment)
        # 必须逐片刷新,否则「流式」只是在最后一次性吐出来。
        stdout.flushFile()
        streamed.add(step.textFragment)
      true
    result =
      if format == cfPlain:
        gen.generate(history[^1].content, options, onStep)
      else:
        gen.chat(buildMessages(system, history), options, onStep)
    # 末尾可能还有被 UTF-8 缓冲扣住的片段,由 result.text 补齐。
    if result.text.len > streamed.len:
      stdout.write(result.text[streamed.len .. ^1])
    stdout.write("\n")
    stdout.flushFile()
  else:
    result =
      if format == cfPlain:
        gen.generate(history[^1].content, options)
      else:
        gen.chat(buildMessages(system, history), options)

  history.add(ChatMessage(role: crAssistant, content: result.text))

# ---------------------------------------------------------------------------
# 交互循环
# ---------------------------------------------------------------------------

proc runInteractive(ctx: CliContext, gen: TextGenerator, args: ChatArgs,
                   format: ChatFormat, label, dir: string): int =
  var system = args.system
  var history: seq[ChatMessage] = @[]

  echo ""
  printSessionInfo(ctx, gen, args, label, dir, system)
  if args.plain:
    echo "  " & ctx.t("chat.plainNote")
  echo ""
  echo "  " & ctx.t("chat.hint.help")
  echo ""

  while true:
    stdout.write("> ")
    stdout.flushFile()

    var line: string
    try:
      line = stdin.readLine()
    except EOFError:
      # 管道输入读完,或用户按了 Ctrl+Z / Ctrl+D。正常结束,不是错误。
      echo ""
      echo ctx.t("chat.bye")
      return ExitSuccess

    let input = line.strip()

    if input.len == 0:
      continue

    if input.startsWith(SlashPrefix):
      let parts = input.split(' ', maxsplit = 1)
      let cmd = parts[0].toLowerAscii()
      let rest = if parts.len > 1: parts[1].strip() else: ""
      case cmd
      of "/exit", "/quit", "/q":
        echo ctx.t("chat.bye")
        return ExitSuccess
      of "/new", "/clear", "/reset":
        history = @[]
        echo ctx.t("chat.cleared")
      of "/history":
        if history.len == 0:
          echo ctx.t("chat.historyEmpty")
        else:
          echo ctx.t("chat.historyTitle", [$history.len])
          for m in history:
            echo "  [" & $m.role & "] " & m.content
      of "/info":
        printSessionInfo(ctx, gen, args, label, dir, system)
      of "/system":
        system = rest
        echo (if system.len > 0: ctx.t("chat.systemSet")
              else: ctx.t("chat.systemCleared"))
      of "/help", "/?":
        printSlashHelp(ctx)
      else:
        echo ctx.t("chat.unknownSlash", [parts[0]])
      echo ""
      continue

    history.add(ChatMessage(role: crUser, content: input))
    echo ""

    try:
      let r = runTurn(ctx, gen, args, format, system, history)
      echo ""
      echo "  " & statsLine(ctx, r)
    except IsvikError as e:
      # 一轮失败不该终结整个会话 —— 用户可能只是问得太长。
      # 但历史里那条未被回答的 user 消息必须撤回,否则下一轮会带着它,
      # 让模型看到「用户连说两句、助手一句没说」这种训练时不存在的结构。
      if history.len > 0 and history[^1].role == crUser:
        history.setLen(history.len - 1)
      discard reportError(ctx, e)
      echo "  " & ctx.t("chat.turnError")
    echo ""

# ---------------------------------------------------------------------------
# 单轮模式
# ---------------------------------------------------------------------------

proc runOneShot(ctx: CliContext, gen: TextGenerator, args: ChatArgs,
               format: ChatFormat, label, dir: string): int =
  var history = @[ChatMessage(role: crUser, content: args.prompt)]
  if not ctx.isJson:
    echo ""
  let r = runTurn(ctx, gen, args, format, args.system, history)

  if ctx.isJson:
    emitJson(%*{
      "model": label,
      "directory": dir,
      "device": gen.device,
      "prompt": args.prompt,
      "text": r.text,
      "tokenIds": r.tokenIds,
      "promptTokens": r.promptTokens,
      "generatedTokens": r.generatedTokens,
      "stopReason": $r.stopReason,
      # 计时如实给出。§35:不得声称未采集到的指标,所以只报真实测到的三项。
      "timing": %*{
        "prefillMs": r.prefillMs,
        "decodeMs": r.decodeMs,
        "totalMs": r.totalMs
      },
      "sampling": "greedy",
      "chatFormat": $format
    })
    return ExitSuccess

  if not args.stream:
    echo r.text
  echo "  " & statsLine(ctx, r)
  result = ExitSuccess

# ---------------------------------------------------------------------------
# 参数解析与入口
# ---------------------------------------------------------------------------

proc parseChatArgs(ctx: CliContext, args: seq[string]):
    tuple[ok: bool, parsed: ChatArgs, exitCode: int] =
  var parsed = initChatArgs(ctx.settings.defaultDevice)
  var i = 0
  while i < args.len:
    let token = args[i]

    # `--prompt` 与 `--system` 的取值是**自由文本**,可能合法地以 `-` 开头
    # (例如 "--- 分隔线 ---"),因此对它们只要求「有下一个 token」。
    # 其余选项的取值是受限值域,保留「下一个 token 不能是选项」这道保护 ——
    # 否则 `isvik chat --device --json` 会把 "--json" 当成设备名。
    let freeText = token == "--prompt" or token == "--system"

    proc hasValue(): bool =
      i + 1 < args.len and (freeText or not args[i + 1].startsWith("--"))

    case token
    of "--no-stream":
      parsed.stream = false
      inc i
    of "--plain":
      parsed.plain = true
      inc i
    of "--device", "--max-tokens", "--system", "--prompt", "--extension":
      if not hasValue():
        return (false, parsed,
                reportUsageError(ctx, ctx.t("error.optionNeedsValue", [token])))
      let value = args[i + 1]
      case token
      of "--device":
        parsed.device = value
        parsed.deviceExplicit = true
      of "--extension": parsed.extension = value
      of "--system": parsed.system = value
      of "--prompt": parsed.prompt = value
      of "--max-tokens":
        try:
          parsed.maxTokens = parseInt(value)
        except ValueError:
          return (false, parsed,
                  reportUsageError(ctx, ctx.t("error.optionNeedsValue", [token])))
        if parsed.maxTokens <= 0:
          return (false, parsed,
                  reportUsageError(ctx, ctx.t("error.optionNeedsValue", [token])))
      else: discard
      inc i, 2
    else:
      if token.startsWith("-"):
        return (false, parsed,
                reportUsageError(ctx, ctx.t("error.unknownOption", [token])))
      if parsed.model.len > 0:
        return (false, parsed, reportUsageError(ctx, ctx.t("chat.usage")))
      parsed.model = token
      inc i

  # `--json` 只能与 `--prompt` 搭配,理由见模块顶部。
  if ctx.isJson and parsed.prompt.len == 0:
    return (false, parsed,
            reportUsageError(ctx, ctx.t("chat.jsonNeedsPrompt")))

  result = (true, parsed, ExitSuccess)

proc runSession(ctx: CliContext, args: ChatArgs, device: string,
               resolved: tuple[dir: string, label: string],
               extPath: string): int =
  ## 一次完整会话,自带 Runtime。
  ##
  ## Runtime 由本函数独占并在 finally 里关掉,因此回落到 CPU 重试时不会
  ## 留着上一次已加载的模型 —— 那可是几 GB 的驻留内存。
  let rt = newRuntime(newInferenceBackend())
  rt.initialize()
  var gen: TextGenerator = nil
  try:
    let started = epochTime()
    gen = newTextGenerator(rt, resolved.dir, extPath, device)
    if not ctx.isJson:
      echo ctx.t("chat.loaded",
                 [formatFloat(epochTime() - started, ffDecimal, 1)])

    # `--plain` 强制不套模板;否则用模型自带格式。格式不被识别时
    # `renderPrompt` 会抛 MODEL_UNSUPPORTED,而不是猜一个(见 chat_format)。
    let format = if args.plain: cfPlain else: gen.chatFormat()

    if args.prompt.len > 0:
      result = runOneShot(ctx, gen, args, format, resolved.label, resolved.dir)
    else:
      result = runInteractive(ctx, gen, args, format,
                              resolved.label, resolved.dir)
  finally:
    if gen != nil:
      gen.release()
    rt.shutdown()

proc isCpuRequest*(device: string): bool =
  ## 该请求是否已经就是 CPU。空串等价 AUTO,不算 CPU。
  device.strip().toUpperAscii().startsWith("CPU")

proc runChat(ctx: CliContext, args: ChatArgs): int =
  let resolution = resolveModelReference(ctx, args.model)
  let resolved = (dir: resolution.directory, label: resolution.label)
  let extPath = resolveExtensionPath(args.extension, resolved.dir)

  # AUTO 消费 manifest 中与当前 Backend 版本匹配的真实失败记录。
  # 显式 --device 不经过规划器，仍会照用户要求真实尝试。
  let models = newModelService(ctx.paths, ctx.settings)
  var plan = ModelDevicePlan(device: args.device)
  var attemptDevice = args.device
  if isAutoRequest(args.device):
    plan = planAutoDevice(models, resolution.id)
    attemptDevice = plan.device

  # JSON 模式下加载提示不能进 stdout,否则输出不再是合法 JSON。
  if not ctx.isJson:
    echo ctx.t("chat.loading")

  try:
    return runSession(ctx, args, attemptDevice, resolved, extPath)
  except IsvikError as e:
    # 回落判据既看原始请求，也看错误中真正失败的设备。规划已选到 CPU，或
    # 固定 CPU tokenizer 失败时，不能再执行一次 CPU→CPU 的无效重试。
    let attempted = deviceFromErrorDetail(e.detail, attemptDevice)
    if not allowsCpuFallback(e.code, args.device) or
        isCpuRequest(attempted):
      raise e

    if plan.backendVersion.len > 0:
      recordCompileFailure(
        models, resolution.id, attempted, e.msg,
        plan.backendName, plan.backendVersion)

    if ctx.isJson:
      stderr.writeLine(ctx.t("chat.deviceFallback", [attempted, e.msg]))
    else:
      echo ""
      echo "  " & ctx.t("chat.deviceFallback", [attempted, e.msg])
      echo "  " & ctx.t("chat.deviceFallbackHint", [attempted])
      echo ""

    var cpuArgs = args
    cpuArgs.device = DeviceRequestCpu
    result = runSession(
      ctx, cpuArgs, DeviceRequestCpu, resolved, extPath)

proc runChatCommand*(ctx: CliContext, args: seq[string]): int =
  let parsed = parseChatArgs(ctx, args)
  if not parsed.ok:
    return parsed.exitCode
  try:
    result = runChat(ctx, parsed.parsed)
  except IsvikError as e:
    result = reportError(ctx, e)
