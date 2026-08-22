## `isvik serve` —— 启动 Local API(§21)
##
## ---
##
## ## 这个命令刻意很薄
##
## 它只做三件事:解析选项、按需覆盖监听地址、把控制权交给 `server/http_server`。
## 路由、协议翻译、推理都不在这里 —— §20.5.11 的职责边界要求 CLI 不重复
## 服务端逻辑。
##
## ---
##
## ## 关于 --host
##
## 允许覆盖,但**不静默**:绑定非回环地址且未开启鉴权时启动日志会明确警告。
## `--require-api-key` 与 `isvik api serve` 用于显式开启动态 API Key 鉴权。
##
## ---
##
## ## 为什么自动补 Key 发生在这里
##
## 这里是**所有**启动路径的汇合点(`isvik serve`、`isvik api serve`、工作台的
## `-serve` 都最终走 `runServeCommand`)。把「强制鉴权却没有任何 Key」的处理
## 放在任何一个上层入口,另外两条就会漏掉。

import std/[os, strutils]

import isvik/core/errors
import isvik/config/settings
import isvik/config/paths
import isvik/logging/logger
import isvik/cli/context
import isvik/cli/output
import isvik/cli/exit_codes
import isvik/cli/api_integration
import isvik/server/http_server

type
  ServeArgs = object
    host: string
    port: int
    hostGiven: bool
    portGiven: bool
    requireApiKey: bool
    autoKey: bool

proc parseServeArgs(ctx: CliContext, args: seq[string]):
    tuple[ok: bool, parsed: ServeArgs, exitCode: int] =
  # autoKey 默认开:见 api_integration.ensureServeApiKey 的说明。
  var parsed = ServeArgs(host: "", port: 0, hostGiven: false,
                         portGiven: false, requireApiKey: false,
                         autoKey: true)
  var i = 0
  while i < args.len:
    let arg = args[i]
    case arg
    of "--host":
      if i + 1 >= args.len or args[i + 1].startsWith("--"):
        return (false, parsed,
                reportUsageError(ctx, ctx.t("serve.needsHost")))
      parsed.host = args[i + 1]
      parsed.hostGiven = true
      i += 2
    of "--port":
      if i + 1 >= args.len:
        return (false, parsed,
                reportUsageError(ctx, ctx.t("serve.needsPort")))
      try:
        parsed.port = parseInt(args[i + 1])
      except ValueError:
        return (false, parsed,
                reportUsageError(ctx, ctx.t("serve.badPort", [args[i + 1]])))
      if parsed.port < 1 or parsed.port > 65535:
        return (false, parsed,
                reportUsageError(ctx, ctx.t("serve.badPort", [args[i + 1]])))
      parsed.portGiven = true
      i += 2
    of "--require-api-key":
      parsed.requireApiKey = true
      inc i
    of "--no-auto-key":
      parsed.autoKey = false
      inc i
    else:
      return (false, parsed, reportUsageError(ctx, ctx.t("serve.usage")))
  (true, parsed, ExitSuccess)

proc runServeCommand*(ctx: CliContext, args: seq[string]): int =
  let parsed = parseServeArgs(ctx, args)
  if not parsed.ok:
    return parsed.exitCode

  # 以配置为基准,命令行只覆盖显式给出的项。这样 settings.json 里的
  # server.host / server.port 仍然是单一来源。
  var s = ctx.settings
  if parsed.parsed.hostGiven:
    s.server.host = parsed.parsed.host
  if parsed.parsed.portGiven:
    s.server.port = parsed.parsed.port

  # 必须在构造服务**之前**:服务端每个请求重读 Key 文件,但启动日志里那句
  # 「API key authentication enabled」印出来之后再补 Key,用户读到的顺序就会
  # 变成先「已启用鉴权」再「顺便给你造了个 Key」,因果看起来是反的。
  try:
    ensureServeApiKey(ctx, s.server.host, s.server.port,
                      parsed.parsed.requireApiKey, parsed.parsed.autoKey)
  except IsvikError as e:
    # Key 文件损坏等问题在这里就报出来,而不是让服务起来后每个请求都 401。
    return reportError(ctx, e)

  # `settings.logging` 此前是**声明了却没有执行者**的配置:logger 与 FileSink
  # 早就写好,但没有任何生产代码用它,于是 `logging.file: true` 毫无效果、
  # `<ISVIK_HOME>/logs` 永远是空的。直接后果是服务端出错时现场不留证据 ——
  # 客户端只显示一句被它自己包装过的消息,真正的 detail 谁也看不到。
  var log: Logger = nil
  if s.logging.file:
    try:
      log = newLogger(minLevel = s.logging.level)
      log.addSink(newFileSink(ctx.paths.logs / "server.log"))
    except CatchableError:
      # 日志开不起来不该让服务起不来,但也不能假装它在记 —— 明说一句。
      log = nil
      echo ctx.t("serve.logFileFailed", [ctx.paths.logs / "server.log"])

  let logger: ServerLogger = proc (line: string) =
    if s.logging.console:
      echo line
    if log != nil:
      log.info(line)

  # 错误单独走 error 级别:否则把 `logging.level` 收紧到 ERROR 时,错误会跟
  # 普通启动信息一起被过滤掉 —— 而那正是最需要留下记录的时候。
  let errorLogger: ServerLogger = proc (line: string) =
    if s.logging.console:
      stderr.writeLine(line)
    if log != nil:
      log.error(line)

  let server = newApiServer(ctx.paths, s, logger, parsed.parsed.requireApiKey,
                            errorLogger)
  try:
    server.serve()
    result = ExitSuccess
  except IsvikError as e:
    result = reportError(ctx, e)
  except OSError as e:
    # 端口被占用是最常见的启动失败,报成可诊断的错误而不是让异常穿透。
    result = reportError(ctx, newIsvikError(
      ecServerError,
      ctx.t("serve.bindFailed", [s.server.host, $s.server.port]),
      e.msg))
  finally:
    server.close()
    if log != nil:
      log.close()
