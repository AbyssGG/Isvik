## Isvik CLI 入口
##
## ---
##
## ## 结构
##
## ```text
## main
##  ├─ parseCliOptions   剥离全局选项(--json / --verbose / --lang / --config)
##  ├─ newCliContext     建立上下文:paths + settings + i18n catalog
##  ├─ runWorkbench      无参数文本模式:常驻交互工作台
##  └─ dispatch          传统子命令与 JSON 帮助
## ```
##
## 全局选项在分发**之前**统一剥离,因此 `isvik --json devices` 与
## `isvik devices --json` 等价(见 `context.nim` 的说明)。
##
## ---
##
## ## 架构约束(§23)
##
## CLI 不得直接访问 OpenVINO。本文件及整个 `cli/` 目录禁止 import
## resonance / c_api / openvino,该约束由 `tests/architecture/tarchitecture.nim`
## 机械强制。需要真实 Backend 时经由 `backends/factory` 取抽象实例。
##
## ---
##
## ## 顶层异常处理
##
## `main` 把所有异常收敛成退出码,不让栈回溯打到用户脸上。
## 非 IsvikError 的意外异常单独一档:那是 Isvik 自己的 bug,
## 因此在 `--verbose` 下打印异常名与栈,便于报告问题。

import std/[os, json]

import isvik/version
import isvik/core/errors
import isvik/cli/console
import isvik/cli/context
import isvik/cli/output
import isvik/cli/exit_codes
import isvik/cli/cmd_config
import isvik/cli/cmd_devices
import isvik/cli/cmd_doctor
import isvik/cli/cmd_models
import isvik/cli/cmd_chat
import isvik/cli/cmd_serve
import isvik/cli/cmd_benchmark
import isvik/cli/cmd_api
import isvik/cli/workbench

proc tagline(ctx: CliContext): string =
  ## 一句话定位。按语言选择,不硬编码在 i18n 表里 ——
  ## 它是产品标识的一部分,权威来源是 version.nim。
  if ctx.language == langZhCn: IsvikDescriptionZhCn else: IsvikDescription

proc printVersion(ctx: CliContext) =
  ## 输出版本信息。版本号来自 isvik/version 这一唯一来源。
  if ctx.isJson:
    emitJson(%*{
      "product": IsvikProductName,
      "version": IsvikVersion,
      "nim": NimVersion,
      "cpu": hostCPU,
      "os": hostOS
    })
    return

  echo IsvikProductName & " " & IsvikVersion
  echo tagline(ctx)
  echo ctx.t("version.toolchain", [NimVersion, hostCPU, hostOS])

proc usageJson*(ctx: CliContext): JsonNode =
  ## 机器可解析的帮助。`isvik --json` 与 `isvik --json help` 都走这里，
  ## 不能把纯文本 usage 混进 JSON 管道。
  %*{
    "product": IsvikProductName,
    "version": IsvikVersion,
    "language": $ctx.language,
    "workbench": {
      "start": IsvikCliName,
      "description": ctx.t("usage.workbench")
    },
    "commands": [
      "version", "config path", "devices", "doctor", "list", "-ls",
      "info <id>", "import <dir>", "rm <id>", "chat [<id>]", "api", "help"
    ],
    "globalOptions": [
      "--json", "--verbose", "-v", "--lang <code>", "--config <dir>"
    ]
  }

proc printUsage(ctx: CliContext) =
  ## 输出帮助。命令与选项的描述全部来自 i18n,不在此处硬编码文案。
  if ctx.isJson:
    emitJson(ctx.usageJson())
    return

  echo IsvikProductName & " " & IsvikVersion & " —— " & tagline(ctx)
  echo ""
  echo ctx.t("usage.synopsis")
  echo "  " & IsvikCliName & "                 " & ctx.t("usage.workbench")
  echo "  " & IsvikCliName & " <command> [options]"
  echo ""
  echo ctx.t("usage.commands")
  echo kvLine("version", ctx.t("usage.cmd.version"), 16)
  echo kvLine("config path", ctx.t("usage.cmd.config"), 16)
  echo kvLine("devices", ctx.t("usage.cmd.devices"), 16)
  echo kvLine("doctor", ctx.t("usage.cmd.doctor"), 16)
  echo kvLine("list, -ls", ctx.t("usage.cmd.list"), 16)
  echo kvLine("info <id>", ctx.t("usage.cmd.info"), 16)
  echo kvLine("import <dir>", ctx.t("usage.cmd.import"), 16)
  echo kvLine("rm <id>", ctx.t("usage.cmd.rm"), 16)
  echo kvLine("chat [<id>]", ctx.t("usage.cmd.chat"), 16)
  echo kvLine("serve", ctx.t("usage.cmd.serve"), 16)
  echo kvLine("benchmark", ctx.t("usage.cmd.benchmark"), 16)
  echo kvLine("api", ctx.t("usage.cmd.api"), 16)
  echo kvLine("help", ctx.t("usage.cmd.help"), 16)
  echo ""
  echo ctx.t("usage.options")
  echo kvLine("--json", ctx.t("usage.opt.json"), 16)
  echo kvLine("--verbose, -v", ctx.t("usage.opt.verbose"), 16)
  echo kvLine("--lang <code>", ctx.t("usage.opt.lang"), 16)
  echo kvLine("--config <dir>", ctx.t("usage.opt.config"), 16)
  echo ""
  echo "  " & ctx.t("usage.exitCodes")

proc dispatch*(ctx: CliContext, args: seq[string]): int =
  ## 按子命令分发。args[0] 是命令名。
  ##
  ## 导出以便 CLI 测试直接调用,不必启动子进程。
  if args.len == 0:
    printUsage(ctx)
    return ExitSuccess

  let cmd = args[0]
  let rest = if args.len > 1: args[1 .. ^1] else: @[]

  case cmd
  of "version", "--version":
    printVersion(ctx)
    ExitSuccess
  of "config":
    runConfigCommand(ctx, rest)
  of "devices", "-devices":
    runDevicesCommand(ctx, rest)
  of "doctor", "-doctor":
    runDoctorCommand(ctx, rest)
  of "list", "ls", "-ls":
    runListCommand(ctx, rest)
  of "info", "-info":
    runInfoCommand(ctx, rest)
  of "import", "-import":
    runImportCommand(ctx, rest)
  of "rm", "remove", "-rm":
    runRemoveCommand(ctx, rest)
  of "chat", "run", "-chat":
    runChatCommand(ctx, rest)
  of "serve", "-serve":
    runServeCommand(ctx, rest)
  of "benchmark", "bench", "-benchmark":
    runBenchmarkCommand(ctx, rest)
  of "api", "-api":
    runApiCommand(ctx, rest)
  of "help", "--help", "-h":
    printUsage(ctx)
    ExitSuccess
  else:
    reportUsageError(ctx,
      ctx.t("error.unknownCommand", [cmd]) & " " &
      ctx.t("error.hint.help", [IsvikCliName]))

proc flushStreams() =
  ## 在返回前显式刷新 stdout / stderr。
  ##
  ## `exit()` 通常会替我们刷新 CRT 缓冲,所以这不是修某个已知缺陷,而是
  ## 让「输出完整」不依赖退出路径的实现细节:任何一条提前 `quit`、
  ## 任何一次异常收敛,都不该让已经写出的内容留在缓冲里。
  ##
  ## 刷新失败被吞掉:那通常意味着 stdout 已经关闭(例如下游管道先退出),
  ## 此时把 IOError 抛出去只会把一个无害的情况变成非零退出码。
  try:
    flushFile(stdout)
  except IOError, OSError:
    discard
  try:
    flushFile(stderr)
  except IOError, OSError:
    discard

proc waitBeforeClosing(ctx: CliContext, ranWorkbench: bool) =
  ## 双击启动且没有进入常驻工作台时,在关闭窗口前等用户读完输出。
  ## 工作台自己处理输入与退出,不能在 `-exit` 后再要求多按一次 Enter。
  ##
  ## 只在**双击**时暂停(判据见 `console.launchedByDoubleClick`)。从终端运行
  ## 时绝不暂停 —— 否则任何脚本调用都会挂住等一个永远不来的回车,那比
  ## 「窗口一闪而过」严重得多。
  ##
  ## `--json` 下也不暂停:那是给程序读的输出,后面追加提示文字会破坏它。
  if ranWorkbench:
    return
  if not launchedByDoubleClick():
    return
  if ctx != nil and ctx.isJson:
    return

  # ctx 为 nil 时(选项解析阶段就失败了)退化为不本地化的提示 ——
  # 总比让窗口直接消失好。
  proc line(key, fallback: string): string =
    if ctx != nil: ctx.t(key) else: fallback

  echo ""
  echo "  " & line("console.doubleClick.title", "Isvik could not enter the workbench")
  echo "  " & line("console.doubleClick.body",
                   "Read the error above, or run Isvik from a terminal.")
  echo ""
  echo "  " & line("console.doubleClick.example", "From PowerShell or cmd:")
  echo "    " & IsvikCliName
  echo ""
  echo "  " & line("console.doubleClick.pressEnter",
                   "Press Enter to close this window.")
  flushStreams()

  try:
    discard stdin.readLine()
  except EOFError, IOError:
    # 读不到输入(例如 stdin 被关闭)时直接退出,不能因为等不到回车而卡死。
    discard

proc shouldRunWorkbench*(options: CliOptions): bool =
  ## 只有人类文本模式的无参数调用进入常驻循环。
  ## `--json` 没有交互语义，必须返回机器可解析帮助而不是等待 stdin。
  options.rest.len == 0 and not options.json

proc main(): int =
  ## 返回进程退出码。
  #
  # 必须在任何输出之前切换控制台编码,否则中文会在 GBK 控制台下乱码。
  enableUtf8Console()

  var ctx: CliContext = nil
  var ranWorkbench = false
  # 顺序有讲究:先刷干净输出,再按需暂停等用户。反过来会让用户对着一个
  # 空窗口按回车。defer 是 LIFO,所以这里的注册顺序与执行顺序相反。
  defer: waitBeforeClosing(ctx, ranWorkbench)
  defer: flushStreams()

  try:
    let options = parseCliOptions(commandLineParams())
    ctx = newCliContext(options)
    if shouldRunWorkbench(options):
      result = runWorkbench(ctx)
      ranWorkbench = true
    else:
      result = dispatch(ctx, options.rest)
  except IsvikError as e:
    # ctx 可能仍为 nil(选项或语言解析阶段就失败了),
    # reportError 对 nil 上下文有退化路径。
    result = reportError(ctx, e)
  except CatchableError as e:
    # 走到这里说明是 Isvik 自己的 bug,不是用户输入问题。
    stderr.writeLine("Internal error: " & e.msg)
    if ctx != nil and ctx.isVerbose:
      stderr.writeLine("Exception: " & $e.name)
      stderr.writeLine(e.getStackTrace())
    result = ExitFailure

when isMainModule:
  quit(main())
