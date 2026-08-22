## `isvik api` —— 面向 TRAE 等成品客户端的安全本地 API 入口。
##
## 子命令:
##
## ```text
## isvik api key create [--name <名称>]
## isvik api key list
## isvik api key revoke <id>
## isvik api serve [--host <地址>] [--port <端口>]
## ```
##
## `api serve` 强制要求 API Key。Key 的创建与撤销可以在服务运行期间执行,
## 服务端每次请求读取同一份元数据文件,因此不需要重启。

import std/[json, strutils]

import isvik/core/errors
import isvik/config/api_keys
import isvik/config/paths
import isvik/cli/context
import isvik/cli/output
import isvik/cli/exit_codes
import isvik/cli/api_integration
import isvik/cli/cmd_serve

proc printApiUsage(ctx: CliContext) =
  echo ctx.t("api.usage")

proc printKeyUsage(ctx: CliContext) =
  echo ctx.t("api.key.usage")

proc runCreateKey(ctx: CliContext, args: seq[string]): int =
  var name = ""
  var i = 0
  while i < args.len:
    case args[i]
    of "--name":
      if i + 1 >= args.len or args[i + 1].startsWith("-"):
        return reportUsageError(ctx, ctx.t("error.optionNeedsValue", ["--name"]))
      name = args[i + 1]
      i += 2
    else:
      return reportUsageError(ctx, ctx.t("api.key.create.usage"))

  ctx.paths.ensureDirectories()
  let created = createApiKey(ctx.paths.apiKeysFile, name)

  if ctx.isJson:
    var output = publicApiKeyJson(created.record)
    output["apiKey"] = %created.secret
    output["warning"] = %ctx.t("api.key.secretWarning")
    output["integration"] = apiIntegrationJson(ctx)
    emitJson(output)
    return ExitSuccess

  echo ctx.t("api.key.created")
  echo kvLine(ctx.t("api.key.id"), created.record.id)
  echo kvLine(ctx.t("api.key.name"), created.record.name)
  echo kvLine(ctx.t("api.key.createdAt"), created.record.createdAt)
  echo kvLine(ctx.t("api.key.secret"), created.secret)
  echo ""
  echo "  " & ctx.t("api.key.secretWarning")
  echo ""
  printApiIntegration(ctx)
  result = ExitSuccess

proc runListKeys(ctx: CliContext, args: seq[string]): int =
  if args.len > 0:
    return reportUsageError(ctx, ctx.t("api.key.list.usage"))
  let keys = listApiKeys(ctx.paths.apiKeysFile)

  if ctx.isJson:
    var items = newJArray()
    for key in keys:
      items.add(publicApiKeyJson(key))
    var output = newJObject()
    output["count"] = %keys.len
    output["keys"] = items
    emitJson(output)
    return ExitSuccess

  echo ctx.t("api.key.listTitle")
  echo ""
  if keys.len == 0:
    echo "  " & ctx.t("api.key.none")
  else:
    var rows: seq[seq[string]] = @[]
    for index, key in keys:
      rows.add(@[
        # 与 `isvik -ls` 的模型编号同一形式:Key 的调取方式和模型一致。
        "[" & $(index + 1) & "]",
        key.id,
        key.name,
        key.createdAt,
        if key.isActive: ctx.t("api.key.active")
        else: ctx.t("api.key.revoked"),
        if key.hasSecret(): ctx.t("common.yes") else: ctx.t("common.no")
      ])
    for line in renderTable(
        [ctx.t("api.key.col.select"), ctx.t("api.key.col.id"),
         ctx.t("api.key.col.name"), ctx.t("api.key.col.createdAt"),
         ctx.t("api.key.col.status"), ctx.t("api.key.col.retrievable")], rows):
      echo line
    echo ""
    echo "  " & ctx.t("api.key.showHint")
  result = ExitSuccess

proc runShowKey(ctx: CliContext, args: seq[string]): int =
  ## 按编号或标识把明文 Key 取回来。
  ##
  ## 单独一条命令而不是并入 `list`:凭据不该出现在「看一眼有哪些 Key」这种
  ## 日常操作的输出里,那类输出经常被截图或重定向进日志。
  if args.len != 1 or args[0].startsWith("-"):
    return reportUsageError(ctx, ctx.t("api.key.show.usage"))
  let key = resolveApiKey(ctx.paths.apiKeysFile, args[0])

  if not key.hasSecret():
    # v1 时代创建的 Key 只有摘要。如实说明取不回,而不是返回空字符串让人
    # 以为复制到了什么东西。
    if ctx.isJson:
      var output = publicApiKeyJson(key)
      output["retrievable"] = %false
      output["reason"] = %ctx.t("api.key.legacyNoSecret")
      emitJson(output)
      return ExitSuccess
    echo ctx.t("api.key.showTitle")
    echo kvLine(ctx.t("api.key.id"), key.id)
    echo kvLine(ctx.t("api.key.name"), key.name)
    echo ""
    echo "  " & ctx.t("api.key.legacyNoSecret")
    return ExitSuccess

  if ctx.isJson:
    var output = publicApiKeyJson(key)
    output["retrievable"] = %true
    output["apiKey"] = %key.secretOf()
    output["integration"] = apiIntegrationJson(ctx)
    emitJson(output)
    return ExitSuccess

  echo ctx.t("api.key.showTitle")
  echo kvLine(ctx.t("api.key.id"), key.id)
  echo kvLine(ctx.t("api.key.name"), key.name)
  echo kvLine(ctx.t("api.key.createdAt"), key.createdAt)
  echo kvLine(ctx.t("api.key.status"),
              if key.isActive: ctx.t("api.key.active")
              else: ctx.t("api.key.revoked"))
  echo kvLine(ctx.t("api.key.secret"), key.secretOf())
  if not key.isActive:
    # 撤销过的 Key 仍然能取回明文(记录还在),但它已经不能用了。
    # 不说清楚的话,用户会拿着一个「看起来正常」的 Key 一直收 401。
    echo ""
    echo "  " & ctx.t("api.key.revokedWarning")
  echo ""
  printApiIntegration(ctx)
  result = ExitSuccess

proc runRevokeKey(ctx: CliContext, args: seq[string]): int =
  if args.len != 1 or args[0].startsWith("-"):
    return reportUsageError(ctx, ctx.t("api.key.revoke.usage"))
  let revoked = revokeApiKey(ctx.paths.apiKeysFile, args[0])

  if ctx.isJson:
    var output = newJObject()
    output["revoked"] = %true
    output["key"] = publicApiKeyJson(revoked)
    emitJson(output)
    return ExitSuccess

  echo ctx.t("api.key.revokedDone", [revoked.id])
  result = ExitSuccess

proc runKeyCommand(ctx: CliContext, args: seq[string]): int =
  if args.len == 0:
    printKeyUsage(ctx)
    return ExitSuccess

  case args[0]
  of "create", "new":
    try:
      result = runCreateKey(ctx, if args.len > 1: args[1 .. ^1] else: @[])
    except IsvikError as e:
      result = reportError(ctx, e)
  of "list", "ls":
    try:
      result = runListKeys(ctx, if args.len > 1: args[1 .. ^1] else: @[])
    except IsvikError as e:
      result = reportError(ctx, e)
  of "show", "get", "use":
    # `use` 是别名:选模型用 `-use 1`,取 Key 用 `-key use 1` 读起来一致。
    try:
      result = runShowKey(ctx, if args.len > 1: args[1 .. ^1] else: @[])
    except IsvikError as e:
      result = reportError(ctx, e)
  of "revoke", "remove", "rm":
    try:
      result = runRevokeKey(ctx, if args.len > 1: args[1 .. ^1] else: @[])
    except IsvikError as e:
      result = reportError(ctx, e)
  else:
    result = reportUsageError(ctx,
      ctx.t("error.unknownSubcommand", ["api key", args[0]]))

proc runApiServe(ctx: CliContext, args: seq[string]): int =
  ## 复用现有 serve 参数解析,但强制开启鉴权。
  var forwarded = @["--require-api-key"]
  for arg in args:
    forwarded.add(arg)
  runServeCommand(ctx, forwarded)

proc runApiCommand*(ctx: CliContext, args: seq[string]): int =
  ## `isvik api` 的入口。
  if args.len == 0:
    printApiUsage(ctx)
    return ExitSuccess

  case args[0]
  of "key", "keys":
    result = runKeyCommand(ctx,
      if args.len > 1: args[1 .. ^1] else: @[])
  of "serve", "start":
    result = runApiServe(
      ctx, if args.len > 1: args[1 .. ^1] else: @[])
  else:
    result = reportUsageError(ctx,
      ctx.t("error.unknownSubcommand", ["api", args[0]]))
