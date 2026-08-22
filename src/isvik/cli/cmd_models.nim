## 模型相关子命令:`list` / `info` / `import` / `rm`
##
## 架构约束(§23):只依赖 models / config / i18n,与任何 Backend 无关 ——
## 列举和导入模型不需要 OpenVINO,因此这些命令在没装运行时的机器上照常可用。
##
## ---
##
## ## 输出里必须能看出「不完整」
##
## 引用模式下模型文件在库外,可能被移动或删除。`list` 如果只显示 id 和大小,
## 用户会以为模型可用,直到编译时才失败。因此完整性状态是 `list` 的一等列。

import std/[json, strutils]

import isvik/core/errors
import isvik/services/model_service
import isvik/cli/context
import isvik/cli/output
import isvik/cli/exit_codes

proc humanBytes(bytes: int64): string =
  ## 人类可读的大小。用二进制单位(KiB / MiB / GiB),不含糊地写清进制 ——
  ## 「GB」在磁盘厂商与操作系统之间含义不同,写 GiB 没有歧义。
  const units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var value = float(bytes)
  var unit = 0
  while value >= 1024.0 and unit < units.high:
    value = value / 1024.0
    inc unit
  if unit == 0:
    result = $bytes & " B"
  else:
    result = formatFloat(value, ffDecimal, 2) & " " & units[unit]

proc statusText(ctx: CliContext, m: StoredModel): string =
  if m.issues.len == 0:
    ctx.t("models.status.complete")
  else:
    ctx.t("models.status.incomplete", [$m.issues.len])

proc storedToJson(m: StoredModel): JsonNode =
  var issues = newJArray()
  for i in m.issues:
    issues.add(%*{"path": i.path, "kind": $i.kind, "detail": i.detail})

  result = m.manifest.toJsonNode()
  result["directory"] = %m.directory
  result["content_directory"] = %m.contentDirectory
  result["total_bytes"] = %m.manifest.totalBytes
  result["complete"] = %(m.issues.len == 0)
  result["issues"] = issues

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------

proc runList(ctx: CliContext): int =
  let mgr = newModelService(ctx.paths, ctx.settings)
  let models = mgr.list()

  if ctx.isJson:
    var arr = newJArray()
    for m in models:
      arr.add(storedToJson(m))
    emitJson(%*{
      "modelDirectory": mgr.rootDirectory,
      "count": models.len,
      "models": arr
    })
    return ExitSuccess

  echo ctx.t("models.title")
  echo ""

  if models.len == 0:
    echo "  " & ctx.t("models.none")
    echo "  " & ctx.t("models.hint.import")
  else:
    var rows: seq[seq[string]] = @[]
    for index, m in models:
      rows.add(@[
        "[" & $(index + 1) & "]",
        m.manifest.id,
        $m.manifest.task,
        $m.manifest.storage,
        humanBytes(m.manifest.totalBytes),
        statusText(ctx, m)
      ])
    for line in renderTable(
        [ctx.t("models.col.select"), ctx.t("models.col.id"),
         ctx.t("models.col.task"), ctx.t("models.col.storage"),
         ctx.t("models.col.size"), ctx.t("models.col.status")], rows):
      echo line

  echo ""
  echo kvLine(ctx.t("models.directory"), mgr.rootDirectory)
  result = ExitSuccess

# ---------------------------------------------------------------------------
# info
# ---------------------------------------------------------------------------

proc runInfo(ctx: CliContext, id: string, checkChecksums: bool): int =
  let mgr = newModelService(ctx.paths, ctx.settings)
  let m = mgr.info(id, initVerifyOptions(checkChecksums))

  if ctx.isJson:
    emitJson(storedToJson(m))
    return ExitSuccess

  echo ctx.t("models.infoTitle", [m.manifest.displayLabel])
  echo ""
  echo kvLine(ctx.t("models.field.id"), m.manifest.id)
  if m.manifest.version.len > 0:
    echo kvLine(ctx.t("models.field.version"), m.manifest.version)
  echo kvLine(ctx.t("models.field.format"), $m.manifest.format)
  echo kvLine(ctx.t("models.field.task"), $m.manifest.task)
  echo kvLine("Layout", $m.manifest.layout)
  echo kvLine(ctx.t("models.field.storage"), $m.manifest.storage)
  echo kvLine(ctx.t("models.field.size"), humanBytes(m.manifest.totalBytes))
  echo kvLine(ctx.t("models.field.files"), $m.manifest.files.len)
  echo kvLine(ctx.t("models.field.contentDir"), m.contentDirectory)
  echo kvLine(ctx.t("models.field.importedAt"), m.manifest.importedAt)
  echo kvLine(ctx.t("models.field.status"), statusText(ctx, m))

  echo ""
  echo ctx.t("models.entrypointsTitle")
  var anyEntrypoint = false
  for role in KnownEntrypoints:
    if m.manifest.hasEntrypoint(role):
      anyEntrypoint = true
      # 宽度必须容得下最长的角色名(text_embeddings_per_layer,25 字符),
      # 否则标签与路径会粘在一起。
      echo kvLine(role, m.manifest.entrypoint(role), 28)
  if not anyEntrypoint:
    echo "  " & ctx.t("common.none")
  if m.manifest.isComposite():
    echo "  " & ctx.t("models.compositeNote")

  echo ""
  echo ctx.t("models.deviceTitle")
  if m.manifest.deviceSupport.len == 0:
    # 没有条目不等于不支持,只是没写。如实说明,不猜。
    echo "  " & ctx.t("models.device.noEntries")
  else:
    var rows: seq[seq[string]] = @[]
    for d in m.manifest.deviceSupport:
      var shapeText = ctx.t("common.none")
      if d.shapeConstraints.len > 0:
        var parts: seq[string] = @[]
        for c in d.shapeConstraints:
          var dims: seq[string] = @[]
          for dim in c.dims:
            dims.add(if dim < 0: "?" else: $dim)
          parts.add(c.port & "[" & dims.join(",") & "]")
        shapeText = parts.join(" ")
      rows.add(@[
        d.device,
        (if d.supported: ctx.t("common.yes") else: ctx.t("common.no")),
        (if d.requiresStaticShape: ctx.t("common.yes") else: ctx.t("common.no")),
        # 「已验证」与「声称支持」必须分开显示(§13 / §27)。
        (if d.verified: ctx.t("models.device.verified")
         else: ctx.t("models.device.unverified")),
        shapeText
      ])
    for line in renderTable(
        [ctx.t("models.col.device"), ctx.t("models.col.supported"),
         ctx.t("models.col.staticShape"), ctx.t("models.col.verified"),
         ctx.t("models.col.shape")], rows):
      echo line
    echo "  " & ctx.t("models.device.legend")

  if m.issues.len > 0:
    echo ""
    echo ctx.t("models.issuesTitle")
    for i in m.issues:
      echo "  " & i.path & ": " & $i.kind &
        (if i.detail.len > 0: "  " & i.detail else: "")

  if m.manifest.notes.len > 0:
    echo ""
    echo kvLine(ctx.t("models.field.notes"), m.manifest.notes)

  result = ExitSuccess

# ---------------------------------------------------------------------------
# import
# ---------------------------------------------------------------------------

proc runImport(ctx: CliContext, args: seq[string]): int =
  ## `isvik import <dir> [--id <id>] [--copy] [--checksums] [--force]`
  ## 默认对本机 NPU 编译主 IR；`--no-npu-probe` 可在离线登记时跳过。
  if args.len == 0:
    return reportUsageError(ctx, ctx.t("models.import.usage"))

  var sourceDir = ""
  var options = initImportOptions()
  var i = 0
  while i < args.len:
    let token = args[i]
    case token
    of "--copy":
      options.copyFiles = true
      inc i
    of "--checksums":
      options.computeChecksums = true
      inc i
    of "--force":
      options.overwrite = true
      inc i
    of "--no-npu-probe":
      options.probeNpu = false
      inc i
    of "--id", "--name":
      if i + 1 >= args.len:
        return reportUsageError(ctx, ctx.t("error.optionNeedsValue", [token]))
      if token == "--id": options.id = args[i + 1]
      else: options.displayName = args[i + 1]
      inc i, 2
    else:
      if token.startsWith("-"):
        return reportUsageError(ctx, ctx.t("error.unknownOption", [token]))
      if sourceDir.len > 0:
        return reportUsageError(ctx, ctx.t("models.import.usage"))
      sourceDir = token
      inc i

  if sourceDir.len == 0:
    return reportUsageError(ctx, ctx.t("models.import.usage"))

  let mgr = newModelService(ctx.paths, ctx.settings)
  let m = mgr.importFrom(sourceDir, options)

  if ctx.isJson:
    emitJson(%*{
      "imported": m.id,
      "storage": $m.storage,
      "files": m.files.len,
      "totalBytes": m.totalBytes,
      "manifest": m.toJsonNode()
    })
    return ExitSuccess

  echo ctx.t("models.import.done", [m.id])
  echo kvLine(ctx.t("models.field.storage"), $m.storage)
  echo kvLine(ctx.t("models.field.files"), $m.files.len)
  echo kvLine(ctx.t("models.field.size"), humanBytes(m.totalBytes))
  echo kvLine("Layout", $m.layout)
  if m.storage == skReferenced:
    echo kvLine(ctx.t("models.field.contentDir"), m.sourceDirectory)
    echo "  " & ctx.t("models.import.referencedNote")
  var anyVerified = false
  for support in m.deviceSupport:
    if support.verified:
      anyVerified = true
      echo kvLine(support.device,
        (if support.supported: ctx.t("common.yes") else: ctx.t("common.no")) &
        " (" & ctx.t("models.device.verified") & ")")
  if not anyVerified:
    echo "  " & ctx.t("models.import.notVerified")
  result = ExitSuccess

# ---------------------------------------------------------------------------
# rm
# ---------------------------------------------------------------------------

proc runRemove(ctx: CliContext, args: seq[string]): int =
  if args.len == 0:
    return reportUsageError(ctx, ctx.t("models.rm.usage"))

  let id = args[0]
  let mgr = newModelService(ctx.paths, ctx.settings)
  # 先读出来,以便告诉用户删掉的是引用还是文件本身。
  let before = mgr.info(id)
  mgr.remove(id)

  if ctx.isJson:
    emitJson(%*{
      "removed": id,
      "storage": $before.manifest.storage,
      "externalFilesKept": before.manifest.storage == skReferenced
    })
    return ExitSuccess

  echo ctx.t("models.rm.done", [id])
  if before.manifest.storage == skReferenced:
    echo "  " & ctx.t("models.rm.keptExternal", [before.contentDirectory])
  result = ExitSuccess

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

proc runListCommand*(ctx: CliContext, args: seq[string]): int =
  if args.len > 0:
    return reportUsageError(ctx,
      ctx.t("error.unknownSubcommand", ["list", args[0]]))
  try:
    result = runList(ctx)
  except IsvikError as e:
    result = reportError(ctx, e)

proc runInfoCommand*(ctx: CliContext, args: seq[string]): int =
  if args.len == 0:
    return reportUsageError(ctx, ctx.t("models.info.usage"))

  var id = ""
  var checkChecksums = false
  for token in args:
    if token == "--checksums":
      checkChecksums = true
    elif token.startsWith("-"):
      return reportUsageError(ctx, ctx.t("error.unknownOption", [token]))
    elif id.len == 0:
      id = token
    else:
      return reportUsageError(ctx, ctx.t("models.info.usage"))

  if id.len == 0:
    return reportUsageError(ctx, ctx.t("models.info.usage"))

  try:
    result = runInfo(ctx, id, checkChecksums)
  except IsvikError as e:
    result = reportError(ctx, e)

proc runImportCommand*(ctx: CliContext, args: seq[string]): int =
  try:
    result = runImport(ctx, args)
  except IsvikError as e:
    result = reportError(ctx, e)

proc runRemoveCommand*(ctx: CliContext, args: seq[string]): int =
  try:
    result = runRemove(ctx, args)
  except IsvikError as e:
    result = reportError(ctx, e)
