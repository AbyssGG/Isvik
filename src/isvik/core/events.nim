## Isvik 结构化运行时事件
##
## 对应 Master Prompt §29「GUI Activity」:
## GUI 的 Activity 页依据结构化事件渲染,**不解析日志文件**。
## 事件总线的存在就是为了让这条约束在架构上成立 —— 日志是事件的一个消费者,
## 而不是 GUI 的数据来源。
##
## ---
##
## **重要:本模块的事件与「推理流事件」是两套不同的东西,不要混用。**
##
## | | 本模块 `RuntimeEvent` | Task 7 的 `InferenceEvent` |
## | --- | --- | --- |
## | 规范来源 | §29 GUI Activity | §20.5.4 Unified Event Stream |
## | 粒度 | 运行时生命周期(进程级) | 单次推理内部(token 级) |
## | 典型值 | RUNTIME_STARTED / CACHE_HIT | ContentDelta / ToolCallDelta |
## | 消费者 | GUI Activity 页、日志 | Protocol Adapter → SSE |
##
## ---
##
## 依赖方向(不可反转):
##
## ```text
## core/events.nim  ←── logging/    (日志订阅事件)
##       ↑
##   core 其它模块   (发布事件)
## ```
##
## Core 自身不依赖 logging。需要记录日志的 Core 代码发布事件即可,
## 由 logging 层订阅并落盘。这样 Core 不需要知道日志的存在。

import std/[json, times]

type
  RuntimeEventKind* = enum
    ## §29 列出的事件全集。
    ##
    ## 字符串值是稳定契约(GUI / API 依赖它做分支与本地化),
    ## 采用 SCREAMING_SNAKE_CASE 而非 §29 原文的「Runtime Started」形式,
    ## 因为后者含空格,不适合作为机器可读标识。
    ## §29 原文与此处的对应关系见 Section29EventNames。
    rekRuntimeStarted = "RUNTIME_STARTED"
    rekBackendLoaded = "BACKEND_LOADED"
    rekDeviceDetected = "DEVICE_DETECTED"
    rekModelLoaded = "MODEL_LOADED"
    rekCompiling = "COMPILING"
    rekCacheHit = "CACHE_HIT"
    rekCacheMiss = "CACHE_MISS"
    rekInferenceStarted = "INFERENCE_STARTED"
    rekInferenceFinished = "INFERENCE_FINISHED"
    rekError = "ERROR"

  RuntimeEvent* = object
    ## 一条结构化运行时事件。
    kind*: RuntimeEventKind
    timestamp*: Time
      ## 事件产生时刻。由 EventBus 的时钟注入,便于测试确定性。
    message*: string
      ## 面向开发者的简短描述。面向最终用户的文案由 GUI 依据 kind 本地化。
    payload*: JsonNode
      ## 结构化附加数据,应为 JObject。可以为 nil(表示无附加数据)。

  SubscriptionId* = distinct int
    ## 订阅句柄,用于取消订阅。

  RuntimeEventHandler* = proc (e: RuntimeEvent)
    ## 事件处理器。
    ##
    ## 处理器抛出的异常会被总线捕获并计数(见 `handlerErrorCount`),
    ## 不会打断其它处理器,也不会传播给发布方。理由:一个 GUI 订阅者出错
    ## 不应该让推理流程失败。但异常被计数而非静默丢弃,保证问题可观测。

  Subscription = object
    id: int
    handler: RuntimeEventHandler

  EventBusObj = object
    subs: seq[Subscription]
    nextId: int
    clock: proc (): Time
    handlerErrors: int
    published: int

  EventBus* = ref EventBusObj
    ## 进程内事件总线。
    ##
    ## 当前实现是单线程的:没有加锁。跨线程发布事件需要在引入
    ## worker / async 时(§70)另行设计,届时应显式加同步而不是假装现在就安全。

const
  Section29EventNames*: array[10, tuple[kind: string, section29Name: string]] = [
    ## §29 原文事件名与稳定标识的对应关系。用于规范一致性测试。
    ("RUNTIME_STARTED", "Runtime Started"),
    ("BACKEND_LOADED", "Backend Loaded"),
    ("DEVICE_DETECTED", "Device Detected"),
    ("MODEL_LOADED", "Model Loaded"),
    ("COMPILING", "Compiling"),
    ("CACHE_HIT", "Cache Hit"),
    ("CACHE_MISS", "Cache Miss"),
    ("INFERENCE_STARTED", "Inference Started"),
    ("INFERENCE_FINISHED", "Inference Finished"),
    ("ERROR", "Error")
  ]

proc `==`*(a, b: SubscriptionId): bool {.borrow.}
proc `$`*(id: SubscriptionId): string {.borrow.}

# ---------------------------------------------------------------------------
# 构造
# ---------------------------------------------------------------------------

proc newEventBus*(clock: proc (): Time = nil): EventBus =
  ## 创建事件总线。
  ##
  ## `clock` 为 nil 时使用系统时间。测试可注入固定时钟以获得确定性时间戳。
  new(result)
  result.subs = @[]
  result.nextId = 1
  if clock == nil:
    result.clock = proc (): Time = getTime()
  else:
    result.clock = clock

# ---------------------------------------------------------------------------
# 订阅
# ---------------------------------------------------------------------------

proc subscribe*(bus: EventBus, handler: RuntimeEventHandler): SubscriptionId
    {.discardable.} =
  ## 注册事件处理器,返回用于取消的句柄。
  ##
  ## 返回值标记为 discardable:多数订阅者(如日志桥接)生命周期与进程相同,
  ## 不需要保留句柄。需要取消时再接收返回值即可。
  ##
  ## 处理器按注册顺序被调用。
  doAssert handler != nil, "事件处理器不能为 nil"
  result = SubscriptionId(bus.nextId)
  bus.subs.add(Subscription(id: bus.nextId, handler: handler))
  inc bus.nextId

proc unsubscribe*(bus: EventBus, id: SubscriptionId): bool {.discardable.} =
  ## 取消订阅。返回是否确实移除了一个订阅。
  let target = int(id)
  for i in 0 ..< bus.subs.len:
    if bus.subs[i].id == target:
      bus.subs.delete(i)
      return true
  result = false

proc subscriberCount*(bus: EventBus): int =
  ## 当前订阅者数量。
  bus.subs.len

# ---------------------------------------------------------------------------
# 发布
# ---------------------------------------------------------------------------

proc dispatch*(bus: EventBus, e: RuntimeEvent) =
  ## 将已构造好的事件分发给所有订阅者。
  ##
  ## 遍历订阅者列表的**快照**:处理器内部允许 subscribe / unsubscribe,
  ## 不会破坏本次分发的迭代,也不会让本次新增的订阅者收到当前事件。
  inc bus.published
  let snapshot = bus.subs
  for sub in snapshot:
    try:
      sub.handler(e)
    except CatchableError:
      inc bus.handlerErrors
    except Defect:
      # Defect 表示程序性错误(如索引越界)。这里同样不允许它打断其它
      # 订阅者与主流程,但计入错误数以便暴露问题。
      inc bus.handlerErrors

proc publish*(
  bus: EventBus,
  kind: RuntimeEventKind,
  message: string = "",
  payload: JsonNode = nil
) =
  ## 构造并发布一条事件。时间戳由总线时钟决定。
  bus.dispatch(RuntimeEvent(
    kind: kind,
    timestamp: bus.clock(),
    message: message,
    payload: payload
  ))

proc handlerErrorCount*(bus: EventBus): int =
  ## 处理器抛出异常的累计次数。
  ##
  ## 非零说明有订阅者在出错。总线选择不让这类异常传播,
  ## 但通过该计数保证问题不会被静默掩盖。
  bus.handlerErrors

proc publishedCount*(bus: EventBus): int =
  ## 已发布事件总数。
  bus.published

# ---------------------------------------------------------------------------
# 序列化
# ---------------------------------------------------------------------------

const eventTimeFormat = "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'"

proc formatEventTime*(t: Time): string =
  ## 事件时间戳的标准文本形式:UTC ISO-8601,毫秒精度。
  ##
  ## 固定用 UTC 而非本地时间,避免不同时区的日志与 GUI 记录无法对齐。
  t.utc.format(eventTimeFormat)

proc toJsonNode*(e: RuntimeEvent): JsonNode =
  ## 事件的 JSON 表示,供 GUI Activity 与 Local API 使用。
  ##
  ## payload 为 nil 或空对象时不输出该字段,保持输出干净。
  result = %*{
    "kind": $e.kind,
    "timestamp": formatEventTime(e.timestamp),
    "message": e.message
  }
  if e.payload != nil and e.payload.kind == JObject and e.payload.len > 0:
    result["payload"] = e.payload

proc toJson*(e: RuntimeEvent): string =
  $e.toJsonNode()
