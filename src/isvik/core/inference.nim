## 统一推理请求与结果模型
##
## 对应 Master Prompt §20.5.3(Unified Inference Request)与
## §20.5.6(Structured Output)。
##
## ---
##
## ## 为什么这些类型必须在 PHASE 1 就定义
##
## §46 明确要求:
##
## > 不能先完成单协议 API,再返工设计多协议兼容。
##
## 所有外部协议(Anthropic Messages、OpenAI Chat Completions、
## OpenAI Responses、Isvik Native)都必须先转换成本模块的
## `UnifiedInferenceRequest`,再进入 Core:
##
## ```text
## External Request → Protocol Adapter → UnifiedInferenceRequest → Isvik Core
## ```
##
## 如果先只做一种协议,请求模型会不自觉地长成那种协议的形状,
## 之后接入第二种协议时就得推翻重来。
##
## ---
##
## ## 「未指定」与「显式设为零值」必须可区分
##
## 采样参数使用 `Option[T]`。理由与配置模块一致:
## `temperature = 0` 是一个**有意义的取值**(贪心解码),
## 而「客户端没有传 temperature」应当由模型或后端的默认值决定。
## 若用 0 同时表示这两种情况,就无法把它们区分开。
##
## 本模块不依赖任何 Backend,也不依赖 HTTP。

import std/[json, options, strutils, tables]

import isvik/core/errors
import isvik/core/tools

type
  MessageRole* = enum
    ## 消息角色。
    ##
    ## 统一模型把 system 也作为一种角色。Anthropic 的 Messages API 把
    ## system 放在顶层独立字段,OpenAI 则把它作为一条 system 消息 ——
    ## 这类差异由各自的 Adapter 在边界上消化,Core 只看到一种形式。
    mrSystem = "system"
    mrUser = "user"
    mrAssistant = "assistant"
    mrTool = "tool"

  ContentPartKind* = enum
    ## 消息内容片段的类型。
    ##
    ## 内容被建模为**片段序列**而不是单个字符串,因为一条 assistant 消息
    ## 可能同时包含文本与若干工具调用,一条 user 消息可能包含多个工具结果。
    ##
    ## 当前不含图像 / 音频片段。多模态需要与真实模型能力一起验证,
    ## 在没有可运行的多模态链路之前先不加类型,避免声明了却不支持(§20.5.6)。
    cpkText = "text"
    cpkReasoning = "reasoning"
      ## 推理过程内容,对应 §20.5.4 的 ReasoningDelta。
      ## 与普通文本分开是必要的:多数客户端需要把它折叠或单独展示。
    cpkToolUse = "tool_use"
    cpkToolResult = "tool_result"

  ContentPart* = object
    ## 内容片段。使用 object variant,使「按 kind 读取正确字段」由编译器保证,
    ## 而不是靠调用方自觉。
    case kind*: ContentPartKind
    of cpkText, cpkReasoning:
      text*: string
    of cpkToolUse:
      toolCall*: ToolCall
    of cpkToolResult:
      toolResult*: ToolResult

  Message* = object
    role*: MessageRole
    content*: seq[ContentPart]

  InferenceParameters* = object
    ## 采样与生成参数。全部使用 Option,以区分「未指定」与「显式取值」。
    maxTokens*: Option[int]
    temperature*: Option[float]
    topP*: Option[float]
    topK*: Option[int]
    seed*: Option[int]
    presencePenalty*: Option[float]
    frequencyPenalty*: Option[float]
    stopSequences*: seq[string]
      ## 空序列即「未指定」,不需要 Option。

  ResponseFormatKind* = enum
    ## 输出格式(§20.5.6)。
    rfkText = "text"
    rfkJsonObject = "json_object"
      ## 要求输出合法 JSON,但不约束具体结构。
    rfkJsonSchema = "json_schema"
      ## 要求输出符合给定 JSON Schema。

  ResponseFormat* = object
    case kind*: ResponseFormatKind
    of rfkText, rfkJsonObject:
      discard
    of rfkJsonSchema:
      schemaName*: string
      schema*: JsonNode

  CancellationToken* = ref object
    ## 取消令牌(§20.5.3 cancellation、§20.5.4 客户端断开处理)。
    ##
    ## 当前实现是单线程的:没有加锁。跨线程取消需要在引入 worker / async
    ## 时(§70)改为原子操作,而不是假装现在就是线程安全的。
    cancelledFlag: bool
    reasonText: string

  UnifiedInferenceRequest* = object
    ## §20.5.3 规定的统一请求模型。所有协议最终都转换成它。
    model*: string
    messages*: seq[Message]
    input*: string
      ## 非对话式的原始输入(embeddings、纯 completion 场景)。
      ## 与 messages 二者取一,不应同时提供。
    parameters*: InferenceParameters
    device*: string
      ## 目标设备。空字符串表示交给 Runtime Policy 决定(相当于 AUTO)。
      ## 显式指定而设备不可用时必须报错,不得静默回落(§12)。
    stream*: bool
    tools*: seq[ToolDefinition]
    toolChoice*: ToolChoice
    responseFormat*: ResponseFormat
    metadata*: Table[string, string]
      ## 透传的附加信息(请求 ID、客户端标识等)。不参与推理语义。
    cancellation*: CancellationToken
      ## 可以为 nil(表示该请求不可取消)。

  StopReason* = enum
    ## 生成终止原因。
    srUnspecified = "unspecified"
    srEndTurn = "end_turn"
    srMaxTokens = "max_tokens"
    srStopSequence = "stop_sequence"
    srToolUse = "tool_use"
    srCancelled = "cancelled"
    srError = "error"

  Usage* = object
    ## token 用量。
    ##
    ## 只存输入与输出两个计数,总数由 `totalTokens` 计算得出 ——
    ## 把总数也存成字段会引入「三个字段互相矛盾」的可能。
    inputTokens*: int
    outputTokens*: int

  UnifiedInferenceResult* = object
    ## §20.5.4 的统一推理结果。
    model*: string
    device*: string
      ## 实际执行推理的设备。可能与请求中的 device 不同(AUTO 决策的结果),
      ## 因此必须如实回报,让调用方知道真正跑在哪里。
    content*: seq[ContentPart]
    stopReason*: StopReason
    usage*: Usage
    metadata*: Table[string, string]

# ---------------------------------------------------------------------------
# 内容片段构造
# ---------------------------------------------------------------------------

proc textPart*(text: string): ContentPart =
  ContentPart(kind: cpkText, text: text)

proc reasoningPart*(text: string): ContentPart =
  ContentPart(kind: cpkReasoning, text: text)

proc toolUsePart*(call: ToolCall): ContentPart =
  ContentPart(kind: cpkToolUse, toolCall: call)

proc toolResultPart*(res: ToolResult): ContentPart =
  ContentPart(kind: cpkToolResult, toolResult: res)

proc initMessage*(role: MessageRole, content: seq[ContentPart]): Message =
  Message(role: role, content: content)

proc textMessage*(role: MessageRole, text: string): Message =
  ## 便捷构造:单个文本片段的消息。
  Message(role: role, content: @[textPart(text)])

proc plainText*(msg: Message): string =
  ## 提取消息中所有文本片段并拼接。
  ##
  ## **不包含** reasoning 片段:推理内容不属于对外回答的正文,
  ## 把它混进来会让日志与展示出现本不该暴露的内容。
  for part in msg.content:
    if part.kind == cpkText:
      result.add(part.text)

proc plainText*(parts: seq[ContentPart]): string =
  ## 同上,作用于内容片段序列(如结果的 content)。
  for part in parts:
    if part.kind == cpkText:
      result.add(part.text)

proc reasoningText*(parts: seq[ContentPart]): string =
  ## 提取推理片段文本。
  for part in parts:
    if part.kind == cpkReasoning:
      result.add(part.text)

proc toolCalls*(parts: seq[ContentPart]): seq[ToolCall] =
  ## 提取全部工具调用。
  for part in parts:
    if part.kind == cpkToolUse:
      result.add(part.toolCall)

# ---------------------------------------------------------------------------
# 响应格式构造
# ---------------------------------------------------------------------------

proc textFormat*(): ResponseFormat = ResponseFormat(kind: rfkText)
proc jsonObjectFormat*(): ResponseFormat = ResponseFormat(kind: rfkJsonObject)

proc jsonSchemaFormat*(name: string, schema: JsonNode): ResponseFormat =
  ResponseFormat(kind: rfkJsonSchema, schemaName: name, schema: schema)

# ---------------------------------------------------------------------------
# 取消令牌
# ---------------------------------------------------------------------------

proc newCancellationToken*(): CancellationToken =
  new(result)
  result.cancelledFlag = false
  result.reasonText = ""

proc cancel*(token: CancellationToken, reason: string = "") =
  ## 标记为已取消。重复调用保留**首次**的原因 ——
  ## 第一个取消原因才是真正触发取消的那个。
  if token == nil:
    return
  if not token.cancelledFlag:
    token.cancelledFlag = true
    token.reasonText = reason

proc isCancelled*(token: CancellationToken): bool =
  ## 是否已取消。nil 令牌视为未取消,调用方无需先判空。
  token != nil and token.cancelledFlag

proc cancelReason*(token: CancellationToken): string =
  if token == nil: "" else: token.reasonText

proc throwIfCancelled*(token: CancellationToken) =
  ## 已取消则抛 IsvikError(STREAM_CANCELLED)。
  ##
  ## 供推理循环在每步之间调用,使取消能及时生效。
  if token.isCancelled:
    raiseIsvikError(
      ecStreamCancelled,
      "Inference was cancelled",
      "reason=" & token.cancelReason
    )

# ---------------------------------------------------------------------------
# 用量
# ---------------------------------------------------------------------------

proc totalTokens*(usage: Usage): int =
  usage.inputTokens + usage.outputTokens

proc `+`*(a, b: Usage): Usage =
  ## 累加用量。流式推理过程中会多次收到增量用量。
  Usage(
    inputTokens: a.inputTokens + b.inputTokens,
    outputTokens: a.outputTokens + b.outputTokens
  )

# ---------------------------------------------------------------------------
# 请求构造与校验
# ---------------------------------------------------------------------------

proc initInferenceParameters*(): InferenceParameters =
  ## 全部参数均为「未指定」。
  InferenceParameters(
    maxTokens: none(int),
    temperature: none(float),
    topP: none(float),
    topK: none(int),
    seed: none(int),
    presencePenalty: none(float),
    frequencyPenalty: none(float),
    stopSequences: @[]
  )

proc initUnifiedInferenceRequest*(model: string): UnifiedInferenceRequest =
  ## 构造一个只指定模型的请求,其余字段为中性默认值。
  UnifiedInferenceRequest(
    model: model,
    messages: @[],
    input: "",
    parameters: initInferenceParameters(),
    device: "",
    stream: false,
    tools: @[],
    toolChoice: autoToolChoice(),
    responseFormat: textFormat(),
    metadata: initTable[string, string](),
    cancellation: nil
  )

proc validateParameters*(p: InferenceParameters): Option[string] =
  ## 校验采样参数取值范围。
  if p.maxTokens.isSome and p.maxTokens.get <= 0:
    return some("max_tokens must be positive, got: " & $p.maxTokens.get)

  if p.temperature.isSome:
    let t = p.temperature.get
    if t < 0.0 or t > 2.0:
      return some("temperature must be within 0.0..2.0, got: " & $t)

  if p.topP.isSome:
    let v = p.topP.get
    if v <= 0.0 or v > 1.0:
      return some("top_p must be within (0.0, 1.0], got: " & $v)

  if p.topK.isSome and p.topK.get <= 0:
    return some("top_k must be positive, got: " & $p.topK.get)

  for s in p.stopSequences:
    if s.len == 0:
      return some("stop sequences must not contain empty strings")

  result = none(string)

proc validate*(req: UnifiedInferenceRequest): Option[string] =
  ## 校验统一请求。返回 none 表示合法。
  ##
  ## 校验发生在进入 Core 之前,使非法请求得到 INVALID_REQUEST /
  ## INVALID_PARAMETER,而不是在更深的地方以难以理解的方式失败。
  if req.model.strip().len == 0:
    return some("model must not be empty")

  if req.messages.len == 0 and req.input.strip().len == 0:
    return some("request must provide either messages or input")

  if req.messages.len > 0 and req.input.strip().len > 0:
    # 同时提供两者意味着调用方意图不明,不猜测该用哪个。
    return some("request must not provide both messages and input")

  for i, msg in req.messages:
    if msg.content.len == 0:
      return some("message at index " & $i & " has no content")
    for part in msg.content:
      case part.kind
      of cpkToolResult:
        if part.toolResult.toolCallId.strip().len == 0:
          return some("tool result at message " & $i &
                      " has an empty tool_call_id")
      of cpkToolUse:
        if part.toolCall.id.strip().len == 0:
          return some("tool call at message " & $i & " has an empty id")
        if part.toolCall.name.strip().len == 0:
          return some("tool call at message " & $i & " has an empty name")
      of cpkText, cpkReasoning:
        discard

  let paramProblem = validateParameters(req.parameters)
  if paramProblem.isSome:
    return paramProblem

  let toolProblem = validateTools(req.tools)
  if toolProblem.isSome:
    return toolProblem

  let choiceProblem = validateToolChoice(req.toolChoice, req.tools)
  if choiceProblem.isSome:
    return choiceProblem

  if req.responseFormat.kind == rfkJsonSchema:
    if req.responseFormat.schema == nil:
      return some("response_format 'json_schema' requires a schema")
    if req.responseFormat.schema.kind != JObject:
      return some("response_format schema must be a JSON object, got: " &
                  $req.responseFormat.schema.kind)

  result = none(string)

proc requireValid*(req: UnifiedInferenceRequest) =
  ## 校验失败则抛 IsvikError(INVALID_REQUEST)。
  let problem = validate(req)
  if problem.isSome:
    raiseIsvikError(ecInvalidRequest, "Invalid inference request", problem.get)

proc initUnifiedInferenceResult*(model: string): UnifiedInferenceResult =
  UnifiedInferenceResult(
    model: model,
    device: "",
    content: @[],
    stopReason: srUnspecified,
    usage: Usage(inputTokens: 0, outputTokens: 0),
    metadata: initTable[string, string]()
  )
