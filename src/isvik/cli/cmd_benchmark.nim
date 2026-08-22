## `isvik benchmark <model>` —— 真实性能测量(§35)
##
## ---
##
## ## 展示层的责任:让读者不会误读
##
## 数字本身不会骗人,**呈现方式**会。这里有三条硬规则:
##
## 1. 实际设备与请求设备都打印。不一致时加一句明确说明。
## 2. 未知值显示 `n/a`,不显示 0。
## 3. 打印有效样本比例。`2/5` 与 `5/5` 的可信度不同。
##
## 另外打印预热次数与 prompt:没有这两项,别人无法复现同一组数字。

import std/[json, strutils]

import isvik/core/errors
import isvik/services/chat_session
import isvik/services/device_service
import isvik/benchmark/runner
import isvik/cli/context
import isvik/cli/output
import isvik/cli/exit_codes
import isvik/cli/cmd_chat

const
  DefaultBenchmarkPrompt* = "Explain what a local AI runtime does."
  DefaultBenchmarkRuns* = 5
  DefaultBenchmarkWarmup* = 1
  DefaultBenchmarkTokens* = 64

type
  BenchmarkArgs = object
    model: string
    device: string
    prompt: string
    runs: int
    warmup: int
    maxTokens: int

proc parseArgs(ctx: CliContext, args: seq[string]):
    tuple[ok: bool, parsed: BenchmarkArgs, exitCode: int] =
  var parsed = BenchmarkArgs(
    model: "",
    device: ctx.settings.defaultDevice,
    prompt: DefaultBenchmarkPrompt,
    runs: DefaultBenchmarkRuns,
    warmup: DefaultBenchmarkWarmup,
    maxTokens: DefaultBenchmarkTokens
  )
  var positional = 0
  var i = 0

  proc needsValue(flag: string): bool =
    i + 1 >= args.len

  while i < args.len:
    let arg = args[i]
    case arg
    of "--device", "--prompt", "--runs", "--warmup", "--max-tokens":
      if needsValue(arg):
        return (false, parsed,
                reportUsageError(ctx, ctx.t("benchmark.needsValue", [arg])))
      let value = args[i + 1]
      case arg
      of "--device": parsed.device = value
      of "--prompt": parsed.prompt = value
      else:
        var number = 0
        try:
          number = parseInt(value)
        except ValueError:
          return (false, parsed,
                  reportUsageError(ctx,
                    ctx.t("benchmark.badNumber", [arg, value])))
        case arg
        of "--runs": parsed.runs = number
        of "--warmup": parsed.warmup = number
        else: parsed.maxTokens = number
      i += 2
    else:
      if arg.startsWith("-"):
        return (false, parsed,
                reportUsageError(ctx, ctx.t("benchmark.usage")))
      inc positional
      if positional > 1:
        return (false, parsed,
                reportUsageError(ctx, ctx.t("benchmark.usage")))
      parsed.model = arg
      inc i
  (true, parsed, ExitSuccess)

proc statsJson(stats: MetricStats, total: int): JsonNode =
  ## 未知值输出 JSON null,而不是 0 或负的哨兵值。
  ##
  ## 让哨兵值出现在 JSON 里等于把内部约定泄漏给脚本,而脚本很可能直接
  ## 把 -1 当成一个测量结果画进图表。
  proc value(v: float): JsonNode =
    if isKnown(v): %v else: newJNull()
  %*{
    "count": stats.count,
    "totalSamples": total,
    "mean": value(stats.mean),
    "min": value(stats.minimum),
    "max": value(stats.maximum),
    "p50": value(stats.p50),
    "p95": value(stats.p95)
  }

proc summaryJson(summary: BenchmarkSummary): JsonNode =
  var samples = newJArray()
  for s in summary.samples:
    samples.add(%*{
      "index": s.index,
      "promptTokens": s.promptTokens,
      "generatedTokens": s.generatedTokens,
      "prefillMs": s.prefillMs,
      "decodeMs": s.decodeMs,
      "totalMs": s.totalMs,
      "stopReason": s.stopReason
    })
  let total = summary.samples.len
  result = %*{
    "model": summary.model,
    "requestedDevice": summary.requestedDevice,
    # 实际设备单独成字段。读者最容易犯的错是把回落后的 CPU 数字
    # 当成请求设备的性能。
    "device": summary.device,
    "deviceFellBack": summary.fellBackToCpu(),
    "backend": summary.backend,
    "backendVersion": summary.backendVersion,
    "prompt": summary.promptText,
    "maxNewTokens": summary.maxNewTokens,
    "warmupRuns": summary.warmupRuns,
    "samplingSeed": summary.samplingSeed,
    "firstTokenMs": statsJson(summary.firstTokenMs, total),
    "decodeTokensPerSecond": statsJson(summary.decodeTokensPerSecond, total),
    "totalTokensPerSecond": statsJson(summary.totalTokensPerSecond, total),
    "samples": samples
  }

proc printSummary(ctx: CliContext, summary: BenchmarkSummary) =
  let total = summary.samples.len
  echo ""
  echo ctx.t("benchmark.title")
  echo ""
  echo kvLine(ctx.t("benchmark.field.model"), summary.model)
  echo kvLine(ctx.t("benchmark.field.requestedDevice"),
              summary.requestedDevice)
  echo kvLine(ctx.t("benchmark.field.device"), summary.device)
  if summary.backend.len > 0:
    echo kvLine(ctx.t("benchmark.field.backend"),
                summary.backend & " / " & summary.backendVersion)
  echo kvLine(ctx.t("benchmark.field.runs"),
              $total & " (+" & $summary.warmupRuns & " warmup)")
  echo kvLine(ctx.t("benchmark.field.maxTokens"), $summary.maxNewTokens)
  echo kvLine(ctx.t("benchmark.field.prompt"), summary.promptText)
  echo ""

  proc row(label: string, stats: MetricStats, digits: int): seq[string] =
    @[
      label,
      formatMetric(stats.mean, digits),
      formatMetric(stats.p50, digits),
      formatMetric(stats.p95, digits),
      formatMetric(stats.minimum, digits),
      formatMetric(stats.maximum, digits),
      knownRatio(stats, total)
    ]

  var rows: seq[seq[string]] = @[]
  rows.add(row(ctx.t("benchmark.metric.firstToken"),
               summary.firstTokenMs, 1))
  rows.add(row(ctx.t("benchmark.metric.decodeRate"),
               summary.decodeTokensPerSecond, 2))
  rows.add(row(ctx.t("benchmark.metric.totalRate"),
               summary.totalTokensPerSecond, 2))

  for line in renderTable(
      [ctx.t("benchmark.col.metric"), ctx.t("benchmark.col.mean"),
       ctx.t("benchmark.col.p50"), ctx.t("benchmark.col.p95"),
       ctx.t("benchmark.col.min"), ctx.t("benchmark.col.max"),
       ctx.t("benchmark.col.valid")], rows):
    echo line

  echo ""
  if summary.fellBackToCpu():
    # 不加这句,读者会把 CPU 的数字当成请求设备的性能。
    echo "  " & ctx.t("benchmark.deviceMismatch",
                      [summary.requestedDevice, summary.device])
  echo "  " & ctx.t("benchmark.note.greedy")
  echo "  " & ctx.t("benchmark.note.observation")

proc runBenchmarkCommand*(ctx: CliContext, args: seq[string]): int =
  let parsed = parseArgs(ctx, args)
  if not parsed.ok:
    return parsed.exitCode
  let a = parsed.parsed

  try:
    let resolved = resolveModelDir(ctx, a.model)
    let extPath = resolveExtensionPath("", resolved.dir)
    var options = initBenchmarkOptions(a.prompt, a.maxTokens, a.runs, a.warmup)
    options.requireValid()

    if not ctx.isJson:
      echo ctx.t("chat.loading")

    # 设备解析与 CPU 回落用与 chat / 工作台完全相同的判据(§20.5.10)。
    var session: ChatSession = nil
    try:
      session = openChatSession(resolved.dir, resolved.label, a.device,
                                extPath, a.maxTokens)
    except IsvikError as e:
      if not allowsCpuFallback(e.code, a.device):
        raise e
      if not ctx.isJson:
        echo "  " & ctx.t("chat.deviceFallback", [a.device, e.msg])
      session = openChatSession(resolved.dir, resolved.label,
                                DeviceRequestCpu, extPath, a.maxTokens)

    let deviceSvc = openDeviceService()
    var backendName = ""
    var backendVersion = ""
    try:
      backendName = deviceSvc.backendName()
      backendVersion = deviceSvc.backendVersion()
    finally:
      deviceSvc.close()

    try:
      let onProgress: ProgressCallback =
        if ctx.isJson: nil
        else:
          proc (phase: string, index, total: int) =
            # 跑一次几十秒,没有反馈会让人以为卡死了。
            stderr.writeLine("  " & phase & " " & $index & "/" & $total)

      let summary = runBenchmark(session, a.device, options,
                                 backendName, backendVersion, onProgress)
      if ctx.isJson:
        emitJson(summaryJson(summary))
      else:
        printSummary(ctx, summary)
      result = ExitSuccess
    finally:
      session.close()
  except IsvikError as e:
    result = reportError(ctx, e)
