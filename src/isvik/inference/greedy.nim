## 贪心解码:从 logits 选下一个 token
##
## ---
##
## ## 为什么单独一个模块
##
## 采样是纯计算,不碰 Backend、不碰设备、不碰模型文件。把它独立出来使它能
## 被完整测试 —— 而「采样选错 token」是一类完全静默的错误:输出仍然是通顺的
## 文本,只是不是模型真正想说的。没有独立测试就发现不了。
##
## ---
##
## ## 只实现贪心
##
## 温度采样、top-k、top-p 需要随机数,而随机数会让输出不可复现。规范的
## 统一请求模型(§20.5.3)已经预留了 `temperature` / `topP` / `topK` /
## `seed` 字段,但**这里不假装支持它们** —— 声明了却不实现比不声明更糟
## (§20.5.13 第 12 条的同一原则)。
##
## 贪心解码是确定性的:同样的输入必然给出同样的输出。这让端到端测试能做
## 真正的断言,而不只是「没报错」。

import std/[math, algorithm]

import isvik/core/errors
import isvik/core/tensor

type
  TokenChoice* = object
    ## 一次采样的结果。
    tokenId*: int
    logit*: float32
      ## 该 token 的原始 logit。保留它是为了让调用方能判断
      ## 「模型有多确信」—— 只给 tokenId 就丢掉了这个信息。

  LogitsView* = object
    ## 对 logits 张量最后一个位置的视图。
    ##
    ## 语言模型的 logits 形状是 `[batch, sequence, vocab]`。自回归解码只关心
    ## **最后一个位置**:那才是「下一个 token 的分布」。取错位置会让模型
    ## 一直重复输入里的内容,而输出看起来像是模型「卡住了」。
    offset*: int
      ## 最后一个位置在扁平数组中的起始下标。
    vocabSize*: int

proc lastPositionView*(shape: openArray[int]): LogitsView =
  ## 计算 logits 张量最后一个位置的视图。
  ##
  ## 接受两种形状:
  ##
  ## ```text
  ## [batch, sequence, vocab]   常规
  ## [batch, vocab]             某些导出只输出最后一步
  ## ```
  ##
  ## 其它 rank 一律报错而不猜:猜错会静默读到错误的内存区间。
  if shape.len == 3:
    let batch = shape[0]
    let sequence = shape[1]
    let vocab = shape[2]
    if batch <= 0 or sequence <= 0 or vocab <= 0:
      raiseIsvikError(
        ecInferenceFailed,
        "Logits tensor has a non-positive dimension",
        "shape=" & $(@shape)
      )
    # 只支持 batch=1:批量解码需要为每条序列各自维护状态,那是另一个
    # 工作量级。这里明确拒绝而不是默默只算第一条。
    if batch != 1:
      raiseIsvikError(
        ecNotImplemented,
        "Batched greedy decoding is not implemented",
        "batch=" & $batch & " shape=" & $(@shape)
      )
    result = LogitsView(offset: (sequence - 1) * vocab, vocabSize: vocab)
  elif shape.len == 2:
    let batch = shape[0]
    let vocab = shape[1]
    if batch <= 0 or vocab <= 0:
      raiseIsvikError(
        ecInferenceFailed,
        "Logits tensor has a non-positive dimension",
        "shape=" & $(@shape)
      )
    if batch != 1:
      raiseIsvikError(
        ecNotImplemented,
        "Batched greedy decoding is not implemented",
        "batch=" & $batch & " shape=" & $(@shape)
      )
    result = LogitsView(offset: 0, vocabSize: vocab)
  else:
    raiseIsvikError(
      ecInferenceFailed,
      "Unexpected logits tensor rank; expected [batch, sequence, vocab]" &
        " or [batch, vocab]",
      "shape=" & $(@shape)
    )

proc greedyChoice*(logits: Tensor,
                   bannedIds: openArray[int] = []): TokenChoice =
  ## 在 logits 的最后一个位置取 argmax。
  ##
  ## `bannedIds` 用于屏蔽不该被选中的 token(例如 `<pad>`)。屏蔽方式是
  ## **跳过**而不是把 logit 设成 -inf:后者需要修改张量内容,而张量可能是
  ## 别处还要用的数据。
  ##
  ## 相等时取**较小的 id**(`>` 而非 `>=`),使结果完全确定 —— 浮点相等在
  ## 不同设备上都可能出现,不定死规则会让 CPU 与 NPU 给出不同输出。
  if logits == nil:
    raiseIsvikError(
      ecInferenceFailed,
      "Logits tensor must not be nil",
      "reason=nil-logits"
    )
  if logits.elementType != etF32:
    # 不做隐式转换:F16 的 logits 需要显式转换路径,静默按 F32 读会得到垃圾。
    raiseIsvikError(
      ecNotImplemented,
      "Greedy decoding currently requires F32 logits",
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
  var bestId = -1
  var bestLogit = low(float32)

  for i in 0 ..< view.vocabSize:
    if isBanned(i):
      continue
    let value = data[view.offset + i]
    # NaN 不参与比较:任何与 NaN 的比较都是 false,若不显式跳过,
    # 一个 NaN 会让后续所有比较都失败而选出错误的 token。
    if value.classify == fcNan:
      continue
    if bestId < 0 or value > bestLogit:
      bestId = i
      bestLogit = value

  if bestId < 0:
    raiseIsvikError(
      ecInferenceFailed,
      "No selectable token remained after filtering",
      "vocabSize=" & $view.vocabSize & " banned=" & $banned.len
    )

  result = TokenChoice(tokenId: bestId, logit: bestLogit)

proc topKChoices*(logits: Tensor, k: int): seq[TokenChoice] =
  ## 取 logits 最后位置上分值最高的 k 个 token。
  ##
  ## **不是采样** —— 它不选一个,只是把候选列出来,供调试与
  ## 「模型到底在犹豫什么」这类观察使用。真正的 top-k 采样需要随机数,
  ## 尚未实现。
  if k <= 0:
    raiseIsvikError(
      ecInvalidParameter,
      "k must be positive",
      "k=" & $k
    )
  if logits == nil or logits.elementType != etF32:
    raiseIsvikError(
      ecInferenceFailed,
      "topKChoices requires a non-nil F32 logits tensor",
      "elementType=" & (if logits == nil: "nil" else: $logits.elementType)
    )

  let view = lastPositionView(logits.shape)
  let data = logits.data(float32)

  var all: seq[TokenChoice] = @[]
  for i in 0 ..< view.vocabSize:
    let value = data[view.offset + i]
    if value.classify == fcNan:
      continue
    all.add(TokenChoice(tokenId: i, logit: value))

  # 稳定排序:logit 相同时按 id 升序,使输出可复现。
  all.sort(proc (a, b: TokenChoice): int =
    if a.logit > b.logit: -1
    elif a.logit < b.logit: 1
    else: cmp(a.tokenId, b.tokenId))

  result = all[0 ..< min(k, all.len)]

proc softmaxProbability*(logits: Tensor, tokenId: int): float =
  ## 某个 token 在最后位置上的 softmax 概率。
  ##
  ## 用「减去最大值再取指数」的稳定形式:直接 `exp(logit)` 在 logit 较大时
  ## 会溢出成 inf,得到 NaN 概率。
  ##
  ## 只在需要展示置信度时调用 —— 贪心解码本身不需要归一化。
  if logits == nil or logits.elementType != etF32:
    raiseIsvikError(
      ecInferenceFailed,
      "softmaxProbability requires a non-nil F32 logits tensor",
      "elementType=" & (if logits == nil: "nil" else: $logits.elementType)
    )

  let view = lastPositionView(logits.shape)
  if tokenId < 0 or tokenId >= view.vocabSize:
    raiseIsvikError(
      ecInvalidParameter,
      "Token id is outside the vocabulary range",
      "tokenId=" & $tokenId & " vocabSize=" & $view.vocabSize
    )

  let data = logits.data(float32)

  var maxLogit = low(float32)
  for i in 0 ..< view.vocabSize:
    let v = data[view.offset + i]
    if v.classify != fcNan and v > maxLogit:
      maxLogit = v

  var total = 0.0
  var target = 0.0
  for i in 0 ..< view.vocabSize:
    let v = data[view.offset + i]
    if v.classify == fcNan:
      continue
    let e = exp(float(v) - float(maxLogit))
    total += e
    if i == tokenId:
      target = e

  if total <= 0.0:
    return 0.0
  result = target / total
