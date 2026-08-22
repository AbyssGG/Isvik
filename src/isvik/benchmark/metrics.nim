## Benchmark 度量与统计(Master Prompt §35)
##
## ---
##
## ## 本模块的唯一职责:不产出假数字
##
## §35 明令禁止 Fake Benchmark、硬编码结果、编造的 NPU 数据。真正危险的不是
## 有人故意造假,而是**统计代码在数据不足时给出一个看起来合理的数**:
##
## ```text
## 只生成了 1 个 token   →  解码吞吐没有定义。返回 0 会被读成「慢」,
##                          返回 inf 会被读成「快」,两者都是谎。
## decodeMs = 0          →  除零。
## 样本数为 0            →  平均值没有定义。
## ```
##
## 因此本模块用 `UnknownMetric`(负值)表示「测不出来」,并且**从不**把它
## 参与平均。调用方必须显式处理未知,而不是让它静默混进结果。
##
## ---
##
## ## 为什么统计是纯函数
##
## 度量正确性无法靠跑一次 benchmark 验证 —— 输出是一堆数字,对错看不出来。
## 把统计独立成纯函数后,可以用构造好的样本断言每一条规则,包括上面那些
## 退化情形。

import std/[algorithm, math, strutils]

const
  UnknownMetric* = -1.0
    ## 「测不出来」。用负值而不是 0 或 NaN:
    ##
    ## - 0 会被读成「非常慢」,是错误的事实陈述。
    ## - NaN 在比较与排序里会静默传播,污染整批统计。
    ##
    ## 负值不可能是合法的耗时或吞吐,因此不会被误认为测量结果。

type
  BenchmarkSample* = object
    ## 一次生成的真实测量。字段全部来自实际运行,没有推算项。
    index*: int
    promptTokens*: int
    generatedTokens*: int
    prefillMs*: float
      ## 到**第一个** token 产出的耗时。
    decodeMs*: float
      ## 第一个 token 之后的解码总耗时。生成 ≤1 个 token 时为 0。
    totalMs*: float
    stopReason*: string
      ## 如实记录为什么停。被长度截断的样本与自然结束的样本混在一起算平均
      ## 是有意义的,但读者需要知道比例。

  MetricStats* = object
    ## 一组数值的统计。样本不足时各项为 `UnknownMetric`。
    count*: int
      ## 参与统计的**有效**样本数,不含未知值。
    mean*: float
    minimum*: float
    maximum*: float
    p50*: float
    p95*: float

  BenchmarkSummary* = object
    ## 一次 benchmark 的完整结论。
    model*: string
    requestedDevice*: string
    device*: string
      ## **实际**执行的设备。与 requestedDevice 不同时说明发生了 AUTO 决策
      ## 或 CPU 回落 —— 必须如实回报,否则读者会把 CPU 的数字当成 NPU 的。
    backend*: string
    backendVersion*: string
    promptText*: string
    maxNewTokens*: int
    warmupRuns*: int
      ## 预热次数。预热样本**不计入**统计:首次运行含编译与页缓存预热,
      ## 把它混进平均会让结果偏慢且不可复现。
    samples*: seq[BenchmarkSample]
    firstTokenMs*: MetricStats
    decodeTokensPerSecond*: MetricStats
    totalTokensPerSecond*: MetricStats
    samplingSeed*: int64
      ## 采样 seed;贪心时为 0。写出来使同一组数字可以被复算。

proc initBenchmarkSample*(index: int): BenchmarkSample =
  BenchmarkSample(
    index: index,
    promptTokens: 0,
    generatedTokens: 0,
    prefillMs: 0.0,
    decodeMs: 0.0,
    totalMs: 0.0,
    stopReason: ""
  )

proc isKnown*(value: float): bool =
  ## 该数值是否是一次真实测量。
  value >= 0.0 and value.classify != fcNan

proc unknownStats*(): MetricStats =
  MetricStats(
    count: 0,
    mean: UnknownMetric,
    minimum: UnknownMetric,
    maximum: UnknownMetric,
    p50: UnknownMetric,
    p95: UnknownMetric
  )

proc firstTokenMs*(sample: BenchmarkSample): float =
  ## 首 token 延迟。
  ##
  ## 一个 token 都没生成时没有「首 token」,返回未知 —— 返回 prefillMs
  ## 会把「什么都没产出」说成一个延迟数字。
  if sample.generatedTokens <= 0 or not isKnown(sample.prefillMs):
    return UnknownMetric
  sample.prefillMs

proc decodeTokensPerSecond*(sample: BenchmarkSample): float =
  ## 解码阶段吞吐(不含首 token)。
  ##
  ## 分子是**首 token 之后**的 token 数:prefill 与 decode 是两个不同的
  ## 计算模式,把它们混在一个吞吐里会同时低估解码速度、高估端到端速度。
  ##
  ## 只生成 1 个 token 时解码阶段不存在,返回未知而不是 0。
  if sample.generatedTokens <= 1:
    return UnknownMetric
  if sample.decodeMs <= 0.0 or not isKnown(sample.decodeMs):
    return UnknownMetric
  float(sample.generatedTokens - 1) / (sample.decodeMs / 1000.0)

proc totalTokensPerSecond*(sample: BenchmarkSample): float =
  ## 端到端吞吐:生成的 token 数 ÷ 总耗时。
  if sample.generatedTokens <= 0:
    return UnknownMetric
  if sample.totalMs <= 0.0 or not isKnown(sample.totalMs):
    return UnknownMetric
  float(sample.generatedTokens) / (sample.totalMs / 1000.0)

proc percentile*(sorted: openArray[float], fraction: float): float =
  ## 已排序序列的分位数,采用**最近秩**法。
  ##
  ## 不做线性插值:插值会产生一个样本里并不存在的数值。对 benchmark 而言
  ## 「p95 是某次真实观测」比「p95 是两次观测之间的估计」更有用 ——
  ## 前者可以去查那一次到底发生了什么。
  if sorted.len == 0:
    return UnknownMetric
  if sorted.len == 1:
    return sorted[0]
  var f = fraction
  if f < 0.0: f = 0.0
  if f > 1.0: f = 1.0
  var index = int(round(f * float(sorted.len - 1)))
  if index < 0: index = 0
  if index > sorted.len - 1: index = sorted.len - 1
  sorted[index]

proc summarize*(values: openArray[float]): MetricStats =
  ## 汇总一组数值。**未知值被剔除**,不参与任何计算。
  ##
  ## 剔除而不是当 0:一次「测不出来」不该把平均值拉低。剔除后 `count`
  ## 会小于样本总数,读者据此判断这批统计的可信度。
  var known: seq[float] = @[]
  for v in values:
    if isKnown(v):
      known.add(v)
  if known.len == 0:
    return unknownStats()

  sort(known)
  var total = 0.0
  for v in known:
    total += v

  MetricStats(
    count: known.len,
    mean: total / float(known.len),
    minimum: known[0],
    maximum: known[^1],
    p50: percentile(known, 0.5),
    p95: percentile(known, 0.95)
  )

proc summarizeSamples*(samples: openArray[BenchmarkSample]):
    tuple[firstToken, decodeRate, totalRate: MetricStats] =
  ## 从样本批量算出三组统计。
  var firstTokens: seq[float] = @[]
  var decodeRates: seq[float] = @[]
  var totalRates: seq[float] = @[]
  for sample in samples:
    firstTokens.add(sample.firstTokenMs())
    decodeRates.add(sample.decodeTokensPerSecond())
    totalRates.add(sample.totalTokensPerSecond())
  (summarize(firstTokens), summarize(decodeRates), summarize(totalRates))

proc formatMetric*(value: float, digits: int = 1): string =
  ## 格式化一个数值。未知时给出 `n/a` 而不是一个数字。
  ##
  ## 这是「不产出假数字」在展示层的最后一道:哪怕上游漏了判断,
  ## 报表里也不会出现一个凭空的 0.0。
  if not isKnown(value):
    return "n/a"
  formatFloat(value, ffDecimal, digits)

proc knownRatio*(stats: MetricStats, totalSamples: int): string =
  ## 「多少个样本给出了有效数值」。用于让读者判断统计的可信度。
  if totalSamples <= 0:
    return "0/0"
  $stats.count & "/" & $totalSamples
