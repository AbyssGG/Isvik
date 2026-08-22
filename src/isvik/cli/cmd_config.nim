## `isvik config` 子命令
##
## 当前只有 `config path`:解析并初始化数据目录,打印实际生效的路径与配置。
##
## 架构约束(§23):CLI 不得直接访问 OpenVINO。本模块只依赖 config / i18n,
## 与任何 Backend 无关。

import std/[os, json]

import isvik/core/errors
import isvik/config/paths
import isvik/config/settings
import isvik/cli/context
import isvik/cli/output
import isvik/cli/exit_codes

proc pathsToJson(p: IsvikPaths): JsonNode =
  %*{
    "root": p.root,
    "models": p.models,
    "blobs": p.blobs,
    "cache": p.cache,
    "logs": p.logs,
    "config": p.config,
    "data": p.data,
    "settingsFile": p.settingsFile
  }

proc runConfigPath(ctx: CliContext): int =
  ## 打印数据目录布局与配置摘要,并确保目录与配置文件存在。
  let p = ctx.paths

  let existedBefore = p.directoriesExist()
  p.ensureDirectories()

  let settingsExistedBefore = fileExists(p.settingsFile)
  let s = loadOrCreateSettings(p.settingsFile)

  if ctx.isJson:
    # 配置部分直接复用 settings 自己的序列化,避免 CLI 输出与
    # 配置文件的字段名分叉。
    emitJson(%*{
      "paths": pathsToJson(p),
      "rootSource": ctx.rootSourceDescription(),
      "createdDirectories": not existedBefore,
      "createdSettings": not settingsExistedBefore,
      "settings": s.toJsonNode()
    })
    return ExitSuccess

  echo ctx.t("config.title")
  echo ""
  echo kvLine(ctx.t("config.root"), p.root)
  echo kvLine(ctx.t("config.models"), p.models)
  echo kvLine(ctx.t("config.blobs"), p.blobs)
  echo kvLine(ctx.t("config.cache"), p.cache)
  echo kvLine(ctx.t("config.logs"), p.logs)
  echo kvLine(ctx.t("config.configDir"), p.config)
  echo kvLine(ctx.t("config.data"), p.data)
  echo ""
  echo kvLine(ctx.t("config.settingsFile"), p.settingsFile)
  echo ""
  echo kvLine(ctx.t("config.source"), ctx.rootSourceDescription())
  if ctx.usesDefaultRoot():
    echo kvLine("", ctx.t("config.source.hint", [IsvikHomeEnvVar]))
  echo ""

  if not existedBefore:
    echo "  " & ctx.t("config.createdDirs")
  if not settingsExistedBefore:
    echo "  " & ctx.t("config.createdSettings")
  if existedBefore and settingsExistedBefore:
    echo "  " & ctx.t("config.noChange")
  echo ""

  echo ctx.t("config.currentTitle")
  echo ""
  echo kvLine("language", s.language)
  echo kvLine("default_device", s.defaultDevice)
  echo kvLine("model_directory",
    if s.modelDirectory.len > 0: s.modelDirectory
    else: "(" & ctx.t("common.default") & ": " & p.models & ")")
  echo kvLine("cache_directory",
    if s.cacheDirectory.len > 0: s.cacheDirectory
    else: "(" & ctx.t("common.default") & ": " & p.cache & ")")
  echo kvLine("server.host", s.server.host)
  echo kvLine("server.port", $s.server.port)
  echo kvLine("logging.level", $s.logging.level)
  echo kvLine("logging.console", $s.logging.console)
  echo kvLine("logging.file", $s.logging.file)

  result = ExitSuccess

proc runConfigCommand*(ctx: CliContext, args: seq[string]): int =
  ## `isvik config` 的入口。args 是 `config` 之后的位置参数。
  if args.len == 0:
    echo ctx.t("config.usage")
    return ExitSuccess

  case args[0]
  of "path":
    try:
      result = runConfigPath(ctx)
    except IsvikError as e:
      result = reportError(ctx, e)
  else:
    result = reportUsageError(ctx,
      ctx.t("error.unknownSubcommand", ["config", args[0]]))
