## CLI 测试:全局选项、退出码映射、上下文与命令分发
##
## ---
##
## ## 为什么不启动子进程
##
## 直接 import `isvik/cli/main` 并调用导出的 `dispatch`,比 `execProcess`
## 快得多,而且能在断言失败时给出 Nim 侧的栈。更关键的是 `src` 下禁止
## `osproc`(§0.5.4 由架构测试强制),测试里也没必要开这个口子。
##
## ---
##
## ## 涉及真实设备的命令怎么测
##
## `devices` / `doctor` 需要真实 Backend。这里**不断言它们的输出内容** ——
## 那取决于机器上有什么硬件。只断言:
##
## - 有 OpenVINO 时退出码为 0(命令能跑通)
## - 没有 OpenVINO 时不崩溃,而是给出可诊断的失败
##
## 真机上的设备语义由 `tests/backends/tdevice_real.nim` 断言。

import std/[unittest, os, strutils, json]

import isvik/core/errors
import isvik/config/paths
import isvik/cli/context
import isvik/cli/exit_codes
import isvik/cli/output
import isvik/cli/main
import isvik/backends/factory

var tmpCounter = 0

proc makeTempRoot(): string =
  inc tmpCounter
  result = getTempDir() / ("isvik_test_cli_" & $tmpCounter & "_" & $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)

proc contextWith(args: openArray[string]): CliContext =
  ## 用给定参数建立上下文,数据根目录指向一个独立临时目录 ——
  ## 测试绝不能碰到用户真实的 ~/.isvik。
  var full: seq[string] = @["--config", makeTempRoot()]
  for a in args:
    full.add(a)
  newCliContext(parseCliOptions(full))

# ---------------------------------------------------------------------------
# 全局选项
# ---------------------------------------------------------------------------

suite "全局选项解析":

  test "默认全部关闭,rest 为空":
    let o = parseCliOptions([])
    check not o.json
    check not o.verbose
    check o.lang == ""
    check o.configDir == ""
    check o.rest.len == 0

  test "布尔选项被识别":
    let o = parseCliOptions(["--json", "--verbose"])
    check o.json
    check o.verbose
    check o.rest.len == 0

  test "-v 是 --verbose 的短形式":
    check parseCliOptions(["-v"]).verbose

  test "带取值的选项支持空格与等号两种写法":
    check parseCliOptions(["--lang", "en-US"]).lang == "en-US"
    check parseCliOptions(["--lang=en-US"]).lang == "en-US"
    check parseCliOptions(["--config", "D:/x"]).configDir == "D:/x"
    check parseCliOptions(["--config=D:/x"]).configDir == "D:/x"

  test "位置参数被保留且顺序不变":
    let o = parseCliOptions(["config", "path"])
    check o.rest == @["config", "path"]

  test "全局选项可以出现在子命令前后,结果相同":
    # 这条是「--json 放哪里都有效」这个承诺的落实点。
    let before = parseCliOptions(["--json", "devices"])
    let after = parseCliOptions(["devices", "--json"])
    check before.json == after.json
    check before.rest == after.rest
    check before.rest == @["devices"]

  test "全局选项混在位置参数中间":
    let o = parseCliOptions(["config", "--json", "path"])
    check o.json
    check o.rest == @["config", "path"]

  test "未知选项原样留给子命令,不在这里报错":
    # 子命令可能有自己的选项,越权判断会挡住它们。
    let o = parseCliOptions(["devices", "--unknown-flag"])
    check o.rest == @["devices", "--unknown-flag"]

  test "缺少取值的选项抛 INVALID_PARAMETER":
    for args in [@["--lang"], @["--config"]]:
      var code: IsvikErrorCode
      try:
        discard parseCliOptions(args)
        check false
      except IsvikError as e:
        code = e.code
      check code == ecInvalidParameter

  test "取值位置是另一个选项时报错,不把选项当取值吞掉":
    # 否则 `isvik --lang --json` 会得到语言 "--json" 这种荒谬结果。
    var code: IsvikErrorCode
    try:
      discard parseCliOptions(["--lang", "--json"])
      check false
    except IsvikError as e:
      code = e.code
    check code == ecInvalidParameter

  test "等号形式取值为空时报错":
    var raised = false
    try:
      discard parseCliOptions(["--lang="])
    except IsvikError:
      raised = true
    check raised

suite "主入口模式选择":

  test "仅无参数文本模式进入工作台":
    check shouldRunWorkbench(parseCliOptions([]))
    check shouldRunWorkbench(parseCliOptions(["--lang", "en-US"]))
    check not shouldRunWorkbench(parseCliOptions(["--json"]))
    check not shouldRunWorkbench(parseCliOptions(["version"]))
    check not shouldRunWorkbench(parseCliOptions(["-ls"]))

  test "JSON 无命令时帮助本身是结构化对象":
    let ctx = contextWith(["--json"])
    let help = usageJson(ctx)
    check help.kind == JObject
    check help["product"].getStr == "Isvik"
    check help["workbench"]["start"].getStr == "isvik"
    check help["commands"].kind == JArray
    check help["globalOptions"].kind == JArray
    check dispatch(ctx, @[]) == ExitSuccess

# ---------------------------------------------------------------------------
# 退出码
# ---------------------------------------------------------------------------

suite "错误码到退出码":

  test "每个错误码都有映射,且都在已定义的取值内":
    let allowed = [ExitSuccess, ExitFailure, ExitUsage, ExitModel, ExitDevice,
                   ExitBackend, ExitExecution, ExitCache, ExitNotImplemented,
                   ExitCancelled]
    for code in IsvikErrorCode:
      check exitCodeFor(code) in allowed

  test "成功是 0,且没有任何错误码映射到 0":
    # 错误映射到 0 会让脚本以为成功了。
    check ExitSuccess == 0
    for code in IsvikErrorCode:
      check exitCodeFor(code) != ExitSuccess

  test "用法错误归 2,与 Unix 惯例一致":
    check exitCodeFor(ecInvalidRequest) == ExitUsage
    check exitCodeFor(ecInvalidParameter) == ExitUsage
    check ExitUsage == 2

  test "模型类归 3":
    check exitCodeFor(ecModelNotFound) == ExitModel
    check exitCodeFor(ecModelInvalid) == ExitModel
    check exitCodeFor(ecModelUnsupported) == ExitModel

  test "设备类归 4,三个设备错误码同组":
    check exitCodeFor(ecDeviceNotAvailable) == ExitDevice
    check exitCodeFor(ecNpuNotAvailable) == ExitDevice
    check exitCodeFor(ecGpuNotAvailable) == ExitDevice

  test "Backend 不可用单独一档,与设备类区分":
    # 「没装运行时」和「有运行时但没这个设备」需要完全不同的处理。
    check exitCodeFor(ecBackendNotAvailable) == ExitBackend
    check ExitBackend != ExitDevice

  test "执行类归 6":
    check exitCodeFor(ecCompilationFailed) == ExitExecution
    check exitCodeFor(ecInferenceFailed) == ExitExecution
    check exitCodeFor(ecToolCallFailed) == ExitExecution

  test "缓存类归 7":
    check exitCodeFor(ecCacheInvalid) == ExitCache
    check exitCodeFor(ecCacheCorrupted) == ExitCache

  test "未实现单独一档,不与失败混淆":
    # 重试「未实现」没有意义,脚本需要能区分。
    check exitCodeFor(ecNotImplemented) == ExitNotImplemented
    check ExitNotImplemented != ExitFailure

  test "取消沿用 128 + SIGINT 约定,不视为故障类":
    check exitCodeFor(ecStreamCancelled) == ExitCancelled
    check ExitCancelled == 130

  test "服务端错误归 1":
    check exitCodeFor(ecServerError) == ExitFailure

  test "异常重载与错误码重载一致":
    let e = newIsvikError(ecNpuNotAvailable)
    check exitCodeFor(e) == exitCodeFor(ecNpuNotAvailable)

  test "nil 异常视为成功,便于调用方无分支处理":
    let none: ref IsvikError = nil
    check exitCodeFor(none) == ExitSuccess

# ---------------------------------------------------------------------------
# 上下文
# ---------------------------------------------------------------------------

suite "CLI 上下文":

  test "默认语言为 zh-CN":
    let ctx = contextWith([])
    check ctx.language == langZhCn
    check ctx.t("error.prefix") == "错误"

  test "--lang 覆盖默认语言":
    let ctx = contextWith(["--lang", "en-US"])
    check ctx.language == langEnUs
    check ctx.t("error.prefix") == "Error"

  test "--lang 传非法值时报错,不静默回落":
    var code: IsvikErrorCode
    try:
      discard contextWith(["--lang", "de-DE"])
      check false
    except IsvikError as e:
      code = e.code
    check code == ecInvalidParameter

  test "--config 决定数据根目录":
    let root = makeTempRoot()
    let ctx = newCliContext(parseCliOptions(["--config", root]))
    check ctx.paths.root == normalizedPath(absolutePath(root))
    check ctx.rootSourceDescription() == ctx.t("config.source.explicit")
    check not ctx.usesDefaultRoot()

  test "构造上下文不创建任何目录":
    # `isvik version` 不该产生文件系统副作用。
    let root = makeTempRoot()
    discard newCliContext(parseCliOptions(["--config", root]))
    check not dirExists(root)

  test "配置文件不存在时用默认值,且不算读取失败":
    # 首次运行的正常路径。
    let ctx = contextWith([])
    check ctx.settingsLoadError == ""
    check ctx.settings.defaultDevice == "AUTO"
    check ctx.settings.language == "zh-CN"

  test "配置文件损坏时退化为默认值并记录原因,不让 CLI 不可用":
    # doctor 的存在前提:环境坏掉时它还得能跑。
    let root = makeTempRoot()
    let p = newIsvikPaths(root)
    p.ensureDirectories()
    writeFile(p.settingsFile, "{ this is not valid json")

    let ctx = newCliContext(parseCliOptions(["--config", root]))
    check ctx.settingsLoadError.len > 0
    check ctx.settingsLoadError.contains("INVALID_PARAMETER")
    check ctx.settings.defaultDevice == "AUTO"    # 退化为默认值
    check ctx.language == langZhCn                # 界面仍可用
    removeDir(root)

  test "配置里的语言被采用,命令行优先级更高":
    let root = makeTempRoot()
    let p = newIsvikPaths(root)
    p.ensureDirectories()
    writeFile(p.settingsFile, """{"language": "en-US"}""")

    check newCliContext(parseCliOptions(["--config", root])).language == langEnUs
    check newCliContext(parseCliOptions(
      ["--config", root, "--lang", "zh-CN"])).language == langZhCn
    removeDir(root)

  test "json 与 verbose 标记透传到上下文":
    let ctx = contextWith(["--json", "--verbose"])
    check ctx.isJson
    check ctx.isVerbose

# ---------------------------------------------------------------------------
# 输出排版
# ---------------------------------------------------------------------------

suite "输出排版":

  test "空表不输出表头":
    # 只有表头的表格没有信息量,反而让人以为「有列但没数据」。
    check renderTable(["A", "B"], @[]).len == 0

  test "非空表包含表头、分隔线与数据行":
    let lines = renderTable(["A", "BB"], @[@["1", "2"]])
    check lines.len == 3
    check lines[0].contains("A")
    check lines[0].contains("BB")
    check lines[1].contains("-")
    check lines[2].contains("1")

  test "列宽按最长单元格计算":
    let lines = renderTable(["A", "B"], @[@["longvalue", "x"]])
    check lines[2].contains("longvalue")
    # 分隔线宽度跟随该列实际宽度
    check lines[1].contains("-".repeat("longvalue".len))

  test "行尾不留多余空格":
    for line in renderTable(["A", "B"], @[@["1", "2"], @["333", "4"]]):
      check line == line.strip(leading = false, trailing = true)

  test "kvLine 按指定宽度填充标签":
    let line = kvLine("k", "v", 6)
    check line == "  k     v"

  test "标签超过宽度时不截断":
    check kvLine("verylonglabel", "v", 4) == "  verylonglabelv"

# ---------------------------------------------------------------------------
# 命令分发
# ---------------------------------------------------------------------------

suite "命令分发":

  test "无参数打印帮助并返回 0":
    check dispatch(contextWith([]), @[]) == ExitSuccess

  test "help 与 version 返回 0":
    let ctx = contextWith([])
    check dispatch(ctx, @["help"]) == ExitSuccess
    check dispatch(ctx, @["--help"]) == ExitSuccess
    check dispatch(ctx, @["-h"]) == ExitSuccess
    check dispatch(ctx, @["version"]) == ExitSuccess
    check dispatch(ctx, @["--version"]) == ExitSuccess

  test "version 的 JSON 形态可用":
    check dispatch(contextWith(["--json"]), @["version"]) == ExitSuccess

  test "Linux 风格短命令保留传统命令的退出语义":
    let root = makeTempRoot()
    let ctx = newCliContext(parseCliOptions(["--config", root]))
    check dispatch(ctx, @["-ls"]) == ExitSuccess
    check dispatch(ctx, @["ls"]) == ExitSuccess
    check dispatch(ctx, @["-info"]) == ExitUsage
    if dirExists(root): removeDir(root)

  test "未知命令返回 ExitUsage":
    check dispatch(contextWith([]), @["nosuchcommand"]) == ExitUsage

  test "未知子命令返回 ExitUsage":
    let ctx = contextWith([])
    check dispatch(ctx, @["config", "nosuchsub"]) == ExitUsage
    check dispatch(ctx, @["devices", "extra"]) == ExitUsage
    check dispatch(ctx, @["doctor", "extra"]) == ExitUsage

  test "config 无子命令时打印用法并返回 0":
    check dispatch(contextWith([]), @["config"]) == ExitSuccess

  test "config path 创建目录与配置文件":
    let root = makeTempRoot()
    let ctx = newCliContext(parseCliOptions(["--config", root]))
    check dispatch(ctx, @["config", "path"]) == ExitSuccess
    check dirExists(root)
    check fileExists(newIsvikPaths(root).settingsFile)
    removeDir(root)

  test "config path 的 JSON 形态可用":
    let root = makeTempRoot()
    let ctx = newCliContext(parseCliOptions(["--config", root, "--json"]))
    check dispatch(ctx, @["config", "path"]) == ExitSuccess
    removeDir(root)

  test "devices 与 doctor 在有运行时的机器上返回 0":
    # 没有 OpenVINO 时跳过 —— 那种环境下 devices 应当报
    # BACKEND_NOT_AVAILABLE,由下一条用例断言。
    if not inferenceRuntimeAvailable():
      skip()
    else:
      let root = makeTempRoot()
      let ctx = newCliContext(parseCliOptions(["--config", root]))
      check dispatch(ctx, @["devices"]) == ExitSuccess
      check dispatch(ctx, @["doctor"]) == ExitSuccess
      removeDir(root)

  test "缺少运行时时 devices 报 Backend 类退出码而不是崩溃":
    if inferenceRuntimeAvailable():
      skip()
    else:
      let root = makeTempRoot()
      let ctx = newCliContext(parseCliOptions(["--config", root]))
      check dispatch(ctx, @["devices"]) == ExitBackend
      # doctor 必须在这种环境下仍然能跑完 —— 那正是它的存在理由。
      discard dispatch(ctx, @["doctor"])
      removeDir(root)

  test "devices 与 doctor 的 JSON 形态可用":
    if not inferenceRuntimeAvailable():
      skip()
    else:
      let root = makeTempRoot()
      let ctx = newCliContext(parseCliOptions(["--config", root, "--json"]))
      check dispatch(ctx, @["devices"]) == ExitSuccess
      check dispatch(ctx, @["doctor"]) == ExitSuccess
      removeDir(root)

  test "英文界面下所有命令同样可用":
    let root = makeTempRoot()
    let ctx = newCliContext(parseCliOptions(["--config", root, "--lang", "en-US"]))
    check dispatch(ctx, @["help"]) == ExitSuccess
    check dispatch(ctx, @["version"]) == ExitSuccess
    check dispatch(ctx, @["config", "path"]) == ExitSuccess
    check dispatch(ctx, @["nosuchcommand"]) == ExitUsage
    removeDir(root)

# ---------------------------------------------------------------------------
# chat 的参数解析
# ---------------------------------------------------------------------------
#
# 这些用例**不需要模型**:错误的参数在触碰模型之前就被拒绝。真正的对话
# 由 tests/inference/tgeneration_real.nim 在真机上验证。
#
# 把参数解析单独测出来是有价值的:一个被静默接受的错误选项(比如
# `--max-tokens abc` 被当成 0)会让 chat 在加载完 4 GB 模型之后才失败,
# 而那时用户已经等了十秒。

suite "chat 的参数校验(不需要模型)":

  test "--json 必须与 --prompt 一起用":
    # 交互式会话是多轮流式输出,拼不成一个合法 JSON 文档。
    let ctx = contextWith(["--json"])
    check dispatch(ctx, @["chat", "somewhere"]) == ExitUsage

  test "--json 配 --prompt 时通过参数校验":
    # 只验证「没有被参数校验拒绝」:模型不存在,因此会以模型类错误结束,
    # 而不是用法错误。两者的区分正是这条要锁的东西。
    let ctx = contextWith(["--json"])
    check dispatch(ctx, @["chat", "no_such_dir_xyz", "--prompt", "hi"]) ==
      ExitModel

  test "不存在的模型标识或目录报模型类退出码":
    let ctx = contextWith([])
    check dispatch(ctx, @["chat", "no_such_dir_xyz", "--prompt", "hi"]) ==
      ExitModel

  test "--max-tokens 非数字被拒绝":
    let ctx = contextWith([])
    check dispatch(ctx, @["chat", "x", "--max-tokens", "abc",
                          "--prompt", "hi"]) == ExitUsage

  test "--max-tokens 非正数被拒绝":
    let ctx = contextWith([])
    for value in ["0", "-1"]:
      check dispatch(ctx, @["chat", "x", "--max-tokens", value,
                            "--prompt", "hi"]) == ExitUsage

  test "缺少取值的选项被拒绝":
    let ctx = contextWith([])
    for option in ["--device", "--max-tokens", "--extension"]:
      check dispatch(ctx, @["chat", option]) == ExitUsage

  test "取值位置是另一个选项时被拒绝(受限值域)":
    # `--device --json` 不该把 "--json" 当成设备名。
    let ctx = contextWith([])
    check dispatch(ctx, @["chat", "--device", "--no-stream",
                          "--prompt", "hi"]) == ExitUsage

  test "--prompt 与 --system 允许以短横线开头的自由文本":
    # 它们的取值是自由文本,可能合法地以 - 开头(例如分隔线)。
    # 这里应当走到模型解析阶段而不是用法错误。
    let ctx = contextWith([])
    check dispatch(ctx, @["chat", "no_such_dir_xyz",
                          "--prompt", "--- hello ---"]) == ExitModel

  test "未知选项被拒绝":
    let ctx = contextWith([])
    check dispatch(ctx, @["chat", "x", "--nonsense"]) == ExitUsage

  test "给两个位置参数被拒绝":
    let ctx = contextWith([])
    check dispatch(ctx, @["chat", "a", "b", "--prompt", "hi"]) == ExitUsage

  test "run 是 chat 的别名":
    let ctx = contextWith(["--json"])
    check dispatch(ctx, @["run", "somewhere"]) == ExitUsage

  test "空模型库时不给参数报模型类错误,并提示如何导入":
    # 不替用户挑模型;库为空时也不该崩。
    let root = makeTempRoot()
    let ctx = newCliContext(parseCliOptions(["--config", root]))
    check dispatch(ctx, @["chat", "--prompt", "hi"]) == ExitModel
    removeDir(root)
