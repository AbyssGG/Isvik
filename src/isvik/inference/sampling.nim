## 随机采样(温度 / top-k / top-p)
##
## ---
##
## ## 与 greedy.nim 的分工
##
## `greedy.nim` 是确定性的 argmax,本模块是**有随机性**的采样。两者共用
## `LogitsView` 与「跳过 banned、跳过 NaN」的取舍,但目标不同:
##
## ```text
## greedy    可复现,端到端测试能对输出做真断言
## sampling  可控随机,给同一提示不同的合理回答
## ```
##
## `temperature <= 0` 时本模块**直接委托 greedyChoice**,而不是自己写一份
## argmax。理由是「temperature=0 等于贪心」这条等价关系必须在代码里只有一个
## 实现 —— 两份实现会在平票规则(取较小 id)上慢慢分叉,而那种分叉只表现为
## 「CPU 与 NPU 输出不同」,极难归因。
##
## ---
##
## ## 随机性必须可复现
##
## 采样默认不可复现,这会让 bug 报告失去意义:「模型有时会输出乱码」无法
## 复查。因此:
##
## - `seed` 显式给出时,同 seed + 同提示 + 同参数必然给出同一结果。
## - `seed` 未给出时**也会生成一个具体的 seed 并如实回报**(见
##   `resolveSeed` 与 `GenerationResult.samplingSeed`),而不是让它消失。
##
## ---
##
## ## 过滤顺序
##
## ```text
## temperature  →  top-k  →  top-p  →  归一化  →  抽样
## ```
##
## 顺序不是随意的:top-p 是对**概率**的截断,必须在温度缩放之后算,否则
## 「保留累计 90% 概率」这句话指的就不是最终分布的 90%。

import std/[math, algorithm, random, times]

import isvik/core/errors
import isvik/core/tensor
import isvik/inference/greedy

export greedy.TokenChoice

const
  GreedyTemperatureThreshold* = 1.0e-6
    ## 低于此值的温度按贪心处理。
    ##
    ## 不直接用 `== 0.0`:极小的温度会让 `logit / temperature` 溢出成 inf,
    ## 于是 softmax 得到 NaN,最终静默选出错误的 token。与其在数值上冒险,
    ## 不如把「温度小到没有随机性」明确等同于贪心。

type
  SamplingConfig* = object
    ## 采样参数的解码侧形态。
    ##
    ## 与 `core/inference.InferenceParameters` 的区别是那边用 `Option` 表达
    ## 「未指定」,而到了这一层必须已经决定好:未指定的项在这里表现为
    ## 「不生效的取值」(温度 0 / topK 0 / topP 0),由服务层完成映射。
    temperature*: float
      ## <= `GreedyTemperatureThreshold` 表示贪心。
    topK*: int
      ## <= 0 表示不限制候选数量。
    topP*: float
      ## <= 0 或 >= 1 表示不做累计概率截断。
    seed*: int64
    seedSpecified*: bool

proc initSamplingConfig*(temperature: float = 0.0, topK: int = 0,
                         topP: float = 0.0, seed: int64 = 0,
                         seedSpecified: bool = false): SamplingConfig =
  SamplingConfig(
    temperature: temperature,
    topK: topK,
    topP: topP,
    seed: seed,
    seedSpecified: seedSpecified
  )

proc greedySamplingConfig*(): SamplingConfig =
  ## 明确表达「不采样」。比到处写 `initSamplingConfig()` 更能看出意图。
  initSamplingConfig()

proc isGreedy*(cfg: SamplingConfig): bool =
  ## 是否退化为贪心。
  ##
  ## NaN 也算贪心:`gen_defaults` 用 NaN 表示「模型没声明温度」,
  ## 把未声明当成某个具体温度就是在编造模型行为。
  cfg.temperature.classify == fcNan or
    cfg.temperature <= GreedyTemperatureThreshold

proc validate*(cfg: SamplingConfig): string =
  ## 校验采样参数。返回空字符串表示合法。
  ##
  ## 取值范围与 `core/inference.validateParameters` 保持一致 —— 那里是 API
  ## 边界的校验,这里是解码前的最后一道:请求可以绕过 API 直接调用本模块
  ## (CLI / benchmark),不能因此失去校验。
  if cfg.temperature.classify != fcNan and
      (cfg.temperature < 0.0 or cfg.temperature > 2.0):
    return "temperature must be within 0.0..2.0, got: " & $cfg.temperature
  if cfg.topP.classify == fcNan:
    return "top_p must be a number"
  if cfg.topP > 1.0:
    return "top_p must be within (0.0, 1.0], got: " & $cfg.topP
  result = ""

proc requireValid*(cfg: SamplingConfig) =
  let problem = cfg.validate()
  if problem.len > 0:
    raiseIsvikError(ecInvalidParameter, "Invalid sampling parameters", problem)

proc resolveSeed*(cfg: SamplingConfig): int64 =
  ## 决定本次采样实际使用的 seed。
  ##
  ## 未指定时用当前时间派生一个**具体值**并返回,使调用方能把它记录下来。
  ## 0 被换成 1:某些 RNG 实现对全零状态有退化行为,规避掉比解释它更省事。
  result =
    if cfg.seedSpecified: cfg.seed
    else: int64(epochTime() * 1_000_000.0)
  if result == 0:
    result = 1

proc newSamplingRng*(cfg: SamplingConfig): tuple[rng: Rand, seed: int64] =
  ## 构造随机数发生器,并回报实际使用的 seed。
  let seed = cfg.resolveSeed()
  (initRand(seed), seed)

proc sampleChoice*(logits: Tensor, cfg: SamplingConfig, rng: var Rand,
                   bannedIds: openArray[int] = []): TokenChoice =
  ## 按配置从 logits 的最后一个位置采样一个 token。
  ##
  ## 返回的 `logit` 是**原始** logit,不是温度缩放后的值:那个字段的语义是
  ## 「模型对这个 token 有多确信」,缩放后的数值不再对应模型的输出。
  cfg.requireValid()
  if cfg.isGreedy:
    return greedyChoice(logits, bannedIds)

  if logits == nil:
    raiseIsvikError(
      ecInferenceFailed,
      "Logits tensor must not be nil",
      "reason=nil-logits"
    )
  if logits.elementType != etF32:
    raiseIsvikError(
      ecNotImplemented,
      "Sampling currently requires F32 logits",
      "elementType=" & $logits.elementType
    )

  let view = lastPositionView(logits.shape)
  if view.offset + view.vocabSize > logits.elementCount:
    raiseIsvikError(
      ecInferenceFailed,
      "Logits view exceeds the tensor's element count",
      "offset=" & $view.offset & " vocabSize=" & $view.vocabSize &
        " elementCount=" & $logits.elementCount
    )

  var banned: seq[int] = @bannedIds
  sort(banned)

  proc isBanned(id: int): bool =
    banned.len > 0 and binarySearch(banned, id) >= 0

  let data = logits.data(float32)

  # --- 收集候选并做温度缩放 ---
  var candidates: seq[TokenChoice] = @[]
  for i in 0 ..< view.vocabSize:
    if isBanned(i):
      continue
    let value = data[view.offset + i]
    if value.classify == fcNan:
      continue
    candidates.add(TokenChoice(tokenId: i, logit: value))

  if candidates.len == 0:
    raiseIsvikError(
      ecInferenceFailed,
      "No selectable token remained after filtering",
      "vocabSize=" & $view.vocabSize & " banned=" & $banned.len
    )

  # 稳定排序:logit 相同时按 id 升序。截断与抽样都依赖顺序,
  # 顺序不定死会让同 seed 得到不同结果。
  candidates.sort(proc (a, b: TokenChoice): int =
    if a.logit > b.logit: -1
    elif a.logit < b.logit: 1
    elif a.tokenId < b.tokenId: -1
    elif a.tokenId > b.tokenId: 1
    else: 0)

  # --- top-k ---
  if cfg.topK > 0 and cfg.topK < candidates.len:
    candidates.setLen(cfg.topK)

  # --- softmax(温度缩放后) ---
  let scale = 1.0 / cfg.temperature
  var maxScaled = -Inf
  for c in candidates:
    let scaled = float(c.logit) * scale
    if scaled > maxScaled:
      maxScaled = scaled

  var weights = newSeq[float](candidates.len)
  var total = 0.0
  for i, c in candidates:
    # 减去最大值再取 exp:直接 exp 大 logit 会溢出成 inf。
    let w = exp(float(c.logit) * scale - maxScaled)
    weights[i] = w
    total += w

  if total <= 0.0 or total.classify == fcNan:
    # 数值退化(全部下溢)时不猜:退回贪心是唯一有依据的结果。
    return greedyChoice(logits, bannedIds)

  for i in 0 ..< weights.len:
    weights[i] = weights[i] / total

  # --- top-p:保留累计概率刚好达到 topP 的最小集合 ---
  if cfg.topP > 0.0 and cfg.topP < 1.0:
    var cumulative = 0.0
    var keep = 0
    for i in 0 ..< weights.len:
      cumulative += weights[i]
      inc keep
      if cumulative >= cfg.topP:
        break
    # 至少保留一个:topP 极小时也必须有东西可选。
    if keep < 1:
      keep = 1
    candidates.setLen(keep)
    weights.setLen(keep)

    var renorm = 0.0
    for w in weights:
      renorm += w
    if renorm <= 0.0:
      return greedyChoice(logits, bannedIds)
    for i in 0 ..< weights.len:
      weights[i] = weights[i] / renorm

  # --- 抽样 ---
  let point = rng.rand(1.0)
  var cumulative = 0.0
  for i, c in candidates:
    cumulative += weights[i]
    if point <= cumulative:
      return c

  # 浮点累计可能略小于 1.0 而让上面的循环走完。取最后一个候选是正确的收尾,
  # 不是兜底的猜测:它就是累计分布的末端。
  result = candidates[^1]
