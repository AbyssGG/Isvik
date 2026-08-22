## Isvik 常驻交互工作台
##
## 无参数启动进入这里。它保留传统 CLI 子命令用于脚本，同时为人在终端中的
## 连续操作提供一个不会每轮重建 Runtime 的工作区：模型只在 `-use` 或第一次
## 自然语言输入时加载，后续对话复用同一个 ChatSession。

import std/[strutils, times]

import isvik/version
import isvik/core/errors
import isvik/services/model_service
import isvik/services/device_service
import isvik/inference/chat_format
import isvik/inference/gen_defaults
import isvik/inference/text_generator
import isvik/services/chat_session
import isvik/cli/context
import isvik/cli/output
import isvik/cli/exit_codes
import isvik/cli/cmd_chat
import isvik/cli/cmd_models
import isvik/cli/cmd_devices
import isvik/cli/cmd_doctor
import isvik/cli/cmd_api

const IsvikAsciiArt = [
  " ___  ____  __     __ ___  _  __",
  "|_ _|/ ___| \\ \\   / /|_ _|| |/ /",
  " | | \\___ \\  \\ \\ / /  | | | ' /",
  " | |  ___) |  \\ V /   | | | . \\",
  "|___||____/    \\_/   |___||_|\\_\\"
]

type
  WorkbenchReadLine* = proc(line: var string): bool {.closure.}
  WorkbenchWrite* = proc(text: string) {.closure.}

  WorkbenchIo* = ref object
    ## 可注入的最小终端接口。真实 CLI 连接 stdin/stdout，测试可使用脚本输入。
    readLine*: WorkbenchReadLine
    write*: WorkbenchWrite
    writeLine*: WorkbenchWrite
    flush*: proc() {.closure.}

  WorkbenchCommandKind* = enum
    wcNatural, wcList, wcUse, wcStop, wcDevices, wcDoctor, wcServe, wcKey,
    wcInfo, wcImport, wcRemove, wcNew, wcHistory, wcSystem, wcLanguage,
    wcHelp, wcExit, wcUnknown

  WorkbenchCommand* = object
    kind*: WorkbenchCommandKind
    token*: string
    argument*: string

  WorkbenchState = object
    session: ChatSession
    selectedModel: string
    requestedDevice: string
    systemPrompt: string

proc consoleWorkbenchIo*(): WorkbenchIo =
  new(result)
  result.readLine = proc(line: var string): bool =
    try:
      stdin.readLine(line)
    except EOFError, IOError:
      false
  result.write = proc(text: string) = stdout.write(text)
  result.writeLine = proc(text: string) = stdout.writeLine(text)
  result.flush = proc() =
    try: stdout.flushFile()
    except IOError, OSError: discard

proc parseModelIndex*(value: string): int =
  ## 解析模型选择编号。支持 `1` 与列表中显示的 `[1]`；返回 0 表示不是编号。
  var raw = value.strip()
  if raw.len >= 3 and raw[0] == '[' and raw[^1] == ']':
    raw = raw[1 .. ^2].strip()
  if raw.len == 0:
    return 0
  for c in raw:
    if c notin {'0' .. '9'}:
      return 0
  try:
    result = parseInt(raw)
  except ValueError:
    return 0
  if result <= 0:
    result = 0

proc parseWorkbenchCommand*(line: string): WorkbenchCommand =
  ## 解析工作台的一行输入。命令大小写不敏感；非命令输入保持原文。
  let input = line.strip()
  if input.len == 0:
    return WorkbenchCommand(kind: wcNatural, argument: "")
  if input.startsWith("-- "):
    return WorkbenchCommand(kind: wcNatural, argument: input[3 .. ^1])
  if parseModelIndex(input) > 0:
    # `-ls` 显示 `[1]` 后，用户可以直接输入 `1` 或 `[1]` 选择模型。
    return WorkbenchCommand(kind: wcUse, token: input, argument: input)

  let parts = input.splitWhitespace(maxsplit = 1)
  let token = parts[0].toLowerAscii()
  let argument = if parts.len > 1: parts[1].strip() else: ""
  result = WorkbenchCommand(token: parts[0], argument: argument)

  case token
  of "-ls", "ls", "-models", "models", "/models": result.kind = wcList
  of "-use", "use", "-chat", "/use": result.kind = wcUse
  of "-stop", "/stop", "-unload": result.kind = wcStop
  of "stop":
    # 裸词 `stop` 只在单独输入时是命令。`stop talking about that` 是一句
    # 正常的话,把它当命令会造成与裸数字同类的隔离问题。
    if argument.len == 0:
      result.kind = wcStop
    else:
      result.kind = wcNatural
      result.argument = input
  of "-devices", "devices", "/devices": result.kind = wcDevices
  of "-doctor", "doctor", "/doctor": result.kind = wcDoctor
  of "-serve", "/serve", "-api": result.kind = wcServe
  of "-key", "-keys", "/key", "-apikey": result.kind = wcKey
  of "-info", "info", "/info": result.kind = wcInfo
  of "-import", "import": result.kind = wcImport
  of "-rm", "rm", "-remove": result.kind = wcRemove
  of "-new", "new", "/new", "/clear", "/reset": result.kind = wcNew
  of "-history", "history", "/history": result.kind = wcHistory
  of "-system", "/system": result.kind = wcSystem
  of "-lang", "lang", "-language": result.kind = wcLanguage
  of "-help", "help", "-h", "/help", "/?": result.kind = wcHelp
  of "-exit", "exit", "-quit", "quit", "/exit", "/quit", "/q":
    result.kind = wcExit
  else:
    if token.startsWith("-") or token.startsWith("/"):
      result.kind = wcUnknown
    else:
      result.kind = wcNatural
      result.argument = input

proc isBareModelIndex*(command: WorkbenchCommand): bool =
  ## 该命令是否来自「直接输入 1 或 [1]」而不是显式 `-use 1`。
  ##
  ## 显式 `-use` 的 token 是 `-use`，因此不会被误判 —— 用户写了 `-use`,
  ## 意图已经明确，不受下面的隔离规则影响。
  command.kind == wcUse and parseModelIndex(command.token) > 0

proc isNumericModelSelection*(command: WorkbenchCommand,
                              hasActiveSession: bool): bool =
  ## 裸数字只在**没有已加载模型**时才代表模型编号。
  ##
  ## 这是聊天内容与模型选择之间的隔离点,判据只有一个 —— 当前有没有会话:
  ##
  ## - 没有模型时,裸数字不可能是有意义的对话(还没有对象可聊),按编号处理。
  ## - 有模型时,模型经常让用户「选 1/2/3」,数字必须原样发给模型。
  ##
  ## 刻意不要求「先执行 -ls」:那个前置条件不可见,会让直接输入 `1` 的用户
  ## 意外触发按需加载并把 `1` 当成问题发出去。确实想把裸数字发给模型的话,
  ## 用 `-- 1` 转义。
  isBareModelIndex(command) and not hasActiveSession

proc normalizeLanguageChoice(value: string): string =
  case value.strip().toLowerAscii()
  of "1", "zh", "zh-cn", "cn", "中文": "zh-CN"
  of "2", "en", "en-us", "english": "en-US"
  else: ""

proc chooseStartupLanguage*(ctx: CliContext, io: WorkbenchIo): bool =
  ## 首次交互启动时选择并保存语言。EOF 表示非交互输入结束，不创建配置。
  if not ctx.needsLanguageSelection():
    return true

  io.writeLine(ctx.t("workbench.lang.title"))
  io.writeLine(ctx.t("workbench.lang.zh"))
  io.writeLine(ctx.t("workbench.lang.en"))
  while true:
    io.write(ctx.t("workbench.lang.prompt"))
    io.flush()
    var line: string
    if not io.readLine(line):
      return false
    let code = normalizeLanguageChoice(line)
    if code.len == 0:
      io.writeLine(ctx.t("workbench.lang.invalid"))
      continue
    ctx.persistLanguage(code)
    io.writeLine(ctx.t("workbench.lang.saved"))
    return true

proc printBanner(ctx: CliContext, io: WorkbenchIo, state: WorkbenchState) =
  io.writeLine("")
  for line in IsvikAsciiArt:
    io.writeLine(line)
  io.writeLine("ISVIK " & IsvikVersion & "  |  " & ctx.t("workbench.title"))
  io.writeLine(ctx.t("workbench.identity"))
  io.writeLine(ctx.t("workbench.status",
    [if state.selectedModel.len > 0: state.selectedModel else: ctx.t("common.none"),
     state.requestedDevice]))
  io.writeLine(ctx.t("workbench.startHint"))
  io.writeLine("")

proc printHelp(ctx: CliContext, io: WorkbenchIo) =
  io.writeLine(ctx.t("workbench.help.title"))
  io.writeLine(kvLine("-ls, -models", ctx.t("workbench.help.list"), 22))
  io.writeLine(kvLine("-use <#|id|dir>", ctx.t("workbench.help.use"), 22))
  io.writeLine(kvLine("-stop", ctx.t("workbench.help.stop"), 22))
  io.writeLine(kvLine("-devices", ctx.t("workbench.help.devices"), 22))
  io.writeLine(kvLine("-doctor", ctx.t("workbench.help.doctor"), 22))
  io.writeLine(kvLine("-serve [--port <n>]", ctx.t("workbench.help.serve"), 22))
  io.writeLine(kvLine("-key <cmd>", ctx.t("workbench.help.key"), 22))
  io.writeLine(kvLine("-info [id]", ctx.t("workbench.help.info"), 22))
  io.writeLine(kvLine("-import <dir>", ctx.t("workbench.help.import"), 22))
  io.writeLine(kvLine("-rm <id>", ctx.t("workbench.help.remove"), 22))
  io.writeLine(kvLine("-new", ctx.t("workbench.help.new"), 22))
  io.writeLine(kvLine("-history", ctx.t("workbench.help.history"), 22))
  io.writeLine(kvLine("-system [text]", ctx.t("workbench.help.system"), 22))
  io.writeLine(kvLine("-lang <zh|en>", ctx.t("workbench.help.lang"), 22))
  io.writeLine(kvLine("-help", ctx.t("workbench.help.help"), 22))
  io.writeLine(kvLine("-exit", ctx.t("workbench.help.exit"), 22))
  io.writeLine("")
  io.writeLine(ctx.t("workbench.help.natural"))
  io.writeLine(ctx.t("workbench.help.selection"))
  io.writeLine(ctx.t("workbench.help.escape"))

proc printSessionInfo(ctx: CliContext, io: WorkbenchIo, session: ChatSession) =
  if session == nil:
    io.writeLine(ctx.t("workbench.noActiveModel"))
    return
  let defaults = session.generationDefaults()
  io.writeLine(ctx.t("workbench.session.title"))
  io.writeLine(kvLine(ctx.t("chat.field.model"), session.model()))
  io.writeLine(kvLine(ctx.t("chat.field.directory"), session.directory()))
  io.writeLine(kvLine(ctx.t("chat.field.device"), session.device()))
  io.writeLine(kvLine(ctx.t("chat.field.tokenizerDevice"), TokenizerDevice))
  io.writeLine(kvLine(ctx.t("chat.field.hidden"), $session.hiddenSize()))
  if session.usesPerLayerInputs():
    let shape = session.perLayerShape()
    io.writeLine(kvLine(ctx.t("chat.field.perLayer"),
                        $shape.layers & " x " & $shape.dim))
  else:
    io.writeLine(kvLine(ctx.t("chat.field.perLayer"), ctx.t("common.no")))
  io.writeLine(kvLine(ctx.t("chat.field.format"), $session.chatFormat()))
  io.writeLine(kvLine(ctx.t("chat.field.eos"),
    if defaults.hasEos: $defaults.eosTokenIds else: ctx.t("common.none")))
  io.writeLine(kvLine(ctx.t("chat.field.maxTokens"), $session.maxNewTokens()))
  if session.systemPrompt().len > 0:
    io.writeLine(kvLine(ctx.t("chat.field.system"), session.systemPrompt()))
  io.writeLine(kvLine(ctx.t("chat.field.sampling"), ctx.t("chat.samplingGreedy")))
  if not session.device().startsWith(TokenizerDevice):
    io.writeLine("  " & ctx.t("chat.tokenizerOnCpu"))
  if not session.device().startsWith("CPU"):
    io.writeLine("  " & ctx.t("chat.notVerifiedOnDevice"))

proc shouldFallbackToCpu*(code: IsvikErrorCode,
                          requestedDevice: string): bool =
  ## 工作台只允许 AUTO 编译失败后回落。
  ##
  ## 判据住在 `services/device_service.allowsCpuFallback`,`isvik chat` 用的是
  ## 同一个:此前两处各写一遍且并不相同,同一个用户在两条路径上会看到不同
  ## 结果。本过程保留下来只为兼容既有调用与测试。
  allowsCpuFallback(code, requestedDevice)

proc resolveWorkbenchModel(ctx: CliContext, requested: string):
    tuple[dir: string, label: string] =
  ## 将工作台编号映射到与 `-ls` 相同的按 ID 排序序列。
  ## 非编号继续沿用目录优先、模型 ID 次之的旧解析规则。
  let index = parseModelIndex(requested)
  if index > 0:
    let res = newModelService(ctx.paths, ctx.settings).resolveIndex(index)
    ctx.raiseUnresolved(res)
    return (res.directory, res.label)
  result = resolveModelDir(ctx, requested)

proc selectModel(ctx: CliContext, io: WorkbenchIo,
                 state: var WorkbenchState, requested: string): bool =
  var resolved: tuple[dir: string, label: string]
  try:
    resolved = resolveWorkbenchModel(ctx, requested)
  except IsvikError as error:
    discard reportError(ctx, error)
    return false

  io.writeLine(ctx.t("chat.loading"))
  io.flush()
  let extensionPath = resolveExtensionPath("", resolved.dir)
  let started = epochTime()
  var candidate: ChatSession = nil
  try:
    try:
      candidate = openChatSession(
        resolved.dir, resolved.label, state.requestedDevice, extensionPath,
        ChatDefaultMaxTokens, state.systemPrompt)
    except IsvikError as error:
      let fallbackApplies =
        shouldFallbackToCpu(error.code, state.requestedDevice)
      if not fallbackApplies:
        raise error
      let attempted = deviceFromDetail(error.detail, state.requestedDevice)
      io.writeLine(ctx.t("chat.deviceFallback", [attempted, error.msg]))
      io.writeLine(ctx.t("workbench.deviceFallbackHint", [attempted]))
      candidate = openChatSession(
        resolved.dir, resolved.label, "CPU", extensionPath,
        ChatDefaultMaxTokens, state.systemPrompt)
  except IsvikError as error:
    discard reportError(ctx, error)
    return false

  if state.session != nil:
    state.session.close()
  state.session = candidate
  state.selectedModel = resolved.label
  io.writeLine(ctx.t("chat.loaded",
    [formatFloat(epochTime() - started, ffDecimal, 1)]))
  printSessionInfo(ctx, io, state.session)
  result = true

proc ensureSession(ctx: CliContext, io: WorkbenchIo,
                   state: var WorkbenchState): bool =
  if state.session != nil:
    return true
  result = selectModel(ctx, io, state, state.selectedModel)

proc runNaturalTurn(ctx: CliContext, io: WorkbenchIo,
                    state: var WorkbenchState, input: string) =
  if input.len == 0:
    return
  if not ensureSession(ctx, io, state):
    io.writeLine(ctx.t("workbench.selectHint"))
    return

  io.writeLine("")
  var streamed = ""
  proc onStep(step: GenerationStep): bool =
    if step.textFragment.len > 0:
      io.write(step.textFragment)
      io.flush()
      streamed.add(step.textFragment)
    true

  try:
    let generated = state.session.send(input, onStep)
    if generated.text.len > streamed.len:
      io.write(generated.text[streamed.len .. ^1])
    io.writeLine("")
    io.writeLine("  " & statsLine(ctx, generated))
  except IsvikError as error:
    discard reportError(ctx, error)
    io.writeLine("  " & ctx.t("chat.turnError"))
  io.writeLine("")

proc printHistory(ctx: CliContext, io: WorkbenchIo, session: ChatSession) =
  if session == nil or session.history().len == 0:
    io.writeLine(ctx.t("chat.historyEmpty"))
    return
  let messages = session.history()
  io.writeLine(ctx.t("chat.historyTitle", [$messages.len]))
  for message in messages:
    io.writeLine("  [" & $message.role & "] " & message.content)

proc splitWorkbenchArgs*(argument: string): seq[string] =
  ## 把工作台的一段参数文本切成 argv 形式。
  ##
  ## 刻意不做引号解析:工作台目前只需要 `--port 7317` 这类简单选项,
  ## 半套引号规则会让「看起来生效但实际切错」成为新的静默失败来源。
  result = @[]
  for part in argument.splitWhitespace():
    result.add(part)

proc runWorkbenchServe(ctx: CliContext, io: WorkbenchIo,
                       state: WorkbenchState, argument: string) =
  ## 在工作台内启动强制 API Key 的 Local API 服务。
  ##
  ## 复用 `isvik api serve` 的同一条实现,不在这里另起一套服务:协议翻译、
  ## 错误映射、SSE 与鉴权只应有一份。
  ##
  ## 服务在**前台**运行。刻意不放到后台线程:`server/http_server.serve` 的
  ## `{.cast(gcsafe).}` 以单线程为前提(§70 的线程模型尚未落地),开线程会让
  ## 那条断言不再成立,而症状是偶发的内存错误而不是明确失败。
  ##
  ## 「没有任何 Key 时自动生成一个」不在这里做 —— 那是 `cmd_serve` 的职责,
  ## 三条启动路径共用同一份行为,避免工作台与命令行给出不同结果。
  if state.session != nil:
    # 服务自带独立的 InferenceService,会再加载一份模型。4 GB 级模型上这不是
    # 小事,所以如实说明而不是悄悄占掉双份内存。
    io.writeLine(ctx.t("workbench.serve.modelLoaded", [state.session.model()]))

  io.writeLine(ctx.t("workbench.serve.foreground"))
  io.writeLine("")
  io.flush()
  discard runApiCommand(ctx, @["serve"] & splitWorkbenchArgs(argument))
  io.writeLine("")
  io.writeLine(ctx.t("workbench.serve.stopped"))

proc runWorkbench*(ctx: CliContext, ioArg: WorkbenchIo = nil): int =
  ## 运行常驻工作台。EOF 与 `-exit` 都是正常退出。
  let io = if ioArg == nil: consoleWorkbenchIo() else: ioArg
  if not chooseStartupLanguage(ctx, io):
    return ExitSuccess

  var state = WorkbenchState(
    session: nil,
    selectedModel: "",
    requestedDevice: ctx.settings.defaultDevice,
    systemPrompt: ""
  )
  printBanner(ctx, io, state)

  try:
    while true:
      let promptModel =
        if state.selectedModel.len > 0: state.selectedModel
        else: ctx.t("workbench.prompt.noModel")
      let promptDevice =
        if state.session != nil: state.session.device()
        else: state.requestedDevice
      io.write("isvik[" & promptModel & "@" & promptDevice & "]> ")
      io.flush()

      var line: string
      if not io.readLine(line):
        io.writeLine("")
        io.writeLine(ctx.t("workbench.bye"))
        return ExitSuccess

      var command = parseWorkbenchCommand(line)
      if isBareModelIndex(command) and
          not isNumericModelSelection(command, state.session != nil):
        # 已经有模型在跑时，裸数字还原成聊天内容：模型让用户「选 1/2/3」
        # 是常见情况，不能因此去重载模型。
        command.kind = wcNatural
        command.argument = line.strip()

      case command.kind
      of wcNatural:
        runNaturalTurn(ctx, io, state, command.argument)
      of wcList:
        discard runListCommand(ctx, @[])
      of wcUse:
        if command.argument.len == 0:
          io.writeLine(ctx.t("workbench.useNeedsModel"))
        else:
          discard selectModel(ctx, io, state, command.argument)
      of wcStop:
        if state.session == nil:
          io.writeLine(ctx.t("workbench.stopNoModel"))
        else:
          let stopped = state.session.model()
          state.session.close()
          state.session = nil
          state.selectedModel = ""
          io.writeLine(ctx.t("workbench.stopped", [stopped]))
      of wcDevices:
        discard runDevicesCommand(ctx, @[])
      of wcDoctor:
        discard runDoctorCommand(ctx, @[])
      of wcServe:
        runWorkbenchServe(ctx, io, state, command.argument)
      of wcKey:
        let keyArgs = splitWorkbenchArgs(command.argument)
        if keyArgs.len == 0:
          io.writeLine(ctx.t("workbench.key.usage"))
        else:
          discard runApiCommand(ctx, @["key"] & keyArgs)
      of wcInfo:
        if command.argument.len > 0:
          discard runInfoCommand(ctx, @[command.argument])
        else:
          printSessionInfo(ctx, io, state.session)
      of wcImport:
        if command.argument.len == 0:
          io.writeLine(ctx.t("workbench.importNeedsDirectory"))
        else:
          discard runImportCommand(ctx, @[command.argument])
      of wcRemove:
        if command.argument.len == 0:
          io.writeLine(ctx.t("workbench.removeNeedsModel"))
        else:
          discard runRemoveCommand(ctx, @[command.argument])
      of wcNew:
        if state.session != nil:
          state.session.clearHistory()
        io.writeLine(ctx.t("chat.cleared"))
      of wcHistory:
        printHistory(ctx, io, state.session)
      of wcSystem:
        state.systemPrompt = command.argument
        if state.session != nil:
          state.session.setSystemPrompt(state.systemPrompt)
        io.writeLine(if state.systemPrompt.len > 0: ctx.t("chat.systemSet")
                     else: ctx.t("chat.systemCleared"))
      of wcLanguage:
        let code = normalizeLanguageChoice(command.argument)
        if code.len == 0:
          io.writeLine(ctx.t("workbench.lang.usage"))
        else:
          try:
            ctx.persistLanguage(code)
            io.writeLine(ctx.t("workbench.lang.changed", [code]))
          except IsvikError as error:
            discard reportError(ctx, error)
      of wcHelp:
        printHelp(ctx, io)
      of wcExit:
        io.writeLine(ctx.t("workbench.bye"))
        return ExitSuccess
      of wcUnknown:
        io.writeLine(ctx.t("workbench.unknown", [command.token]))
  finally:
    if state.session != nil:
      state.session.close()
