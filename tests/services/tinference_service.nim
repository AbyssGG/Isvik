## Inference Service 测试
##
## 重点是**映射与拒绝**,它们不需要模型:
##
## ```text
## InferenceParameters → SamplingConfig   采样字段此前完全无人消费
## Message            → ChatMessage       工具消息必须显式拒绝
## 解码 StopReason     → 统一 StopReason   不得把截断说成自然结束
## 未实现的请求形态                        必须抛 NOT_IMPLEMENTED,不是静默忽略
## ```
##
## 真实生成由 `tests/inference/tgeneration_real.nim` 覆盖,不在这里重复。

import std/[json, options, os, strutils, unittest]

import isvik/core/errors
import isvik/core/tools
import isvik/core/inference
import isvik/config/paths
import isvik/config/settings
import isvik/inference/chat_format
import isvik/inference/sampling
import isvik/inference/text_generator
import isvik/services/inference_service

proc chatRequest(text: string = "hello"): UnifiedInferenceRequest =
  result = initUnifiedInferenceRequest("some-model")
  result.messages = @[textMessage(mrUser, text)]

proc codeOf(body: proc()): IsvikErrorCode =
  result = ecServerError
  try:
    body()
  except IsvikError as e:
    result = e.code

suite "采样参数映射":

  test "全部未指定时是贪心":
    # 不替客户端假设 temperature=1.0:那会让「没说要随机」的请求变随机。
    let cfg = toSamplingConfig(initInferenceParameters())
    check cfg.isGreedy
    check not cfg.seedSpecified

  test "显式 temperature 被采用":
    var p = initInferenceParameters()
    p.temperature = some(0.7)
    let cfg = toSamplingConfig(p)
    check not cfg.isGreedy
    check cfg.temperature == 0.7

  test "显式 temperature=0 仍是贪心":
    # Option 的意义就在这里:能区分「没指定」与「指定为 0」。
    var p = initInferenceParameters()
    p.temperature = some(0.0)
    check toSamplingConfig(p).isGreedy

  test "只给 top_p 时温度取恒等值,而不是静默忽略 top_p":
    # 贪心下 top_p 完全无效。忽略客户端明确给的字段属于静默错误
    # (§20.5.13 第 12 条),因此这里用 softmax 的恒等缩放 1.0 让它生效。
    var p = initInferenceParameters()
    p.topP = some(0.9)
    let cfg = toSamplingConfig(p)
    check not cfg.isGreedy
    check cfg.temperature == 1.0
    check cfg.topP == 0.9

  test "只给 top_k 时同理":
    var p = initInferenceParameters()
    p.topK = some(40)
    let cfg = toSamplingConfig(p)
    check not cfg.isGreedy
    check cfg.topK == 40

  test "seed 被透传且标记为已指定":
    var p = initInferenceParameters()
    p.temperature = some(0.8)
    p.seed = some(20240820)
    let cfg = toSamplingConfig(p)
    check cfg.seedSpecified
    check cfg.resolveSeed() == 20240820

  test "映射结果始终通过采样自身的校验":
    var p = initInferenceParameters()
    for t in [0.0, 0.5, 1.0, 2.0]:
      p.temperature = some(t)
      toSamplingConfig(p).requireValid()
    check true

suite "token 上限映射":

  test "未指定时用给定默认值":
    check resolveMaxTokens(initInferenceParameters(), 128) == 128

  test "显式取值优先":
    var p = initInferenceParameters()
    p.maxTokens = some(64)
    check resolveMaxTokens(p, 128) == 64

suite "消息映射":

  test "三种角色映射到对话模板的角色":
    let messages = @[
      textMessage(mrSystem, "sys"),
      textMessage(mrUser, "u"),
      textMessage(mrAssistant, "a")
    ]
    let mapped = toChatMessages(messages)
    check mapped.len == 3
    check mapped[0].role == crSystem
    check mapped[1].role == crUser
    check mapped[2].role == crAssistant
    check mapped[1].content == "u"

  test "多个文本片段被拼接":
    let msg = initMessage(mrUser, @[textPart("ab"), textPart("cd")])
    check toChatMessages(@[msg])[0].content == "abcd"

  test "reasoning 片段不进入正文":
    # 推理内容不属于对外回答,混进提示词会让模型看到本不该有的前缀。
    let msg = initMessage(mrUser, @[textPart("keep"), reasoningPart("drop")])
    check toChatMessages(@[msg])[0].content == "keep"

  test "tool 角色以 user 回合回去,并带来源标记":
    # chat_format.ChatRole 不含 tool 角色,工具结果在对话结构上占的是
    # 「用户又说话了」这一格。但不能伪装成普通用户发言 —— 模型需要知道
    # 这是工具的输出。
    let msg = initMessage(mrTool,
      @[toolResultPart(initToolResult("call_1", "18C"))])
    let mapped = toChatMessages(@[msg])
    check mapped.len == 1
    check mapped[0].role == crUser
    check mapped[0].content.contains("isvik_tool_result")
    check mapped[0].content.contains("18C")

  test "assistant 的工具调用被还原成信封":
    # 多轮工具对话里,上一轮的调用必须以模型当初输出的形状回到提示词里。
    let call = initToolCall("c1", "get_time", "{}", newJObject())
    let msg = initMessage(mrAssistant, @[toolUsePart(call)])
    let mapped = toChatMessages(@[msg])
    check mapped[0].role == crAssistant
    check mapped[0].content.contains("isvik_tool_call")
    check mapped[0].content.contains("get_time")

suite "终止原因映射":

  test "EOS 映射为 end_turn":
    check toUnifiedStopReason(text_generator.srEndOfSequence) ==
      inference.srEndTurn

  test "两种截断都映射为 max_tokens":
    # 统一模型没有「模型未声明 EOS」这一档,但两者对客户端的含义相同:
    # 输出可能不完整。说成 end_turn 才是失真。
    check toUnifiedStopReason(text_generator.srMaxTokens) ==
      inference.srMaxTokens
    check toUnifiedStopReason(text_generator.srNoEosDeclared) ==
      inference.srMaxTokens

  test "取消如实映射":
    check toUnifiedStopReason(text_generator.srCancelled) ==
      inference.srCancelled

  test "没有任何解码终止原因被映射成 unspecified 或 error":
    # 这两档表示「不知道为什么停」与「出错了」,不该由正常终止产生。
    for r in [text_generator.srEndOfSequence, text_generator.srMaxTokens,
              text_generator.srNoEosDeclared, text_generator.srCancelled]:
      let mapped = toUnifiedStopReason(r)
      check mapped != inference.srUnspecified
      check mapped != inference.srError

suite "未实现的请求形态必须显式拒绝":

  test "合法的纯文本对话请求通过":
    chatRequest().requireSupported()
    check true

  test "工具调用不再被拒绝(已接入提示词方案)":
    var req = chatRequest()
    req.tools = @[initToolDefinition("get_time", "Return the time", nil)]
    req.requireSupported()
    check true

  test "各种 toolChoice 都被接受":
    for choice in [autoToolChoice(), noToolChoice(), requiredToolChoice()]:
      var req = chatRequest()
      req.tools = @[initToolDefinition("get_time", "d", nil)]
      req.toolChoice = choice
      req.requireSupported()
    check true

  test "结构化输出抛 NOT_IMPLEMENTED":
    var req = chatRequest()
    req.responseFormat = jsonObjectFormat()
    check codeOf(proc() = req.requireSupported()) == ecNotImplemented

  test "stop 序列抛 NOT_IMPLEMENTED 而不是静默不停":
    # 静默忽略会让客户端以为「模型就是没在那里停」。
    var req = chatRequest()
    req.parameters.stopSequences = @["\n\n"]
    check codeOf(proc() = req.requireSupported()) == ecNotImplemented

  test "惩罚项抛 NOT_IMPLEMENTED":
    var req = chatRequest()
    req.parameters.presencePenalty = some(0.5)
    check codeOf(proc() = req.requireSupported()) == ecNotImplemented
    var other = chatRequest()
    other.parameters.frequencyPenalty = some(0.5)
    check codeOf(proc() = other.requireSupported()) == ecNotImplemented

  test "非对话 input 路径抛 NOT_IMPLEMENTED":
    var req = initUnifiedInferenceRequest("some-model")
    req.input = "raw text"
    check codeOf(proc() = req.requireSupported()) == ecNotImplemented

  test "空消息列表报 INVALID_REQUEST":
    let req = initUnifiedInferenceRequest("some-model")
    check codeOf(proc() = req.requireSupported()) == ecInvalidRequest

suite "服务生命周期":

  test "构造不加载模型,也不因环境失败":
    # 构造必须能在没有模型、甚至没有 OpenVINO 的机器上成功 ——
    # 否则 doctor 之类的诊断路径自己就跑不起来。
    let svc = newInferenceService(newIsvikPaths(getTempDir()), defaultSettings())
    check not svc.isLoaded()
    check svc.loadedModel() == ""
    check svc.loadedDevice() == ""
    svc.close()

  test "close 与 unload 幂等,nil 安全":
    let svc = newInferenceService(newIsvikPaths(getTempDir()), defaultSettings())
    svc.unload()
    svc.unload()
    svc.close()
    svc.close()
    let nilSvc: InferenceService = nil
    nilSvc.unload()
    nilSvc.close()
    check not nilSvc.isLoaded()

  test "关闭后执行报可诊断错误":
    let svc = newInferenceService(newIsvikPaths(getTempDir()), defaultSettings())
    svc.close()
    check codeOf(proc() = discard svc.execute(chatRequest())) ==
      ecInvalidParameter
