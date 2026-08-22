## `isvik doctor` —— 环境体检
##
## ---
##
## ## 三态,不是布尔
##
## DEVLOG 第六节第 7 条对 doctor 的硬要求是:输出必须区分
##
## ```text
## 可用            能用,不必管
## 存在但不可用    检测到了但用不起来 —— 这是唯一需要用户动手的一类
## 缺失            本机没有这一项 —— 不是故障,只是没有
## ```
##
## 用布尔会把后两者压成同一个「否」,而它们的处理方式完全相反:
## 「没有 NPU」不需要修,「有 NPU 但驱动装不上」必须修。
##
## ---
##
## ## 它必须在环境坏掉时还能运行
##
## 这是 doctor 唯一的存在理由。因此:
##
## - 不 import OpenVINO(§23),经 `backends/factory` 拿抽象 Backend
## - 运行时加载失败不抛异常,记为一项「缺失」继续往下检查
## - 配置文件损坏不中断,`CliContext` 已把原因记在 `settingsLoadError` 里
## - 只有真正需要写盘的检查才动文件系统,且写完就删
##
## ---
##
## ## 退出码
##
## 有任何一项「存在但不可用」时返回非零,让 CI 能直接用它当门禁。
## 「缺失」不算失败 —— 一台没有 NPU 的机器不该让 doctor 报错。

import std/[os, json, strutils]

import isvik/core/errors
import isvik/core/runtime
import isvik/config/paths
import isvik/backends/factory
import isvik/cli/context
import isvik/cli/output
import isvik/cli/exit_codes

type
  CheckState* = enum
    ## 三态。字符串值进入 JSON 输出,是稳定契约。
    csOk = "ok"
    csUnusable = "unusable"
    csMissing = "missing"

  DoctorCheck* = object
    ## 一项检查的结果。
    section*: string
    label*: string
    state*: CheckState
    detail*: string
      ## 实测到的具体内容(版本号、设备名、路径、失败原因)。
      ## 空字符串表示没有额外信息可报。

proc stateText(ctx: CliContext, state: CheckState): string =
  case state
  of csOk: ctx.t("doctor.state.ok")
  of csUnusable: ctx.t("doctor.state.unusable")
  of csMissing: ctx.t("doctor.state.missing")

proc stateMark(state: CheckState): string =
  ## 纯 ASCII 标记。刻意不用 emoji 或 Unicode 符号:Windows 控制台在
  ## 非 UTF-8 代码页下会把它们显示成乱码,而 doctor 恰恰要在环境不正常的
  ## 机器上可读。
  case state
  of csOk: "[ok]"
  of csUnusable: "[!!]"
  of csMissing: "[--]"

# ---------------------------------------------------------------------------
# 各组检查
# ---------------------------------------------------------------------------

proc checkRuntime(ctx: CliContext, checks: var seq[DoctorCheck]) =
  ## 推理运行时能否加载,以及真实版本。
  let section = ctx.t("doctor.section.runtime")
  let available = inferenceRuntimeAvailable()

  checks.add(DoctorCheck(
    section: section,
    label: ctx.t("doctor.check.openvino"),
    state: if available: csOk else: csMissing,
    detail:
      if available: InferenceRuntimeName
      else: InferenceRuntimeName & ": " & inferenceRuntimeError()
  ))

  if not available:
    # 版本查不了就不假装查过。
    checks.add(DoctorCheck(
      section: section,
      label: ctx.t("doctor.check.runtimeVersion"),
      state: csMissing,
      detail: ""
    ))
    return

  let version = inferenceRuntimeVersion()
  checks.add(DoctorCheck(
    section: section,
    label: ctx.t("doctor.check.runtimeVersion"),
    # 版本取不到是「装着但报不出版本」,属于存在但不正常。
    state: if version == UnknownRuntimeVersion: csUnusable else: csOk,
    detail: version
  ))

proc summarizeType(devices: seq[DeviceInfo], wanted: DeviceType,
                   section, label: string, checks: var seq[DoctorCheck]) =
  ## 汇总某一类设备的状态。
  ##
  ## 找不到某类设备是「缺失」而不是「不可用」—— 一台没有 NPU 的机器
  ## 不该被 doctor 报成有问题。
  ##
  ## 但要区分两种「找不到」:一个都没检测到,与检测到了却被策略排除。
  ## 后者会把被排除的设备与原因写进 detail,因为那正是用户想问的
  ## 「我明明有显卡,为什么说没有 Intel GPU」。
  var matched: seq[DeviceInfo] = @[]
  for d in devices:
    if d.deviceType == wanted and d.policyEligible:
      matched.add(d)

  if matched.len == 0:
    var seenButExcluded: seq[string] = @[]
    for d in devices:
      if d.deviceType == wanted and not d.policyEligible:
        seenButExcluded.add(d.rawName & "(" & d.exclusionReason & ")")
    checks.add(DoctorCheck(
      section: section,
      label: label,
      state: csMissing,
      detail: seenButExcluded.join(", ")
    ))
  else:
    var names: seq[string] = @[]
    for d in matched:
      names.add(
        if d.fullName.len > 0: d.rawName & " " & d.fullName
        else: d.rawName)
    checks.add(DoctorCheck(
      section: section,
      label: label,
      state: csOk,
      detail: names.join(", ")
    ))

proc checkDevices(ctx: CliContext, checks: var seq[DoctorCheck]) =
  ## 设备枚举与各类设备的可用性。
  let section = ctx.t("doctor.section.devices")

  if not inferenceRuntimeAvailable():
    # 运行时都加载不了,设备无从谈起。如实记为缺失,不猜。
    checks.add(DoctorCheck(
      section: section,
      label: ctx.t("doctor.check.deviceEnum"),
      state: csMissing,
      detail: ctx.t("doctor.hint.runtime")
    ))
    return

  let rt = newRuntime(newInferenceBackend())
  var devices: seq[DeviceInfo] = @[]
  var enumError = ""

  try:
    rt.initialize()
    devices = rt.semanticDevices()
  except IsvikError as e:
    enumError = $e.code & ": " & e.msg

  try:
    if enumError.len > 0:
      # 运行时能加载但枚举失败 —— 典型的「存在但不可用」。
      checks.add(DoctorCheck(
        section: section,
        label: ctx.t("doctor.check.deviceEnum"),
        state: csUnusable,
        detail: enumError
      ))
      return

    checks.add(DoctorCheck(
      section: section,
      label: ctx.t("doctor.check.deviceEnum"),
      state: if devices.len > 0: csOk else: csUnusable,
      detail: $devices.len
    ))

    summarizeType(devices, dtCpu, section, ctx.t("doctor.check.cpu"), checks)
    summarizeType(devices, dtGpu, section, ctx.t("doctor.check.intelGpu"), checks)
    summarizeType(devices, dtNpu, section, ctx.t("doctor.check.npu"), checks)

    # AUTO 到底会选谁 —— 这是用户最想知道的一行。
    var autoDetail = ""
    var autoState = csOk
    try:
      let selection = rt.resolveDevice(DeviceRequestAuto)
      autoDetail = selection.device.rawName
      if selection.device.fullName.len > 0:
        autoDetail.add(" " & selection.device.fullName)
    except IsvikError as e:
      autoState = csUnusable
      autoDetail = $e.code & ": " & e.msg
    checks.add(DoctorCheck(
      section: section,
      label: ctx.t("doctor.check.autoTarget"),
      state: autoState,
      detail: autoDetail
    ))
  finally:
    rt.shutdown()

proc deepestExistingDir(start: string): string =
  ## 从 `start` 起向上找到第一个已存在的目录。
  ##
  ## 用途:数据目录还不存在时,「能不能建起来」取决于其最近的已存在祖先
  ## 是否可写。检查那里才有意义。
  var current = start
  while current.len > 0 and not dirExists(current):
    let parent = current.parentDir
    if parent == current:
      return ""
    current = parent
  result = current

proc checkStorage(ctx: CliContext, checks: var seq[DoctorCheck]) =
  ## 数据目录是否存在、可写,配置文件是否可读。
  ##
  ## **不创建任何目录。** doctor 是诊断命令,静默产生文件系统副作用会让
  ## 「检查前后状态不同」,而且第一次跑完就再也复现不了原始状态。
  ## 目录的创建交给 `isvik config path`。
  let section = ctx.t("doctor.section.storage")
  let p = ctx.paths

  let exists = p.directoriesExist()
  checks.add(DoctorCheck(
    section: section,
    label: ctx.t("doctor.check.dataDir"),
    # 目录不存在不算故障:首次运行本来就没有,`config path` 会建。
    state: if exists: csOk else: csMissing,
    detail: p.root
  ))

  # 可写性必须真的写一次才知道 —— 检查权限位在 Windows 上不可靠
  # (ACL、只读属性、磁盘满、路径被占用都会让「看起来可写」的目录写失败)。
  #
  # 目录不存在时探测其最近的已存在祖先:那回答的是「能否建起来」,
  # 同样是有用的信息,且不需要先创建任何东西。
  let probeDir =
    if dirExists(p.data): p.data
    elif dirExists(p.root): p.root
    else: deepestExistingDir(p.root)

  var writable = false
  var writeDetail = probeDir
  if probeDir.len == 0:
    writeDetail = p.root
  else:
    try:
      let probe = probeDir / ".isvik_doctor_probe"
      writeFile(probe, "probe")
      writable = readFile(probe) == "probe"
      removeFile(probe)
    except CatchableError as e:
      writeDetail = probeDir & " | " & e.msg

  checks.add(DoctorCheck(
    section: section,
    label: ctx.t("doctor.check.writable"),
    # 写不进去是必须修的问题,不是「本机没有」。
    state: if writable: csOk else: csUnusable,
    detail: writeDetail
  ))

  # 配置文件:不存在是正常的(首次运行),损坏才是问题。
  if ctx.settingsLoadError.len > 0:
    checks.add(DoctorCheck(
      section: section,
      label: ctx.t("doctor.check.settings"),
      state: csUnusable,
      detail: ctx.settingsLoadError
    ))
  elif not fileExists(p.settingsFile):
    checks.add(DoctorCheck(
      section: section,
      label: ctx.t("doctor.check.settings"),
      state: csMissing,
      detail: p.settingsFile
    ))
  else:
    checks.add(DoctorCheck(
      section: section,
      label: ctx.t("doctor.check.settings"),
      state: csOk,
      detail: p.settingsFile
    ))

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

proc problemCount(checks: seq[DoctorCheck]): int =
  ## 「存在但不可用」的数量。缺失不计入 —— 见模块顶部说明。
  for c in checks:
    if c.state == csUnusable:
      inc result

proc missingCount(checks: seq[DoctorCheck]): int =
  ## 「本机不具备」的数量。单独统计,以免摘要出现
  ## 「有 2 项缺失」却又说「全部检查通过」这种自相矛盾的读感。
  for c in checks:
    if c.state == csMissing:
      inc result

proc runDoctor(ctx: CliContext): int =
  var checks: seq[DoctorCheck] = @[]
  checkRuntime(ctx, checks)
  checkDevices(ctx, checks)
  checkStorage(ctx, checks)

  let problems = problemCount(checks)
  let missing = missingCount(checks)

  if ctx.isJson:
    var items = newJArray()
    for c in checks:
      items.add(%*{
        "section": c.section,
        "check": c.label,
        "state": $c.state,
        "detail": c.detail
      })
    emitJson(%*{
      "checks": items,
      "problems": problems,
      "missing": missing,
      "ok": problems == 0
    })
    return (if problems == 0: ExitSuccess else: ExitFailure)

  echo ctx.t("doctor.title")

  var currentSection = ""
  for c in checks:
    if c.section != currentSection:
      currentSection = c.section
      echo ""
      echo currentSection
    var line = "  " & stateMark(c.state) & " " & c.label &
      ": " & stateText(ctx, c.state)
    if c.detail.len > 0:
      line.add("  " & c.detail)
    echo line

  echo ""
  echo "  " & ctx.t("doctor.legend")
  echo ""
  if problems > 0:
    echo "  " & ctx.t("doctor.summary.problems", [$problems])
  elif missing > 0:
    # 不说「全部检查通过」——上面明明有几行写着「缺失」。
    echo "  " & ctx.t("doctor.summary.okWithMissing", [$missing])
  else:
    echo "  " & ctx.t("doctor.summary.ok")

  if not inferenceRuntimeAvailable():
    echo "  " & ctx.t("doctor.hint.runtime")

  result = if problems == 0: ExitSuccess else: ExitFailure

proc runDoctorCommand*(ctx: CliContext, args: seq[string]): int =
  ## `isvik doctor` 的入口。当前不接受位置参数。
  if args.len > 0:
    return reportUsageError(ctx,
      ctx.t("error.unknownSubcommand", ["doctor", args[0]]))
  try:
    result = runDoctor(ctx)
  except IsvikError as e:
    result = reportError(ctx, e)
