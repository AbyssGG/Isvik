## Protocol Adapter 接口
##
## 对应 Master Prompt §20.5.2、§20.5.4、§20.5.7、§20.5.13。
##
## ---
##
## ## 硬性规则(§20.5.2)
##
## ```text
## External Request
##       ↓
## Protocol Adapter     ← 本模块定义其接口
##       ↓
## Unified Inference Request
##       ↓
##   Isvik Core
## ```
##
## 禁止的路径:
##
## ```text
## Anthropic API → OpenVINO
## OpenAI API    → OpenVINO
## HTTP Handler  → OpenVINO
## ```
##
## 本模块只定义**接口**,不含任何具体协议实现,也不含 HTTP。
## Adapter 实现位于 `src/isvik/protocol/`。
##
## ---
##
## ## 为什么 Adapter 必须声明自己的能力
##
## §20.5.13 第 12 条:
##
## > 未实现的第三方 API 能力必须明确返回 Unsupported,不得伪造完全兼容。
##
## 靠文档说明「我们暂不支持 X」是不够的 —— 运行时必须真的拒绝。
## 因此每个 Adapter 通过 `capabilities()` 声明自己支持什么,
## `requireCapability` 在不支持时抛 `NOT_IMPLEMENTED`。
##
## 这样「声明的能力」与「实际行为」由同一处代码决定,不会分叉。

import std/[json, strutils]

import isvik/core/errors
import isvik/core/inference
import isvik/core/inference_events
import isvik/core/tools

type
  ProtocolCapability* = enum
    ## Adapter 可声明的能力项。
    pcStreaming = "streaming"
      ## §20.5.4 流式响应。
    pcToolCalling = "tool_calling"
      ## §20.5.5 工具调用。
    pcStructuredOutput = "structured_output"
      ## §20.5.6 结构化输出(json_object / json_schema)。
    pcReasoning = "reasoning"
      ## 推理内容单独输出(ReasoningDelta)。
    pcMultiTurn = "multi_turn"
      ## 多轮对话(messages 数组)。
    pcSingleInput = "single_input"
      ## 单条原始输入(embeddings / completion 风格)。
    pcCancellation = "cancellation"
      ## 请求取消。

  ProtocolStreamChunk* = object
    ## 一个协议层的流式数据块。
    ##
    ## 有意**不包含** SSE 的物理格式(`event:` / `data:` 前缀、空行分隔):
    ## 那属于 HTTP 传输层,由 server 负责拼装。Core 只描述
    ## 「这个块叫什么、内容是什么、是否是结束标记」。
    ##
    ## 这样同一个 Adapter 未来也能用于 WebSocket 或其它传输方式,
    ## 而不必修改。
    eventName*: string
      ## 协议事件名。Anthropic SSE 需要它(`event: content_block_delta`);
      ## OpenAI SSE 不需要,留空即可。
    data*: JsonNode
      ## 数据载荷。可以为 nil(仅用于纯结束标记)。
    isDone*: bool
      ## 是否为终止标记。OpenAI 用字面量 `[DONE]` 表示,
      ## 该细节由 server 依据此标记生成,不在 data 中硬编码。

  ProtocolAdapter* = ref object of RootObj
    ## 协议适配器接口。
    ##
    ## 与 Backend 抽象一样采用继承 + method:当前需要的实现数量有限
    ## (Anthropic / OpenAI Chat / OpenAI Responses / Native),
    ## 不引入注册表或动态加载机制(§6 不要过度抽象)。

proc raiseAdapterNotImplemented(a: ProtocolAdapter,
                                operation: string) {.noreturn.} =
  raiseIsvikError(
    ecNotImplemented,
    "Protocol adapter operation is not implemented",
    "adapter=" & (if a == nil: "nil" else: $a.type) &
      " operation=" & operation
  )

# ---------------------------------------------------------------------------
# 元信息与能力声明
# ---------------------------------------------------------------------------

method protocolName*(a: ProtocolAdapter): string {.base.} =
  ## 协议标识,如 "anthropic" / "openai-chat" / "isvik-native"。
  raiseAdapterNotImplemented(a, "protocolName")

method apiVersion*(a: ProtocolAdapter): string {.base.} =
  ## 协议版本路径前缀,如 "/v1" 或 "/api/v1"(§20.5.9)。
  raiseAdapterNotImplemented(a, "apiVersion")

method capabilities*(a: ProtocolAdapter): set[ProtocolCapability] {.base.} =
  ## 该 Adapter 支持的能力集合。
  ##
  ## 必须**如实**声明。声明了却不实现,比不声明更糟:客户端会按声明去用,
  ## 然后得到静默错误的结果(§20.5.13 第 12 条)。
  raiseAdapterNotImplemented(a, "capabilities")

proc supports*(a: ProtocolAdapter, capability: ProtocolCapability): bool =
  ## 是否支持某能力。
  capability in a.capabilities()

proc requireCapability*(a: ProtocolAdapter,
                        capability: ProtocolCapability) =
  ## 不支持该能力时抛 IsvikError(NOT_IMPLEMENTED)。
  ##
  ## 这是 §20.5.13 第 12 条在代码层面的落实点:
  ## 明确返回 Unsupported,而不是静默忽略请求中的某个字段。
  if capability notin a.capabilities():
    raiseIsvikError(
      ecNotImplemented,
      "This capability is not supported by the requested API protocol",
      "protocol=" & a.protocolName() & " capability=" & $capability
    )

# ---------------------------------------------------------------------------
# 请求方向:外部协议 → Unified
# ---------------------------------------------------------------------------

method parseRequest*(a: ProtocolAdapter,
                     body: JsonNode): UnifiedInferenceRequest {.base.} =
  ## 把外部协议的请求体转换为统一请求。
  ##
  ## 形状不合法抛 INVALID_REQUEST;字段取值不合法抛 INVALID_PARAMETER;
  ## 请求用到了本 Adapter 未实现的能力抛 NOT_IMPLEMENTED。
  raiseAdapterNotImplemented(a, "parseRequest")

# ---------------------------------------------------------------------------
# 响应方向:Unified → 外部协议
# ---------------------------------------------------------------------------

method formatResult*(a: ProtocolAdapter,
                     res: UnifiedInferenceResult): JsonNode {.base.} =
  ## 把统一结果转换为该协议的非流式响应体。
  raiseAdapterNotImplemented(a, "formatResult")

method formatEvent*(a: ProtocolAdapter,
                    e: InferenceEvent): seq[ProtocolStreamChunk] {.base.} =
  ## 把一条统一事件转换为该协议的流式数据块。
  ##
  ## 返回 **seq** 而不是单个块,因为映射不是一对一的:
  ##
  ## - 一条内部事件可能需要产生多个协议事件
  ##   (Anthropic 的 content_block_start + content_block_delta)
  ## - 也可能在某协议中没有对应事件,此时返回空序列
  ##   (例如 ReasoningDelta 在不支持推理输出的协议中应被丢弃,
  ##    而不是硬塞进普通文本里 —— 那会污染正文)
  raiseAdapterNotImplemented(a, "formatEvent")

method formatError*(a: ProtocolAdapter, code: IsvikErrorCode,
                    message: string): JsonNode {.base.} =
  ## 把 Isvik 错误转换为该协议的错误响应体(§20.5.7)。
  ##
  ## 错误必须先是 IsvikError,再由此转换为协议错误:
  ##
  ## ```text
  ## Backend Error → Isvik Error → Protocol Error
  ## ```
  ##
  ## 只接受 code 与 message 两个参数,而不是整个 `ref IsvikError` ——
  ## 从签名上保证 detail 不可能被误写进对外响应。
  raiseAdapterNotImplemented(a, "formatError")

proc defaultHttpStatusFor*(code: IsvikErrorCode): int =
  ## 错误码到 HTTP 状态码的默认映射。
  ##
  ## 划分依据:调用方能自行修正的问题归 4xx,服务端或环境问题归 5xx。
  ## 设备不可用归 503 而非 400 —— 请求本身没错,是当前环境不具备该能力。
  case code
  of ecModelNotFound: 404
  of ecModelInvalid, ecModelUnsupported: 400
  of ecInvalidRequest, ecInvalidParameter: 400
  of ecUnauthorized: 401
  of ecToolCallFailed: 400
  of ecStreamCancelled: 499          # 客户端主动断开(nginx 约定)
  of ecDeviceNotAvailable, ecNpuNotAvailable, ecGpuNotAvailable: 503
  of ecBackendNotAvailable: 503
  of ecNotImplemented: 501
  of ecCompilationFailed, ecInferenceFailed: 500
  of ecCacheInvalid, ecCacheCorrupted: 500
  of ecServerError: 500

method httpStatusFor*(a: ProtocolAdapter,
                      code: IsvikErrorCode): int {.base.} =
  ## 该错误码对应的 HTTP 状态码。
  ##
  ## 由 Adapter 决定而非 Core:不同协议对同一语义错误的状态码约定不同。
  ## 默认采用 `defaultHttpStatusFor`,Adapter 可覆盖。
  defaultHttpStatusFor(code)

# ---------------------------------------------------------------------------
# 请求能力校验
# ---------------------------------------------------------------------------

proc requiredCapabilities*(req: UnifiedInferenceRequest):
    set[ProtocolCapability] =
  ## 推导一个请求实际用到了哪些能力。
  ##
  ## 用途:在真正开始推理之前,就能判断当前 Adapter 是否支持这个请求,
  ## 从而把 NOT_IMPLEMENTED 在入口处返回,而不是跑到一半才失败。
  result = {}
  if req.stream:
    result.incl(pcStreaming)
  if req.tools.len > 0 or req.toolChoice.kind != tckAuto:
    result.incl(pcToolCalling)
  if req.responseFormat.kind != rfkText:
    result.incl(pcStructuredOutput)
  if req.messages.len > 0:
    result.incl(pcMultiTurn)
  if req.input.len > 0:
    result.incl(pcSingleInput)
  if req.cancellation != nil:
    result.incl(pcCancellation)
  for msg in req.messages:
    for part in msg.content:
      if part.kind == cpkReasoning:
        result.incl(pcReasoning)

proc requireSupportedRequest*(a: ProtocolAdapter,
                              req: UnifiedInferenceRequest) =
  ## 校验该 Adapter 能否处理这个请求。
  ##
  ## 不支持时抛 NOT_IMPLEMENTED,并在 detail 中列出缺失的能力,
  ## 让调用方知道究竟是哪一项不被支持。
  let needed = requiredCapabilities(req)
  let available = a.capabilities()
  var missing: seq[string] = @[]
  for capability in needed:
    if capability notin available:
      missing.add($capability)
  if missing.len > 0:
    raiseIsvikError(
      ecNotImplemented,
      "The request uses capabilities that this API protocol does not support",
      "protocol=" & a.protocolName() & " missing=" & missing.join(",")
    )

# ---------------------------------------------------------------------------
# 流式块辅助
# ---------------------------------------------------------------------------

proc initChunk*(eventName: string, data: JsonNode): ProtocolStreamChunk =
  ProtocolStreamChunk(eventName: eventName, data: data, isDone: false)

proc doneChunk*(eventName: string = ""): ProtocolStreamChunk =
  ## 终止标记块。
  ProtocolStreamChunk(eventName: eventName, data: nil, isDone: true)

proc noChunks*(): seq[ProtocolStreamChunk] =
  ## 表示「该事件在本协议中无对应输出」。
  ##
  ## 显式提供这个函数,是为了让「有意丢弃」在代码里看得出来,
  ## 而不是写成一个容易被误读为遗漏的空 `@[]`。
  @[]

# ---------------------------------------------------------------------------
# Adapter 注册表
# ---------------------------------------------------------------------------

type
  AdapterRegistry* = ref object
    ## 按协议名索引 Adapter。
    ##
    ## 保持极简:只有注册与查找。API Gateway 依据 URL 路径选择 Adapter,
    ## 不需要优先级、中间件链之类的机制。
    adapters: seq[ProtocolAdapter]

proc newAdapterRegistry*(): AdapterRegistry =
  new(result)
  result.adapters = @[]

proc register*(registry: AdapterRegistry, adapter: ProtocolAdapter) =
  ## 注册一个 Adapter。协议名重复时抛错,避免出现「哪个生效」的不确定性。
  doAssert adapter != nil, "不能注册 nil adapter"
  let name = adapter.protocolName()
  for existing in registry.adapters:
    if existing.protocolName() == name:
      raiseIsvikError(
        ecServerError,
        "A protocol adapter with this name is already registered",
        "protocol=" & name
      )
  registry.adapters.add(adapter)

proc find*(registry: AdapterRegistry, protocolName: string): ProtocolAdapter =
  ## 按协议名查找。找不到返回 nil。
  for adapter in registry.adapters:
    if adapter.protocolName() == protocolName:
      return adapter
  result = nil

proc get*(registry: AdapterRegistry, protocolName: string): ProtocolAdapter =
  ## 按协议名查找,找不到抛 INVALID_REQUEST。
  result = registry.find(protocolName)
  if result == nil:
    var known: seq[string] = @[]
    for adapter in registry.adapters:
      known.add(adapter.protocolName())
    raiseIsvikError(
      ecInvalidRequest,
      "Unknown API protocol",
      "requested=" & protocolName & " registered=" & known.join(",")
    )

proc protocolNames*(registry: AdapterRegistry): seq[string] =
  for adapter in registry.adapters:
    result.add(adapter.protocolName())

proc len*(registry: AdapterRegistry): int = registry.adapters.len
