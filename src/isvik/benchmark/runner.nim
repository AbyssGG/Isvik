## Benchmark 执行器(Master Prompt §35)
##
## ---
##
## ## 它只报告真实跑过的东西
##
## §35 禁止:Fake Benchmark、硬编码结果、编造的 NPU 结果。落实为三条:
##
## 1. **设备如实回报。** 请求 NPU 而实际跑在 CPU 上时,结论里的 `device`
##    是 CPU。绝不把 CPU 的数字挂在 NPU 名下。
## 2. **失败就是失败。** 某个设备编译不过就报错退出,不静默换设备再出数。
## 3. **预热样本不计入统计。** 首次运行含模型编译与页缓存预热。
##
## ---
##
## ## 为什么用 ChatSession 而不是 InferenceService
##
## `UnifiedInferenceResult` 不带耗时字段(它是协议层的结果),而 benchmark
## 恰恰只关心耗时。`ChatSession.send` 返回的 `GenerationResult` 含
## `prefillMs` / `decodeMs` / `totalMs` —— 这些是解码循环里实测的,
## 不是在外面用秒表估的。
##
## 每轮之前清空历史:否则第二轮的 prompt 里多了第一轮的问答,
## token 数不同,几轮的数字就不可比。

import std/strutils

import isvik/core/errors
import isvik/inference/sampling
import isvik/inference/text_generator
import isvik/services/chat_session
import isvik/benchmark/metrics

export metrics

type
  BenchmarkOptions* = object
    prompt*: string
    maxNewTokens*: int
    runs*: int
      ## 计入统计的运行次数。
    warmupRuns*: int
      ## 预热次数,不计入统计。
    sampling*: SamplingConfig
      ## 默认贪心。benchmark 用贪心是刻意的:随机采样会让每轮生成的 token
      ## 数不同,而 token 数直接决定耗时 —— 那样测出来的是运气,不是性能。

  ProgressCallback* = proc (phase: string, index, total: int) {.closure.}
    ## 进度回调。跑一次几十秒,没有反馈会让人以为卡死了。

proc initBenchmarkOptions*(prompt: string, maxNewTokens = 64, runs = 5,
                           warmupRuns = 1): BenchmarkOptions =
  BenchmarkOptions(
    prompt: prompt,
    maxNewTokens: maxNewTokens,
    runs: runs,
    warmupRuns: warmupRuns,
    sampling: greedySamplingConfig()
  )

proc validate*(options: BenchmarkOptions): string =
  ## 校验选项。返回空串表示合法。
  if options.prompt.len == 0:
    return "prompt must not be empty"
  if options.maxNewTokens <= 0:
    return "maxNewTokens must be positive, got: " & $options.maxNewTokens
  if options.runs <= 0:
    return "runs must be positive, got: " & $options.runs
  if options.warmupRuns < 0:
    return "warmupRuns must not be negative, got: " & $options.warmupRuns
  result = ""

proc requireValid*(options: BenchmarkOptions) =
  let problem = options.validate()
  if problem.len > 0:
    raiseIsvikError(ecInvalidParameter, "Invalid benchmark options", problem)

proc toSample(index: int, generated: GenerationResult): BenchmarkSample =
  ## 把一次真实生成转成样本。**逐字段搬运**,不做任何推算。
  BenchmarkSample(
    index: index,
    promptTokens: generated.promptTokens,
    generatedTokens: generated.generatedTokens,
    prefillMs: generated.prefillMs,
    decodeMs: generated.decodeMs,
    totalMs: generated.totalMs,
    stopReason: $generated.stopReason
  )

proc runBenchmark*(session: ChatSession, requestedDevice: string,
                   options: BenchmarkOptions,
                   backendName = "", backendVersion = "",
                   onProgress: ProgressCallback = nil): BenchmarkSummary =
  ## 在一个**已加载**的会话上跑 benchmark。
  ##
  ## 会话由调用方打开:那一步涉及设备解析与 CPU 回落策略,属于
  ## `services/device_service` 与 CLI 的职责,不该在度量代码里重做。
  options.requireValid()
  if session == nil:
    raiseIsvikError(ecInvalidParameter, "Benchmark requires an open session",
                    "reason=nil-session")

  var samples: seq[BenchmarkSample] = @[]
  var seedUsed: int64 = 0

  proc runOnce(): GenerationResult =
    # 每轮之前清空历史:否则后续轮次的 prompt 变长,几轮的数字不可比。
    session.clearHistory()
    result = session.send(options.prompt)

  for i in 0 ..< options.warmupRuns:
    if onProgress != nil:
      onProgress("warmup", i + 1, options.warmupRuns)
    # 预热结果被丢弃,但异常不吞:预热失败说明这个配置根本跑不起来。
    discard runOnce()

  for i in 0 ..< options.runs:
    if onProgress != nil:
      onProgress("measure", i + 1, options.runs)
    let generated = runOnce()
    samples.add(toSample(i, generated))
    if generated.samplingSeed != 0:
      seedUsed = generated.samplingSeed

  let stats = summarizeSamples(samples)
  result = BenchmarkSummary(
    model: session.model(),
    requestedDevice: requestedDevice,
    # 实际设备来自会话本身,而不是请求值。
    device: session.device(),
    backend: backendName,
    backendVersion: backendVersion,
    promptText: options.prompt,
    maxNewTokens: options.maxNewTokens,
    warmupRuns: options.warmupRuns,
    samples: samples,
    firstTokenMs: stats.firstToken,
    decodeTokensPerSecond: stats.decodeRate,
    totalTokensPerSecond: stats.totalRate,
    samplingSeed: seedUsed
  )

proc fellBackToCpu*(summary: BenchmarkSummary): bool =
  ## 请求的设备与实际设备是否不一致。
  ##
  ## 展示层据此加一句说明:读者最容易犯的错就是把回落后的 CPU 数字
  ## 当成请求设备的性能。
  summary.requestedDevice.len > 0 and
    summary.device.len > 0 and
    not summary.device.startsWith(summary.requestedDevice)
