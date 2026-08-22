## 统一推理事件流
##
## 对应 Master Prompt §20.5.4:
##
## ```text
## Isvik Core
##     ↓
## Unified Inference Result / Event      ← 本模块
##     ↓
## Protocol Adapter
##     ├── Anthropic SSE
##     ├── OpenAI SSE
##     └── Isvik Native Stream
## ```
##
## §20.5.4 要求 Streaming **从架构阶段设计**,内部统一使用一套事件,
## 再分别转换为各协议的 SSE。这样新增协议只需写一个 Adapter,
## 而不需要在推理循环里插入协议相关的分支。
##
## ---
##
## ## 与 core/events.nim 的区别(不要混用)
##
## | | 本模块 `InferenceEvent` | core/events.nim `RuntimeEvent` |
## | --- | --- | --- |
## | 规范来源 | §20.5.4 Unified Event Stream | §29 GUI Activity |
## | 粒度 | 单次推理内部(token 级) | 运行时生命周期(进程级) |
## | 生命周期 | 随一次请求开始与结束 | 与进程同寿 |
## | 消费者 | Protocol Adapter → SSE | GUI Activity 页、日志 |
##
## ---
##
## ## 命名风格为何与 RuntimeEventKind 不同
##
## `RuntimeEventKind` 用 `SCREAMING_SNAKE_CASE`,因为 §29 的原文是
## 「Runtime Started」这类带空格的名字,无法直接作为标识符,必须转换。
##
## 本模块的字符串值直接采用 §20.5.4 的原文(`InferenceStarted`、
## `ContentDelta` …)—— 它们本身就是合法标识符,原样使用可以让代码与规范
## 逐字对应,减少「这个事件对应规范里哪一条」的猜测。

import std/[json, options, tables]

import isvik/core/errors
import isvik/core/inference
import isvik/core/tools

type
  InferenceEventKind* = enum
    ## §20.5.4 列出的九种事件,字符串值与规范原文一致。
    iekInferenceStarted = "InferenceStarted"
    iekContentDelta = "ContentDelta"
    iekReasoningDelta = "ReasoningDelta"
    iekToolCallStarted = "ToolCallStarted"
    iekToolCallDelta = "ToolCallDelta"
    iekUsageUpdated = "UsageUpdated"
    iekInferenceCompleted = "InferenceCompleted"
    iekInferenceCancelled = "InferenceCancelled"
    iekInferenceError = "InferenceError"

  InferenceEvent* = object
    ## 一条推理流事件。
    ##
    ## 使用 object variant,让「按事件类型访问正确字段」由编译器保证。
    ##
    ## 注意 ToolCallStarted 与 ToolCallDelta 共用一个分支:Nim 的 case object
    ## 要求所有分支的字段名互不相同,而这两个事件天然共享 toolCallId。
    ## 合并分支比给其中一个起 `deltaToolCallId` 这类别名更清晰。
    case kind*: InferenceEventKind
    of iekInferenceStarted:
      startedModel*: string
      startedDevice*: string
        ## 实际使用的设备。AUTO 决策的结果在此刻已确定,
        ## 客户端可以据此知道推理真正跑在哪里。
    of iekContentDelta, iekReasoningDelta:
      textDelta*: string
    of iekToolCallStarted, iekToolCallDelta:
      toolCallId*: string
      toolName*: string
        ## 仅 ToolCallStarted 有值。
      argumentsDelta*: string
        ## 仅 ToolCallDelta 有值,是参数文本的增量片段。
    of iekUsageUpdated:
      usage*: Usage
    of iekInferenceCompleted:
      finalResult*: UnifiedInferenceResult
        ## 命名为 finalResult 而非 result:后者是 Nim 的隐式返回变量名,
        ## 作为字段名会造成阅读混淆。
    of iekInferenceCancelled:
      cancelledReason*: string
    of iekInferenceError:
      errorCode*: IsvikErrorCode
      errorMessage*: string

  InferenceEventHandler* = proc (e: InferenceEvent)

const
  ## §20.5.4 原文列出的事件名。用于规范一致性测试。
  Section2054EventNames*: array[9, string] = [
    "InferenceStarted",
    "ContentDelta",
    "ReasoningDelta",
    "ToolCallStarted",
    "ToolCallDelta",
    "UsageUpdated",
    "InferenceCompleted",
    "InferenceCancelled",
    "InferenceError"
  ]

  ## 终止性事件:每个推理流恰好以其中之一结束。
  ##
  ## 注意:文档注释必须写在常量名之前。Nim 的 set 字面量 `{...}` 内部
  ## 只接受表达式,把 `##` 注释放进去会导致「expression expected」。
  TerminalEventKinds* = {
    iekInferenceCompleted, iekInferenceCancelled, iekInferenceError
  }

# ---------------------------------------------------------------------------
# 构造
# ---------------------------------------------------------------------------

proc inferenceStarted*(model, device: string): InferenceEvent =
  InferenceEvent(kind: iekInferenceStarted,
                 startedModel: model, startedDevice: device)

proc contentDelta*(text: string): InferenceEvent =
  InferenceEvent(kind: iekContentDelta, textDelta: text)

proc reasoningDelta*(text: string): InferenceEvent =
  InferenceEvent(kind: iekReasoningDelta, textDelta: text)

proc toolCallStarted*(id, name: string): InferenceEvent =
  InferenceEvent(kind: iekToolCallStarted,
                 toolCallId: id, toolName: name, argumentsDelta: "")

proc toolCallDelta*(id, argumentsDelta: string): InferenceEvent =
  InferenceEvent(kind: iekToolCallDelta,
                 toolCallId: id, toolName: "", argumentsDelta: argumentsDelta)

proc usageUpdated*(usage: Usage): InferenceEvent =
  InferenceEvent(kind: iekUsageUpdated, usage: usage)

proc inferenceCompleted*(res: UnifiedInferenceResult): InferenceEvent =
  InferenceEvent(kind: iekInferenceCompleted, finalResult: res)

proc inferenceCancelled*(reason: string = ""): InferenceEvent =
  InferenceEvent(kind: iekInferenceCancelled, cancelledReason: reason)

proc inferenceError*(code: IsvikErrorCode, message: string): InferenceEvent =
  InferenceEvent(kind: iekInferenceError,
                 errorCode: code, errorMessage: message)

proc inferenceErrorFrom*(e: ref IsvikError): InferenceEvent =
  ## 从 IsvikError 构造错误事件。
  ##
  ## 只取 code 与 msg,**不取 detail** —— detail 可能含本地路径等敏感信息,
  ## 而事件流会直接流向外部客户端。这与 core/errors 中
  ## 「detail 不进入 API 响应」的边界一致。
  inferenceError(e.code, e.msg)

proc isTerminal*(e: InferenceEvent): bool =
  ## 该事件是否为流的终止事件。
  e.kind in TerminalEventKinds

# ---------------------------------------------------------------------------
# 序列化(Isvik Native 形式)
# ---------------------------------------------------------------------------

proc toJsonNode*(usage: Usage): JsonNode =
  %*{
    "input_tokens": usage.inputTokens,
    "output_tokens": usage.outputTokens,
    "total_tokens": usage.totalTokens
  }

proc toJsonNode*(part: ContentPart): JsonNode =
  case part.kind
  of cpkText:
    %*{"type": "text", "text": part.text}
  of cpkReasoning:
    %*{"type": "reasoning", "text": part.text}
  of cpkToolUse:
    %*{"type": "tool_use", "tool_call": part.toolCall.toJsonNode()}
  of cpkToolResult:
    %*{"type": "tool_result", "tool_result": part.toolResult.toJsonNode()}

proc toJsonNode*(res: UnifiedInferenceResult): JsonNode =
  var contentArray = newJArray()
  for part in res.content:
    contentArray.add(part.toJsonNode())

  result = %*{
    "model": res.model,
    "device": res.device,
    "content": contentArray,
    "stop_reason": $res.stopReason,
    "usage": res.usage.toJsonNode()
  }
  if res.metadata.len > 0:
    var meta = newJObject()
    for key, value in res.metadata:
      meta[key] = %value
    result["metadata"] = meta

proc toJsonNode*(e: InferenceEvent): JsonNode =
  ## 事件的 Isvik Native JSON 表示。
  ##
  ## 每个事件都带 `type` 字段,取值即 §20.5.4 的事件名,
  ## 使客户端能以单一字段做分派。
  result = %*{"type": $e.kind}
  case e.kind
  of iekInferenceStarted:
    result["model"] = %e.startedModel
    result["device"] = %e.startedDevice
  of iekContentDelta, iekReasoningDelta:
    result["text"] = %e.textDelta
  of iekToolCallStarted:
    result["tool_call_id"] = %e.toolCallId
    result["tool_name"] = %e.toolName
  of iekToolCallDelta:
    result["tool_call_id"] = %e.toolCallId
    result["arguments_delta"] = %e.argumentsDelta
  of iekUsageUpdated:
    result["usage"] = e.usage.toJsonNode()
  of iekInferenceCompleted:
    result["result"] = e.finalResult.toJsonNode()
  of iekInferenceCancelled:
    result["reason"] = %e.cancelledReason
  of iekInferenceError:
    # 与 §22 的错误响应形状保持一致,便于客户端复用同一套解析。
    result["error"] = %*{
      "code": $e.errorCode,
      "message": e.errorMessage
    }

proc toJson*(e: InferenceEvent): string = $e.toJsonNode()

# ---------------------------------------------------------------------------
# 流累积器
# ---------------------------------------------------------------------------

type
  StreamAccumulator* = ref object
    ## 把事件流重新聚合成完整结果。
    ##
    ## 用途有两个,都不是可选的:
    ##
    ## 1. **非流式请求复用同一条推理路径。** 推理内部始终产生事件流,
    ##    非流式响应只是「把流累积起来再一次性返回」。
    ##    否则流式与非流式会变成两套代码,行为迟早分叉。
    ## 2. **测试可以断言流的最终聚合结果**,而不只是逐个事件。
    model: string
    device: string
    textBuffer: string
    reasoningBuffer: string
    pendingToolCalls: seq[ToolCall]
    usageTotal: Usage
    finished: bool
    stopReason: StopReason
    errorCode: Option[IsvikErrorCode]
    errorMessage: string
    completedResult: Option[UnifiedInferenceResult]

proc newStreamAccumulator*(): StreamAccumulator =
  new(result)
  result.pendingToolCalls = @[]
  result.usageTotal = Usage(inputTokens: 0, outputTokens: 0)
  result.finished = false
  result.stopReason = srUnspecified
  result.errorCode = none(IsvikErrorCode)
  result.completedResult = none(UnifiedInferenceResult)

proc findToolCallIndex(acc: StreamAccumulator, id: string): int =
  for i in 0 ..< acc.pendingToolCalls.len:
    if acc.pendingToolCalls[i].id == id:
      return i
  result = -1

proc feed*(acc: StreamAccumulator, e: InferenceEvent) =
  ## 送入一条事件。
  ##
  ## 终止事件之后继续送入会抛 IsvikError(INVALID_REQUEST):
  ## 流在终止后还有事件说明产生方有 bug,静默忽略会掩盖它。
  if acc.finished:
    raiseIsvikError(
      ecInvalidRequest,
      "Cannot feed events into an already finished stream",
      "event=" & $e.kind
    )

  case e.kind
  of iekInferenceStarted:
    acc.model = e.startedModel
    acc.device = e.startedDevice
  of iekContentDelta:
    acc.textBuffer.add(e.textDelta)
  of iekReasoningDelta:
    acc.reasoningBuffer.add(e.textDelta)
  of iekToolCallStarted:
    if acc.findToolCallIndex(e.toolCallId) >= 0:
      raiseIsvikError(
        ecToolCallFailed,
        "Duplicate tool call id in stream",
        "toolCallId=" & e.toolCallId
      )
    acc.pendingToolCalls.add(initToolCall(e.toolCallId, e.toolName))
  of iekToolCallDelta:
    let idx = acc.findToolCallIndex(e.toolCallId)
    if idx < 0:
      # 先收到 Delta 再收到 Started 说明事件顺序错误,必须报错而不是猜。
      raiseIsvikError(
        ecToolCallFailed,
        "Received tool call delta before its ToolCallStarted event",
        "toolCallId=" & e.toolCallId
      )
    acc.pendingToolCalls[idx].appendArguments(e.argumentsDelta)
  of iekUsageUpdated:
    acc.usageTotal = acc.usageTotal + e.usage
  of iekInferenceCompleted:
    acc.finished = true
    acc.stopReason = e.finalResult.stopReason
    acc.completedResult = some(e.finalResult)
  of iekInferenceCancelled:
    acc.finished = true
    acc.stopReason = srCancelled
    acc.errorMessage = e.cancelledReason
  of iekInferenceError:
    acc.finished = true
    acc.stopReason = srError
    acc.errorCode = some(e.errorCode)
    acc.errorMessage = e.errorMessage

proc isFinished*(acc: StreamAccumulator): bool = acc.finished
proc accumulatedText*(acc: StreamAccumulator): string = acc.textBuffer
proc accumulatedReasoning*(acc: StreamAccumulator): string = acc.reasoningBuffer
proc accumulatedUsage*(acc: StreamAccumulator): Usage = acc.usageTotal
proc accumulatedStopReason*(acc: StreamAccumulator): StopReason = acc.stopReason
proc accumulatedErrorCode*(acc: StreamAccumulator): Option[IsvikErrorCode] =
  acc.errorCode
proc accumulatedErrorMessage*(acc: StreamAccumulator): string = acc.errorMessage

proc accumulatedToolCalls*(acc: StreamAccumulator): seq[ToolCall] =
  ## 已累积的工具调用。参数文本已就位,但可能尚未解析。
  acc.pendingToolCalls

proc finalizeToolCalls*(acc: StreamAccumulator) =
  ## 解析所有工具调用的参数文本。参数非法时抛 TOOL_CALL_FAILED。
  for i in 0 ..< acc.pendingToolCalls.len:
    acc.pendingToolCalls[i].finalizeArguments()

proc buildResult*(acc: StreamAccumulator): UnifiedInferenceResult =
  ## 将累积的流聚合成完整结果。
  ##
  ## 若流以 InferenceCompleted 结束,直接采用其中携带的结果 ——
  ## 那是产生方给出的权威版本,重新拼装会有偏差的风险。
  ## 否则(取消 / 出错 / 未结束)按已累积的内容构造一个尽力而为的结果。
  if acc.completedResult.isSome:
    return acc.completedResult.get

  result = initUnifiedInferenceResult(acc.model)
  result.device = acc.device
  result.stopReason = acc.stopReason
  result.usage = acc.usageTotal

  if acc.reasoningBuffer.len > 0:
    result.content.add(reasoningPart(acc.reasoningBuffer))
  if acc.textBuffer.len > 0:
    result.content.add(textPart(acc.textBuffer))
  for call in acc.pendingToolCalls:
    result.content.add(toolUsePart(call))

proc requireSuccess*(acc: StreamAccumulator) =
  ## 若流以错误或取消结束,则抛出对应的 IsvikError。
  ##
  ## 非流式请求在返回响应前应调用它:客户端不该从一个「成功」的响应体里
  ## 自己去发现推理其实失败了。
  if acc.errorCode.isSome:
    raiseIsvikError(acc.errorCode.get, acc.errorMessage)
  if acc.stopReason == srCancelled:
    raiseIsvikError(
      ecStreamCancelled,
      "Inference was cancelled",
      "reason=" & acc.errorMessage
    )

proc collect*(events: openArray[InferenceEvent]): StreamAccumulator =
  ## 便捷函数:把一串事件依次送入新的累积器。
  result = newStreamAccumulator()
  for e in events:
    result.feed(e)
