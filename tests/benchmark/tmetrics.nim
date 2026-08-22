## Benchmark 度量与统计测试
##
## §35 禁止 Fake Benchmark。真正的风险不是有人故意造假,而是统计代码在数据
## 不足时给出一个看起来合理的数 —— 那种错误无法通过「跑一次看看」发现,
## 因为输出本来就是一堆数字。
##
## 因此这里逐条断言退化情形:1 个 token、0 耗时、空样本、部分未知。

import std/unittest

import isvik/benchmark/metrics

proc sample(index: int, promptTokens, generatedTokens: int,
            prefillMs, decodeMs, totalMs: float,
            stopReason = "end_of_sequence"): BenchmarkSample =
  BenchmarkSample(
    index: index,
    promptTokens: promptTokens,
    generatedTokens: generatedTokens,
    prefillMs: prefillMs,
    decodeMs: decodeMs,
    totalMs: totalMs,
    stopReason: stopReason
  )

suite "未知值的表达":

  test "UnknownMetric 是负值,不可能被误认为测量结果":
    check UnknownMetric < 0.0
    check not isKnown(UnknownMetric)

  test "0 与正数都是有效测量":
    check isKnown(0.0)
    check isKnown(12.5)

  test "NaN 不是有效测量":
    # NaN 在比较与排序里会静默传播,污染整批统计。
    check not isKnown(NaN)

  test "未知值格式化为 n/a 而不是一个数字":
    # 展示层的最后一道防线:哪怕上游漏了判断,报表里也不会出现凭空的 0.0。
    check formatMetric(UnknownMetric) == "n/a"
    check formatMetric(NaN) == "n/a"
    check formatMetric(12.34, 2) == "12.34"

suite "首 token 延迟":

  test "正常样本给出 prefill 耗时":
    check sample(0, 10, 20, 150.0, 500.0, 650.0).firstTokenMs() == 150.0

  test "一个 token 都没生成时没有首 token":
    # 返回 prefillMs 会把「什么都没产出」说成一个延迟数字。
    check sample(0, 10, 0, 150.0, 0.0, 150.0).firstTokenMs() == UnknownMetric

  test "prefill 为负时视为未知":
    check sample(0, 10, 5, -1.0, 100.0, 200.0).firstTokenMs() == UnknownMetric

suite "解码吞吐":

  test "分子是首 token 之后的 token 数":
    # prefill 与 decode 是两种计算模式,混在一个吞吐里会同时低估解码速度、
    # 高估端到端速度。11 个 token 里只有 10 个属于解码阶段。
    let s = sample(0, 5, 11, 100.0, 1000.0, 1100.0)
    check abs(s.decodeTokensPerSecond() - 10.0) < 1e-9

  test "只生成一个 token 时解码阶段不存在":
    # 返回 0 会被读成「慢」,返回 inf 会被读成「快」,两者都是谎。
    check sample(0, 5, 1, 100.0, 0.0, 100.0).decodeTokensPerSecond() ==
      UnknownMetric

  test "零个 token 同样是未知":
    check sample(0, 5, 0, 0.0, 0.0, 0.0).decodeTokensPerSecond() ==
      UnknownMetric

  test "decodeMs 为 0 时不除零":
    check sample(0, 5, 10, 100.0, 0.0, 100.0).decodeTokensPerSecond() ==
      UnknownMetric

suite "端到端吞吐":

  test "生成 token 数除以总耗时":
    let s = sample(0, 5, 20, 100.0, 900.0, 1000.0)
    check abs(s.totalTokensPerSecond() - 20.0) < 1e-9

  test "没有输出时未知":
    check sample(0, 5, 0, 0.0, 0.0, 50.0).totalTokensPerSecond() ==
      UnknownMetric

  test "总耗时为 0 时不除零":
    check sample(0, 5, 3, 0.0, 0.0, 0.0).totalTokensPerSecond() ==
      UnknownMetric

suite "分位数":

  test "空序列返回未知而不是 0":
    check percentile([], 0.5) == UnknownMetric

  test "单元素序列的任何分位数都是它自己":
    check percentile([7.0], 0.0) == 7.0
    check percentile([7.0], 0.95) == 7.0

  test "分位数总是序列里真实存在的观测":
    # 不做线性插值:插值会产生样本里并不存在的数值,而「p95 是某次真实观测」
    # 可以去查那一次到底发生了什么。
    let values = [1.0, 2.0, 3.0, 4.0]
    for f in [0.0, 0.25, 0.5, 0.75, 1.0, 0.95]:
      check percentile(values, f) in values

  test "两端取到最小与最大":
    let values = [10.0, 20.0, 30.0]
    check percentile(values, 0.0) == 10.0
    check percentile(values, 1.0) == 30.0

  test "越界比例被夹到有效范围":
    let values = [10.0, 20.0, 30.0]
    check percentile(values, -5.0) == 10.0
    check percentile(values, 5.0) == 30.0

suite "统计汇总":

  test "全部有效时各项正确":
    let stats = summarize([10.0, 20.0, 30.0, 40.0])
    check stats.count == 4
    check abs(stats.mean - 25.0) < 1e-9
    check stats.minimum == 10.0
    check stats.maximum == 40.0

  test "未知值被剔除,不参与平均":
    # 一次「测不出来」不该把平均值拉低。
    let stats = summarize([10.0, UnknownMetric, 30.0])
    check stats.count == 2
    check abs(stats.mean - 20.0) < 1e-9

  test "全部未知时整组统计为未知":
    let stats = summarize([UnknownMetric, UnknownMetric])
    check stats.count == 0
    check stats.mean == UnknownMetric
    check stats.p50 == UnknownMetric

  test "空输入返回未知":
    check summarize([]).count == 0
    check summarize([]).mean == UnknownMetric

  test "有效样本比例可被读出":
    # 读者据此判断这批统计的可信度。
    let stats = summarize([1.0, UnknownMetric, 3.0])
    check knownRatio(stats, 3) == "2/3"
    check knownRatio(unknownStats(), 0) == "0/0"

suite "批量汇总":

  test "三组统计各自独立":
    let samples = @[
      sample(0, 5, 11, 100.0, 1000.0, 1100.0),
      sample(1, 5, 21, 120.0, 2000.0, 2120.0)
    ]
    let (firstToken, decodeRate, totalRate) = summarizeSamples(samples)
    check firstToken.count == 2
    check decodeRate.count == 2
    check totalRate.count == 2
    check firstToken.minimum == 100.0

  test "单 token 样本只影响解码吞吐这一项":
    # 它有首 token 延迟、有端到端吞吐,但没有解码阶段。
    let samples = @[
      sample(0, 5, 1, 100.0, 0.0, 100.0),
      sample(1, 5, 11, 100.0, 1000.0, 1100.0)
    ]
    let (firstToken, decodeRate, totalRate) = summarizeSamples(samples)
    check firstToken.count == 2
    check totalRate.count == 2
    # 只有第二个样本能给出解码吞吐。
    check decodeRate.count == 1

  test "空样本集不产生任何数字":
    let (firstToken, decodeRate, totalRate) = summarizeSamples([])
    check firstToken.mean == UnknownMetric
    check decodeRate.mean == UnknownMetric
    check totalRate.mean == UnknownMetric

suite "结论结构":

  test "实际设备与请求设备是两个独立字段":
    # 不如实回报会让读者把 CPU 的数字当成 NPU 的。
    var summary = BenchmarkSummary(
      model: "m", requestedDevice: "NPU", device: "CPU",
      warmupRuns: 1, samples: @[]
    )
    check summary.requestedDevice != summary.device
    check summary.warmupRuns == 1

  test "预热次数被单独记录":
    # 首次运行含编译与页缓存预热,混进平均会让结果偏慢且不可复现。
    var summary = BenchmarkSummary(warmupRuns: 2)
    check summary.warmupRuns == 2
