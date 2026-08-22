## 常驻工作台：命令解析、首次语言选择和无模型交互回归测试
##
## 测试使用注入式 WorkbenchIo，不读取真实 stdin，也不触碰用户的 ~/.isvik。
## 无模型脚本只验证工作台控制流；真实生成仍由 inference 真机测试覆盖。

import std/[os, strutils, unittest]

import isvik/core/errors
import isvik/version
import isvik/config/paths
import isvik/config/settings
import isvik/cli/context
import isvik/cli/exit_codes
import isvik/cli/workbench

type
  ScriptTerminal = ref object
    lines: seq[string]
    nextLine: int
    output: string

var tempCounter = 0

proc tempRoot(label: string): string =
  inc tempCounter
  result = getTempDir() /
    ("isvik_workbench_" & label & "_" & $getCurrentProcessId() & "_" &
     $tempCounter)
  if dirExists(result):
    removeDir(result)

proc contextAt(root: string, extra: openArray[string] = []): CliContext =
  var args = @["--config", root]
  for value in extra:
    args.add(value)
  newCliContext(parseCliOptions(args))

proc newScriptTerminal(lines: openArray[string]): ScriptTerminal =
  new(result)
  result.lines = @lines
  result.nextLine = 0
  result.output = ""

proc ioFor(terminal: ScriptTerminal): WorkbenchIo =
  new(result)
  result.readLine = proc(line: var string): bool =
    if terminal.nextLine >= terminal.lines.len:
      return false
    line = terminal.lines[terminal.nextLine]
    inc terminal.nextLine
    true
  result.write = proc(text: string) =
    terminal.output.add(text)
  result.writeLine = proc(text: string) =
    terminal.output.add(text & "\n")
  result.flush = proc() = discard

suite "工作台命令解析":

  test "Linux 风格短命令与兼容别名映射到同一动作":
    for command in ["-ls", "ls", "-models", "/models"]:
      check parseWorkbenchCommand(command).kind == wcList
    for command in ["-use model", "-chat model", "/use model"]:
      let parsed = parseWorkbenchCommand(command)
      check parsed.kind == wcUse
      check parsed.argument == "model"
    for command in ["-devices", "-doctor", "-info", "-new", "-history",
                    "-help", "-exit", "/exit"]:
      check parseWorkbenchCommand(command).kind != wcUnknown
      check parseWorkbenchCommand(command).kind != wcNatural

  test "模型列表编号支持 1 和 [1],也可直接输入选择":
    check parseModelIndex("1") == 1
    check parseModelIndex("[1]") == 1
    check parseModelIndex("  [12]  ") == 12
    check parseModelIndex("0") == 0
    check parseModelIndex("[0]") == 0
    check parseModelIndex("model-id") == 0

    for line in ["1", "[2]"]:
      let direct = parseWorkbenchCommand(line)
      check direct.kind == wcUse
      check direct.argument == line

    let explicit = parseWorkbenchCommand("-use [3]")
    check explicit.kind == wcUse
    check explicit.argument == "[3]"

  test "裸数字的含义只取决于有没有已加载模型":
    # 隔离判据只有一个:当前有没有会话。
    #
    # 没有模型时数字必须能选模型 —— 曾经要求「先执行 -ls」,那个前置条件不
    # 可见,直接输入 `1` 会被当成问题发给按需加载的模型。
    # 有模型时数字必须发给模型 —— 模型经常让用户「选 1/2/3」。
    let bare = parseWorkbenchCommand("3")
    check isBareModelIndex(bare)
    check isNumericModelSelection(bare, hasActiveSession = false)
    check not isNumericModelSelection(bare, hasActiveSession = true)

    # 显式 -use 的 token 不是数字,因此永远不受该隔离影响。
    let explicit = parseWorkbenchCommand("-use 3")
    check not isBareModelIndex(explicit)
    check not isNumericModelSelection(explicit, hasActiveSession = true)

    check not isBareModelIndex(parseWorkbenchCommand("hello"))

    # 想把裸数字当成聊天内容发出去,用 `-- ` 转义。
    let escaped = parseWorkbenchCommand("-- 3")
    check escaped.kind == wcNatural
    check escaped.argument == "3"
    check not isBareModelIndex(escaped)

  test "-stop 与别名映射到停止动作,且不吃参数":
    for command in ["-stop", "stop", "/stop", "-unload"]:
      check parseWorkbenchCommand(command).kind == wcStop
    check parseWorkbenchCommand("-STOP").kind == wcStop
    # 「stop」作为自然语言的一部分不应被当成命令。
    check parseWorkbenchCommand("stop talking about that").kind == wcNatural

  test "普通文本直接作为自然语言,保留完整内容":
    let parsed = parseWorkbenchCommand("  explain local inference  ")
    check parsed.kind == wcNatural
    check parsed.argument == "explain local inference"

  test "双横线允许发送以命令字符开头的自然语言":
    let parsed = parseWorkbenchCommand("-- -this is a question")
    check parsed.kind == wcNatural
    check parsed.argument == "-this is a question"

  test "未知短命令不会误发给模型":
    let parsed = parseWorkbenchCommand("-does-not-exist")
    check parsed.kind == wcUnknown
    check parsed.token == "-does-not-exist"

  test "只有 AUTO 编译失败允许回落 CPU":
    check shouldFallbackToCpu(ecCompilationFailed, "AUTO")
    check shouldFallbackToCpu(ecCompilationFailed, " auto ")
    check not shouldFallbackToCpu(ecCompilationFailed, "GPU")
    check not shouldFallbackToCpu(ecCompilationFailed, "NPU")
    check not shouldFallbackToCpu(ecInferenceFailed, "AUTO")

suite "工作台语言选择":

  test "首次启动允许重试并持久化英文":
    let root = tempRoot("first_language")
    defer:
      if dirExists(root): removeDir(root)
    let ctx = contextAt(root)
    check ctx.needsLanguageSelection()

    let terminal = newScriptTerminal(["invalid", "2"])
    check chooseStartupLanguage(ctx, ioFor(terminal))
    check ctx.language == langEnUs
    check fileExists(ctx.paths.settingsFile)
    check loadSettings(ctx.paths.settingsFile).language == "en-US"
    check terminal.output.contains("Enter 1 or 2")
    check not ctx.needsLanguageSelection()

  test "显式 --lang 是临时覆盖,不会强制创建配置":
    let root = tempRoot("explicit_language")
    defer:
      if dirExists(root): removeDir(root)
    let ctx = contextAt(root, ["--lang", "en-US"])
    let terminal = newScriptTerminal([])
    check chooseStartupLanguage(ctx, ioFor(terminal))
    check terminal.nextLine == 0
    check not fileExists(ctx.paths.settingsFile)
    check ctx.language == langEnUs

  test "切换语言保留配置中的其他字段":
    let root = tempRoot("preserve_settings")
    defer:
      if dirExists(root): removeDir(root)
    let paths = newIsvikPaths(root)
    var initial = defaultSettings()
    initial.defaultDevice = "GPU"
    saveSettings(paths.settingsFile, initial)

    let ctx = contextAt(root)
    ctx.persistLanguage("en-US")
    let saved = loadSettings(paths.settingsFile)
    check saved.language == "en-US"
    check saved.defaultDevice == "GPU"
    check ctx.language == langEnUs

  test "切换前重读磁盘,保留工作台运行期间的外部修改":
    let root = tempRoot("external_update")
    defer:
      if dirExists(root): removeDir(root)
    let paths = newIsvikPaths(root)
    saveSettings(paths.settingsFile, defaultSettings())
    let ctx = contextAt(root)

    var externallyUpdated = loadSettings(paths.settingsFile)
    externallyUpdated.defaultDevice = "NPU"
    externallyUpdated.server.port = 8123
    saveSettings(paths.settingsFile, externallyUpdated)

    ctx.persistLanguage("en-US")
    let saved = loadSettings(paths.settingsFile)
    check saved.language == "en-US"
    check saved.defaultDevice == "NPU"
    check saved.server.port == 8123

  test "启动后配置被改坏时也拒绝覆盖":
    let root = tempRoot("broken_after_start")
    defer:
      if dirExists(root): removeDir(root)
    let paths = newIsvikPaths(root)
    saveSettings(paths.settingsFile, defaultSettings())
    let ctx = contextAt(root)
    let broken = "{ damaged while workbench is running"
    writeFile(paths.settingsFile, broken)

    expect IsvikError:
      ctx.persistLanguage("en-US")
    check readFile(paths.settingsFile) == broken
    check ctx.language == langZhCn

  test "配置损坏时拒绝覆盖原始字节":
    let root = tempRoot("broken_settings")
    defer:
      if dirExists(root): removeDir(root)
    let paths = newIsvikPaths(root)
    paths.ensureDirectories()
    let original = "{ broken json"
    writeFile(paths.settingsFile, original)

    let ctx = contextAt(root)
    check ctx.settingsLoadError.len > 0
    expect IsvikError:
      ctx.persistLanguage("en-US")
    check readFile(paths.settingsFile) == original

suite "无模型工作台":

  test "首次选择语言后可帮助、切换语言并正常退出":
    let root = tempRoot("script")
    defer:
      if dirExists(root): removeDir(root)
    let ctx = contextAt(root)
    let terminal = newScriptTerminal(["2", "-help", "-lang zh", "-exit"])

    check runWorkbench(ctx, ioFor(terminal)) == ExitSuccess
    check terminal.output.contains(" ___  ____  __     __ ___  _  __")
    check terminal.output.contains("|___||____/    \\_/   |___||_|\\_\\")
    check terminal.output.contains("ISVIK " & IsvikVersion & "  |  Local AI Workbench")
    check terminal.output.contains("-use <#|id|dir>")
    check terminal.output.contains("-stop")
    check terminal.output.contains("已退出 Isvik 工作台")
    check loadSettings(ctx.paths.settingsFile).language == "zh-CN"

  test "没有已加载模型时 -stop 明确说明无需停止,不报错退出":
    # -stop 是「离开模型」的显式出口。没有会话时它必须是无害的提示,
    # 而不是错误 —— 否则用户不敢用它来解除数字歧义。
    let root = tempRoot("stop_idle")
    defer:
      if dirExists(root): removeDir(root)
    let ctx = contextAt(root, ["--lang", "zh-CN"])
    let terminal = newScriptTerminal(["-stop", "-exit"])

    check runWorkbench(ctx, ioFor(terminal)) == ExitSuccess
    check terminal.output.contains("没有已加载的模型")
    check terminal.output.contains("已退出 Isvik 工作台")

  test "EOF 正常退出而不是阻塞或报错":
    let root = tempRoot("eof")
    defer:
      if dirExists(root): removeDir(root)
    let ctx = contextAt(root, ["--lang", "zh-CN"])
    let terminal = newScriptTerminal([])

    check runWorkbench(ctx, ioFor(terminal)) == ExitSuccess
    check terminal.output.contains("已退出 Isvik 工作台")
