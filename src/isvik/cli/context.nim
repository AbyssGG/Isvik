## CLI 全局参数解析与运行上下文
##
## ---
##
## ## 支持的全局选项(§59 / §31)
##
## ```text
## --json              以 JSON 输出
## --verbose, -v       输出更多诊断信息
## --lang <code>       界面语言(zh-CN / en-US)
## --config <dir>      数据根目录,覆盖 ISVIK_HOME
## ```
##
## `--lang zh-CN` 与 `--lang=zh-CN` 两种写法都接受。
##
## ---
##
## ## 为什么全局选项在子命令之前统一剥离
##
## 若每个子命令自己解析 `--json`,就会出现「有的命令支持有的不支持」这种
## 不一致,而且用户无法预测把它放在哪里有效。这里先剥掉所有全局选项,
## 剩下的按位置参数交给子命令,于是
## `isvik --json devices` 与 `isvik devices --json` 等价。
##
## 未知的 `--xxx` **不在这里报错**,原样留给子命令 —— 子命令可能有自己的选项,
## 越权判断会挡住它们。
##
## ---
##
## ## 配置读不出来时不能让 CLI 整体不可用
##
## `isvik doctor` 的全部意义就是在环境有问题时还能运行。如果构造上下文时
## 因为 settings.json 损坏而抛异常,那么最需要 doctor 的时候恰好用不了它。
## 因此读配置失败会退化为默认值,并把原因记在 `settingsLoadError` 里,
## 由 doctor 如实报告。

import std/[os, strutils]

import isvik/core/errors
import isvik/config/paths
import isvik/config/settings
import isvik/i18n/catalog

export catalog

type
  CliOptions* = object
    ## 从命令行剥离出的全局选项。
    json*: bool
    verbose*: bool
    lang*: string
      ## 原样保留的 `--lang` 取值;空表示未指定。
    configDir*: string
      ## 原样保留的 `--config` 取值;空表示未指定。
    rest*: seq[string]
      ## 去掉全局选项后剩余的参数,第一个通常是子命令名。

  CliContext* = ref object
    ## 命令执行所需的运行上下文。
    options*: CliOptions
    catalog*: Catalog
    paths*: IsvikPaths
    settings*: Settings
    settingsLoadError*: string
      ## 配置读取失败的原因。为空表示读取正常(含「文件不存在,用默认值」
      ## 这一首次运行的正常路径)。非空时 `settings` 是默认值。

const
  GlobalFlagNames* = ["--json", "--verbose", "-v"]
    ## 不带取值的全局选项。

  GlobalValueOptionNames* = ["--lang", "--config"]
    ## 需要取值的全局选项。

proc isGlobalOption(token: string): bool =
  for name in GlobalFlagNames:
    if token == name:
      return true
  for name in GlobalValueOptionNames:
    if token == name or token.startsWith(name & "="):
      return true
  result = false

proc raiseNeedsValue(option: string, got: string = "") {.noreturn.} =
  raiseIsvikError(
    ecInvalidParameter,
    "Global option requires a value",
    "option=" & option & (if got.len > 0: " got=" & got else: "")
  )

proc parseCliOptions*(args: openArray[string]): CliOptions =
  ## 从参数列表中剥离全局选项。
  result = CliOptions(
    json: false,
    verbose: false,
    lang: "",
    configDir: "",
    rest: @[]
  )

  var i = 0
  while i < args.len:
    let token = args[i]

    if not isGlobalOption(token):
      result.rest.add(token)
      inc i
      continue

    # `--name=value` 形式
    var handledInline = false
    for name in GlobalValueOptionNames:
      if token.startsWith(name & "="):
        let value = token[(name.len + 1) .. ^1]
        if value.len == 0:
          raiseNeedsValue(name)
        if name == "--lang": result.lang = value
        else: result.configDir = value
        handledInline = true
        break
    if handledInline:
      inc i
      continue

    case token
    of "--json":
      result.json = true
      inc i
    of "--verbose", "-v":
      result.verbose = true
      inc i
    of "--lang", "--config":
      if i + 1 >= args.len:
        raiseNeedsValue(token)
      let value = args[i + 1]
      # 下一个 token 又是选项,说明取值缺失 —— 不能把选项当成取值吞掉,
      # 否则 `isvik --lang --json` 会得到语言 "--json" 这种荒谬结果。
      if value.startsWith("-"):
        raiseNeedsValue(token, value)
      if token == "--lang": result.lang = value
      else: result.configDir = value
      inc i, 2
    else:
      # isGlobalOption 与本 case 必须覆盖同一集合;走到这里说明两者分叉了。
      raiseIsvikError(
        ecServerError,
        "Global option recognized but not handled",
        "option=" & token
      )

proc newCliContext*(options: CliOptions): CliContext =
  ## 构造运行上下文。
  ##
  ## **不创建任何目录**:只有 `config path` 与 `doctor` 会显式创建。
  ## 让 `isvik version` 这类命令产生文件系统副作用是不可接受的。
  new(result)
  result.options = options
  result.paths = newIsvikPaths(options.configDir)
  result.settingsLoadError = ""

  try:
    result.settings = loadSettings(result.paths.settingsFile)
  except IsvikError as e:
    result.settings = defaultSettings()
    result.settingsLoadError = $e.code & ": " & e.msg
    if e.detail.len > 0:
      result.settingsLoadError.add(" | " & e.detail)

  # 语言:命令行 > 配置 > 默认。命令行给了非法值必须报错(见 catalog 说明)。
  #
  # 注意配置里的非法语言不能在这里炸掉 CLI —— settings 的 validate 已经会
  # 拒绝非法语言,所以能读出来的配置里语言一定合法;但配置读取失败时用的是
  # 默认值,同样合法。因此这里只有 --lang 有可能带来非法值。
  let language = resolveLanguage(options.lang, result.settings.language)
  result.catalog = catalogFor(language)

proc t*(ctx: CliContext, key: string): string =
  ## 取文案的便捷入口。
  ctx.catalog.t(key)

proc t*(ctx: CliContext, key: string, args: openArray[string]): string =
  ctx.catalog.t(key, args)

proc language*(ctx: CliContext): Language = ctx.catalog.language
proc isJson*(ctx: CliContext): bool = ctx.options.json
proc isVerbose*(ctx: CliContext): bool = ctx.options.verbose

proc needsLanguageSelection*(ctx: CliContext): bool =
  ## 当前是否是尚未创建 settings.json 的首次交互启动。
  ##
  ## 配置损坏时绝不能返回 true:此时 `settings` 是为保证 doctor 可运行而提供的
  ## 默认退化值,若把它保存回去会覆盖用户原来的损坏文件,连恢复线索也一起丢掉。
  ctx != nil and ctx.settingsLoadError.len == 0 and
    not fileExists(ctx.paths.settingsFile) and
    ctx.options.lang.strip().len == 0

proc persistLanguage*(ctx: CliContext, code: string) =
  ## 持久化语言并立即更新当前 CLI 上下文。
  ##
  ## 这是一次小型事务:先解析并写盘,全部成功后才替换内存里的 settings/catalog。
  ## 因此磁盘不可写时当前界面不会出现「看似切换成功、重启又恢复」的半提交状态。
  if ctx == nil:
    raiseIsvikError(ecInvalidParameter, "CLI context is required")
  if ctx.settingsLoadError.len > 0:
    raiseIsvikError(
      ecInvalidParameter,
      ctx.t("workbench.lang.configBroken"),
      ctx.settingsLoadError
    )

  let language = parseLanguage(code.strip())

  # 常驻工作台可能运行很久，settings.json 在此期间可能被用户或另一个 Isvik
  # 进程修改。保存前重新读取磁盘，只合并 language；不能拿启动时的快照覆盖
  # 新字段。若文件此刻损坏，loadSettings 会抛错，原始字节保持不动。
  var updated =
    if fileExists(ctx.paths.settingsFile):
      loadSettings(ctx.paths.settingsFile)
    else:
      ctx.settings
  updated.language = $language
  saveSettings(ctx.paths.settingsFile, updated)

  ctx.settings = updated
  ctx.catalog = catalogFor(language)

proc rootSourceDescription*(ctx: CliContext): string =
  ## 说明数据根目录是怎么定下来的,避免用户困惑于「为什么在这个位置」。
  if ctx.options.configDir.strip().len > 0:
    return ctx.t("config.source.explicit")
  let envValue = getEnv(IsvikHomeEnvVar).strip()
  if envValue.len > 0:
    return ctx.t("config.source.env", [IsvikHomeEnvVar, envValue])
  result = ctx.t("config.source.default", [DefaultHomeDirName])

proc usesDefaultRoot*(ctx: CliContext): bool =
  ## 根目录是否来自默认位置(既没有 `--config` 也没有 `ISVIK_HOME`)。
  ctx.options.configDir.strip().len == 0 and
    getEnv(IsvikHomeEnvVar).strip().len == 0
