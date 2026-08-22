## 随机采样测试
##
## 采样的错误是**静默**的:输出仍然是通顺文本,只是不再反映模型的分布。
## 因此这里不测「没报错」,而是测可判定的性质:
##
## ```text
## temperature=0        必须与贪心逐位相同
## 同 seed 同参数        必须逐位可复现
## topK=1 / topP→0       退化为确定性,与 seed 无关
## banned / NaN          与贪心一致地被跳过
## ```

import std/[random, unittest]

import isvik/core/errors
import isvik/core/tensor
import isvik/inference/greedy
import isvik/inference/sampling

proc logits3d(values: openArray[float32], sequence, vocab: int): Tensor =
  newTensor(etF32, [1, sequence, vocab], values)

proc flat(values: openArray[float32]): Tensor =
  logits3d(values, 1, values.len)

proc drawMany(t: Tensor, cfg: SamplingConfig, count: int): seq[int] =
  ## 用同一个 RNG 连续抽样 count 次,返回 token 序列。
  var prepared = newSamplingRng(cfg)
  result = @[]
  for _ in 0 ..< count:
    result.add(sampleChoice(t, cfg, prepared.rng).tokenId)

suite "采样配置":

  test "默认配置是贪心":
    check greedySamplingConfig().isGreedy
    check initSamplingConfig().isGreedy

  test "温度为 0 或极小值都算贪心":
    # 不直接用 == 0.0:极小温度会让 logit/temperature 溢出成 inf,
    # softmax 得到 NaN,最终静默选出错误 token。
    check initSamplingConfig(temperature = 0.0).isGreedy
    check initSamplingConfig(temperature = 1.0e-9).isGreedy
    check not initSamplingConfig(temperature = 0.7).isGreedy

  test "未声明的温度(NaN)算贪心而不是某个具体温度":
    # gen_defaults 用 NaN 表示模型没声明温度。把未声明当成具体值
    # 就是在编造模型行为。
    check initSamplingConfig(temperature = NaN).isGreedy

  test "非法温度与 top_p 被拒绝":
    for bad in [-0.1, 2.1, 100.0]:
      expect IsvikError:
        initSamplingConfig(temperature = bad).requireValid()
    expect IsvikError:
      initSamplingConfig(temperature = 0.8, topP = 1.5).requireValid()

  test "合法取值通过校验":
    initSamplingConfig(temperature = 0.0).requireValid()
    initSamplingConfig(temperature = 2.0).requireValid()
    initSamplingConfig(temperature = 0.7, topP = 1.0, topK = 5).requireValid()
    check true

  test "未指定 seed 时也会给出一个具体 seed":
    # 否则「模型有时输出乱码」这类报告无法复查。
    let cfg = initSamplingConfig(temperature = 0.8)
    let seed = cfg.resolveSeed()
    check seed != 0

  test "指定 seed 时原样使用":
    let cfg = initSamplingConfig(temperature = 0.8, seed = 12345,
                                 seedSpecified = true)
    check cfg.resolveSeed() == 12345

suite "采样退化为贪心的情形":

  test "temperature=0 与 greedyChoice 结果完全一致":
    # 这条等价关系必须成立:否则「温度 0」在两条路径上含义不同。
    let t = flat([0.1'f32, 2.5, 0.3, 2.5, 1.0])
    var rng = initRand(1)
    let sampled = sampleChoice(t, greedySamplingConfig(), rng)
    let greedy = greedyChoice(t)
    check sampled.tokenId == greedy.tokenId
    check sampled.logit == greedy.logit
    # 平票取较小 id,与贪心同一规则。
    check sampled.tokenId == 1

  test "topK=1 时与 seed 无关,恒为 argmax":
    let t = flat([0.5'f32, 3.0, 1.0, 2.0])
    for seed in [1'i64, 2, 999, 123456]:
      let cfg = initSamplingConfig(temperature = 1.0, topK = 1,
                                   seed = seed, seedSpecified = true)
      check drawMany(t, cfg, 8) == @[1, 1, 1, 1, 1, 1, 1, 1]

  test "topP 极小时只剩最高概率的一个候选":
    # 至少保留一个:topP 再小也必须有东西可选。
    let t = flat([0.5'f32, 3.0, 1.0, 2.0])
    let cfg = initSamplingConfig(temperature = 1.0, topP = 1.0e-6,
                                 seed = 7, seedSpecified = true)
    check drawMany(t, cfg, 6) == @[1, 1, 1, 1, 1, 1]

suite "采样的可复现性":

  test "同 seed 同参数给出逐位相同的序列":
    let t = flat([1.0'f32, 1.2, 0.9, 1.1, 1.05])
    let cfg = initSamplingConfig(temperature = 1.0, seed = 4242,
                                 seedSpecified = true)
    let first = drawMany(t, cfg, 24)
    let second = drawMany(t, cfg, 24)
    check first == second
    # 抽样必须真的有随机性,否则这条测试会因为「恒定输出」而假通过。
    var seen: seq[int] = @[]
    for id in first:
      if id notin seen:
        seen.add(id)
    check seen.len > 1

  test "不同 seed 给出不同序列":
    let t = flat([1.0'f32, 1.2, 0.9, 1.1, 1.05])
    proc seqFor(seed: int64): seq[int] =
      drawMany(t, initSamplingConfig(temperature = 1.0, seed = seed,
                                     seedSpecified = true), 24)
    check seqFor(1) != seqFor(2)

  test "所有抽出的 token 都在词表范围内":
    let t = flat([1.0'f32, 1.2, 0.9, 1.1, 1.05])
    let cfg = initSamplingConfig(temperature = 1.5, seed = 11,
                                 seedSpecified = true)
    for id in drawMany(t, cfg, 200):
      check id >= 0
      check id < 5

suite "采样与贪心共享的过滤规则":

  test "banned token 不会被抽中":
    let t = flat([5.0'f32, 4.9, 4.8, 0.1])
    let cfg = initSamplingConfig(temperature = 1.0, seed = 3,
                                 seedSpecified = true)
    var rng = newSamplingRng(cfg).rng
    for _ in 0 ..< 100:
      let id = sampleChoice(t, cfg, rng, [0, 1]).tokenId
      check id != 0
      check id != 1

  test "NaN 被跳过而不是毒化整个分布":
    # 任何与 NaN 的比较都是 false;不显式跳过会让它污染归一化。
    let t = flat([NaN.float32, 2.0, 1.0])
    let cfg = initSamplingConfig(temperature = 1.0, seed = 5,
                                 seedSpecified = true)
    for id in drawMany(t, cfg, 50):
      check id != 0

  test "全部被屏蔽时报 INFERENCE_FAILED 而不是返回垃圾":
    let t = flat([1.0'f32, 2.0])
    let cfg = initSamplingConfig(temperature = 1.0, seed = 5,
                                 seedSpecified = true)
    var rng = newSamplingRng(cfg).rng
    var code = ecServerError
    try:
      discard sampleChoice(t, cfg, rng, [0, 1])
    except IsvikError as e:
      code = e.code
    check code == ecInferenceFailed

  test "非 F32 logits 报 NOT_IMPLEMENTED 而不是按 F32 硬读":
    # F16 每元素 2 字节,构造时必须用同宽的 Nim 类型 —— 张量会校验这一点。
    let t = newTensor(etF16, [1, 1, 4], @[0'u16, 0, 0, 0])
    let cfg = initSamplingConfig(temperature = 1.0, seed = 5,
                                 seedSpecified = true)
    var rng = newSamplingRng(cfg).rng
    var code = ecServerError
    try:
      discard sampleChoice(t, cfg, rng)
    except IsvikError as e:
      code = e.code
    check code == ecNotImplemented

  test "nil logits 被拒绝":
    let cfg = initSamplingConfig(temperature = 1.0, seed = 5,
                                 seedSpecified = true)
    var rng = newSamplingRng(cfg).rng
    expect IsvikError:
      discard sampleChoice(nil, cfg, rng)

suite "温度对分布的影响":

  test "低温更集中,高温更分散":
    # 只断言方向,不断言具体比例:后者依赖 RNG 实现,换 Nim 版本就会碎。
    let t = flat([2.0'f32, 1.0, 0.5, 0.2])
    proc topShare(temperature: float): float =
      let cfg = initSamplingConfig(temperature = temperature, seed = 20240820,
                                   seedSpecified = true)
      let draws = drawMany(t, cfg, 400)
      var hits = 0
      for id in draws:
        if id == 0:
          inc hits
      result = hits / draws.len

    let cold = topShare(0.3)
    let hot = topShare(2.0)
    checkpoint("cold=" & $cold & " hot=" & $hot)
    check cold > hot
