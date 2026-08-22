## 贪心解码测试
##
## 纯计算,不依赖 OpenVINO。这一层的错误是完全静默的 —— 采样选错 token 会
## 产出通顺但不是模型真正想说的文本,只有独立断言才能发现。

import std/[unittest, math]

import isvik/core/errors
import isvik/core/tensor
import isvik/inference/greedy

proc logits3d(values: openArray[float32], sequence, vocab: int): Tensor =
  ## 构造 `[1, sequence, vocab]` 的 logits。
  newTensor(etF32, [1, sequence, vocab], values)

suite "最后位置视图":

  test "三维形状取最后一个位置":
    # 自回归只关心最后一步:取错位置会让模型一直重复输入内容。
    let view = lastPositionView([1, 4, 10])
    check view.vocabSize == 10
    check view.offset == 30      # (4-1) * 10

  test "序列长度为 1 时偏移为 0":
    let view = lastPositionView([1, 1, 7])
    check view.offset == 0
    check view.vocabSize == 7

  test "二维形状被接受,偏移为 0":
    # 某些导出只输出最后一步。
    let view = lastPositionView([1, 12])
    check view.offset == 0
    check view.vocabSize == 12

  test "批量大于 1 报 NOT_IMPLEMENTED 而不是只算第一条":
    # 默默只算第一条会让批量请求得到静默错误的结果。
    for shape in [@[2, 3, 10], @[4, 10]]:
      var code: IsvikErrorCode
      try:
        discard lastPositionView(shape)
        check false
      except IsvikError as e:
        code = e.code
      check code == ecNotImplemented

  test "其它 rank 报错而不猜":
    for shape in [@[10], @[1, 2, 3, 4], @[]]:
      expect IsvikError:
        discard lastPositionView(shape)

  test "非正维度被拒绝":
    for shape in [@[1, 0, 10], @[1, 3, 0], @[0, 10]]:
      expect IsvikError:
        discard lastPositionView(shape)

suite "贪心选择":

  test "取最大 logit 对应的 id":
    let t = logits3d([0.1'f32, 0.5, 0.2, 0.9, 0.3], 1, 5)
    let choice = greedyChoice(t)
    check choice.tokenId == 3
    check choice.logit == 0.9'f32

  test "只看最后一个位置,忽略前面的":
    # 第一个位置的最大值在 id=0,最后一个位置的最大值在 id=2。
    # 若实现取错位置,这条会失败。
    let t = logits3d([
      9.0'f32, 0.0, 0.0,      # 位置 0
      0.0, 0.0, 5.0           # 位置 1(最后)
    ], 2, 3)
    let choice = greedyChoice(t)
    check choice.tokenId == 2
    check choice.logit == 5.0'f32

  test "负 logit 同样正确":
    let t = logits3d([-5.0'f32, -1.0, -9.0], 1, 3)
    check greedyChoice(t).tokenId == 1

  test "相等时取较小的 id,结果完全确定":
    # 浮点相等在不同设备上都可能出现;不定死规则会让 CPU 与 NPU 输出不同。
    let t = logits3d([1.0'f32, 3.0, 3.0, 2.0], 1, 4)
    check greedyChoice(t).tokenId == 1
    # 重复调用结果一致
    check greedyChoice(t).tokenId == greedyChoice(t).tokenId

  test "被屏蔽的 id 不会被选中":
    let t = logits3d([0.1'f32, 9.9, 0.2], 1, 3)
    check greedyChoice(t).tokenId == 1
    check greedyChoice(t, [1]).tokenId == 2

  test "屏蔽多个 id":
    let t = logits3d([5.0'f32, 9.0, 8.0, 1.0], 1, 4)
    check greedyChoice(t, [1, 2]).tokenId == 0
    check greedyChoice(t, [1, 2, 0]).tokenId == 3

  test "屏蔽顺序不影响结果":
    let t = logits3d([5.0'f32, 9.0, 8.0, 1.0], 1, 4)
    check greedyChoice(t, [2, 1]).tokenId == greedyChoice(t, [1, 2]).tokenId

  test "全部被屏蔽时报 INFERENCE_FAILED":
    let t = logits3d([1.0'f32, 2.0], 1, 2)
    var code: IsvikErrorCode
    try:
      discard greedyChoice(t, [0, 1])
      check false
    except IsvikError as e:
      code = e.code
    check code == ecInferenceFailed

  test "NaN 被跳过,不会毒化比较":
    # 任何与 NaN 的比较都是 false。不显式跳过的话,一个 NaN 会让后续所有
    # 比较失败并选出错误的 token。
    let nan = NaN.float32
    let t = logits3d([nan, 1.0'f32, nan, 2.0, nan], 1, 5)
    let choice = greedyChoice(t)
    check choice.tokenId == 3
    check choice.logit == 2.0'f32

  test "第一个元素是 NaN 时仍能选出正确 id":
    let t = logits3d([NaN.float32, 0.5'f32, 0.1], 1, 3)
    check greedyChoice(t).tokenId == 1

  test "全是 NaN 时报错而不是返回垃圾":
    let nan = NaN.float32
    let t = logits3d([nan, nan], 1, 2)
    expect IsvikError:
      discard greedyChoice(t)

  test "nil 张量被拒绝":
    expect IsvikError:
      discard greedyChoice(nil)

  test "非 F32 张量报 NOT_IMPLEMENTED,不做隐式转换":
    # 按 F32 读 F16 会得到垃圾数值。
    let t = newTensor(etF16, [1, 1, 4])
    var code: IsvikErrorCode
    try:
      discard greedyChoice(t)
      check false
    except IsvikError as e:
      code = e.code
    check code == ecNotImplemented

  test "二维 logits 同样可用":
    let t = newTensor(etF32, [1, 4], [0.1'f32, 0.2, 0.9, 0.3])
    check greedyChoice(t).tokenId == 2

suite "top-k 候选":

  test "按 logit 降序返回前 k 个":
    let t = logits3d([1.0'f32, 5.0, 3.0, 4.0, 2.0], 1, 5)
    let top = topKChoices(t, 3)
    check top.len == 3
    check top[0].tokenId == 1     # 5.0
    check top[1].tokenId == 3     # 4.0
    check top[2].tokenId == 2     # 3.0

  test "第一名与贪心选择一致":
    # 两条路径若不一致,说明其中一个实现有问题。
    let t = logits3d([0.3'f32, 0.1, 0.7, 0.5], 1, 4)
    check topKChoices(t, 1)[0].tokenId == greedyChoice(t).tokenId

  test "k 大于词表时返回全部":
    let t = logits3d([1.0'f32, 2.0], 1, 2)
    check topKChoices(t, 99).len == 2

  test "logit 相同时按 id 升序,保证可复现":
    let t = logits3d([2.0'f32, 2.0, 2.0], 1, 3)
    let top = topKChoices(t, 3)
    check top[0].tokenId == 0
    check top[1].tokenId == 1
    check top[2].tokenId == 2

  test "k 非正被拒绝":
    let t = logits3d([1.0'f32], 1, 1)
    for k in [0, -1]:
      var code: IsvikErrorCode
      try:
        discard topKChoices(t, k)
        check false
      except IsvikError as e:
        code = e.code
      check code == ecInvalidParameter

  test "NaN 不进入候选":
    let t = logits3d([NaN.float32, 1.0'f32], 1, 2)
    let top = topKChoices(t, 5)
    check top.len == 1
    check top[0].tokenId == 1

suite "softmax 概率":

  test "概率和为 1":
    let t = logits3d([1.0'f32, 2.0, 3.0], 1, 3)
    var total = 0.0
    for id in 0 ..< 3:
      total += softmaxProbability(t, id)
    check abs(total - 1.0) < 1e-6

  test "最大 logit 对应最大概率":
    let t = logits3d([0.0'f32, 5.0, 1.0], 1, 3)
    let p1 = softmaxProbability(t, 1)
    check p1 > softmaxProbability(t, 0)
    check p1 > softmaxProbability(t, 2)
    check p1 > 0.9

  test "均匀 logits 给出均匀概率":
    let t = logits3d([1.0'f32, 1.0, 1.0, 1.0], 1, 4)
    for id in 0 ..< 4:
      check abs(softmaxProbability(t, id) - 0.25) < 1e-6

  test "大 logit 不溢出成 NaN":
    # 直接 exp(logit) 在这个量级会变成 inf,进而得到 NaN 概率。
    let t = logits3d([700.0'f32, 701.0], 1, 2)
    let p = softmaxProbability(t, 1)
    check p.classify != fcNan
    check p > 0.5
    check p <= 1.0

  test "越界 token id 被拒绝":
    let t = logits3d([1.0'f32, 2.0], 1, 2)
    for id in [-1, 2, 99]:
      var code: IsvikErrorCode
      try:
        discard softmaxProbability(t, id)
        check false
      except IsvikError as e:
        code = e.code
      check code == ecInvalidParameter
