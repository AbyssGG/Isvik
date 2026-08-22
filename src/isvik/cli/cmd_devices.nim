## `isvik devices` —— 列出真实检测到的设备与 AUTO 策略结果
##
## ---
##
## ## 它必须回答的问题
##
## 用户看到 `GPU` 是不知道跑在哪张卡上的。本机有两个 GPU:`GPU.0` 是
## Intel iGPU,`GPU.1` 是 NVIDIA 独显。因此这个命令必须显示:
##
## ```text
## 每个设备的真实标识(GPU.0 / GPU.1,不是笼统的 GPU)
## 厂商(Intel / NVIDIA / Other / Unknown)
## 是否进入 AUTO 候选,不进入的原因是什么
## AUTO 最终选中谁
## ```
##
## ---
##
## ## 不伪造(§13 / §27)
##
## - 设备列表完全来自 Backend 的真实枚举,没有任何硬编码条目。
## - `FULL_DEVICE_NAME` 取不到时显示 `(无)`,**不用 rawName 冒充**。
## - 运行时不可用时报 `BACKEND_NOT_AVAILABLE`,而不是打印一张空表让用户
##   以为「这台机器没有设备」。
## - 被策略排除的设备**照常列出**并注明原因,不假装它不存在。
##
## 架构:本模块只 import `backends/factory`(返回 `Backend` 抽象),
## 不接触任何 OpenVINO 类型。

import std/[json, strutils]

import isvik/core/errors
import isvik/core/runtime
import isvik/backends/factory
import isvik/cli/context
import isvik/cli/output
import isvik/cli/exit_codes

proc statusText(ctx: CliContext, device: DeviceInfo): string =
  if device.policyEligible:
    ctx.t("devices.status.eligible")
  else:
    ctx.t("devices.status.excluded")

proc displayName(ctx: CliContext, device: DeviceInfo): string =
  ## 完整设备名。取不到时显示 `(无)` —— 不用 rawName 冒充(§27)。
  if device.fullName.len > 0: device.fullName else: ctx.t("common.none")

proc deviceToJson(device: DeviceInfo): JsonNode =
  ## 单个设备的 JSON 形态。
  ##
  ## `available` 与 `policyEligible` 都输出:前者是「Backend 检测到了」,
  ## 后者是「当前策略允许选它」。合成一个布尔会丢掉
  ## 「已检测但被排除」这个状态,而那恰好是 NVIDIA GPU 的情况。
  result = %*{
    "device": device.rawName,
    "deviceType": $device.deviceType,
    "ordinal": device.deviceId.ordinal,
    "fullName": device.fullName,
    "vendor": device.vendor,
    "vendorId": device.vendorId,
    "architecture": device.architecture,
    "available": device.available,
    "policyEligible": device.policyEligible,
    "exclusionReason": device.exclusionReason,
    "backend": device.backend
  }
  var caps = newJArray()
  for c in device.capabilities:
    caps.add(%($c))
  result["capabilities"] = caps

proc selectionToJson(selection: DeviceSelection): JsonNode =
  var attempts = newJArray()
  for a in selection.attempts:
    attempts.add(%*{
      "deviceType": $a.deviceType,
      "status": $a.status,
      "candidates": a.candidateIds,
      "excluded": a.excludedIds,
      "reason": a.reason
    })
  result = %*{
    "requested": selection.requested,
    "device": selection.device.rawName,
    "deviceType": $selection.device.deviceType,
    "fullName": selection.device.fullName,
    "usedAuto": selection.usedAuto,
    "reason": selection.reason,
    "attempts": attempts
  }

proc runDevices(ctx: CliContext): int =
  ## 枚举设备并打印。
  ##
  ## Runtime 生命周期严格配对:initialize 成功后必须 shutdown,
  ## 否则原生 Core 会一直留到进程退出才释放。
  let rt = newRuntime(newInferenceBackend())
  rt.initialize()

  try:
    let devices = rt.semanticDevices()

    # AUTO 解析单独 try:没有合格设备时它会抛错,但设备清单本身仍有价值 ——
    # 不能因为「AUTO 选不出来」就连已检测到的设备都不显示。
    var selection: DeviceSelection
    var selectionError: ref IsvikError = nil
    try:
      selection = rt.resolveDevice(DeviceRequestAuto)
    except IsvikError as e:
      selectionError = e

    if ctx.isJson:
      var deviceArray = newJArray()
      for d in devices:
        deviceArray.add(deviceToJson(d))
      var node = %*{
        "backend": rt.backendName,
        "backendVersion": rt.backendVersion,
        "devices": deviceArray
      }
      if selectionError == nil:
        node["auto"] = selectionToJson(selection)
      else:
        node["auto"] = %*{
          "requested": DeviceRequestAuto,
          "error": %*{
            "code": $selectionError.code,
            "message": selectionError.msg
          }
        }
      emitJson(node)
      return ExitSuccess

    # --- 文本输出 ---
    echo ctx.t("devices.title")
    echo ""

    if devices.len == 0:
      echo "  " & ctx.t("devices.none")
    else:
      var rows: seq[seq[string]] = @[]
      for d in devices:
        rows.add(@[
          d.rawName,
          $d.deviceType,
          d.vendor,
          statusText(ctx, d),
          displayName(ctx, d)
        ])
      for line in renderTable(
          [ctx.t("devices.col.device"), ctx.t("devices.col.type"),
           ctx.t("devices.col.vendor"), ctx.t("devices.col.status"),
           ctx.t("devices.col.name")], rows):
        echo line

    echo ""
    echo kvLine(ctx.t("devices.backend"),
                rt.backendName & " / " & rt.backendVersion)

    # 被排除的设备单独列一段并说明原因 —— 用户最容易困惑的正是
    # 「我明明有一张显卡,为什么 AUTO 不用它」。
    var excluded: seq[DeviceInfo] = @[]
    for d in devices:
      if d.available and not d.policyEligible:
        excluded.add(d)
    if excluded.len > 0:
      echo ""
      echo ctx.t("devices.excludedTitle")
      for d in excluded:
        echo "  " & ctx.t("devices.excludedLine",
                          [d.rawName, d.exclusionReason])
      echo "  " & ctx.t("devices.hint.excluded")

    echo ""
    echo ctx.t("devices.autoTitle")
    echo "  " & ctx.t("devices.autoOrder")
    if selectionError == nil:
      let suffix =
        if selection.device.fullName.len > 0:
          "  (" & selection.device.fullName & ")"
        else:
          ""
      echo "  " & ctx.t("devices.autoSelected",
                        [selection.device.rawName, suffix])
      if ctx.isVerbose:
        for a in selection.attempts:
          var line = "    " & $a.deviceType & ": " & $a.status
          if a.excludedIds.len > 0:
            line.add("  excluded=" & a.excludedIds.join(","))
          line.add("  (" & a.reason & ")")
          echo line
    else:
      echo "  " & ctx.t("devices.autoFailed",
                        [$selectionError.code, selectionError.msg])

    result = ExitSuccess
  finally:
    rt.shutdown()

proc runDevicesCommand*(ctx: CliContext, args: seq[string]): int =
  ## `isvik devices` 的入口。当前不接受位置参数。
  if args.len > 0:
    return reportUsageError(ctx,
      ctx.t("error.unknownSubcommand", ["devices", args[0]]))
  try:
    result = runDevices(ctx)
  except IsvikError as e:
    result = reportError(ctx, e)
