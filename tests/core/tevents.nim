## Task 3 测试:结构化运行时事件与事件总线

import std/[unittest, json, times, sets, strutils]

import isvik/core/events

proc fixedClock(iso: string): proc (): Time =
  ## 返回一个恒定时间的时钟,用于确定性断言。
  let t = parse(iso, "yyyy-MM-dd'T'HH:mm:ss", utc()).toTime
  result = proc (): Time = t

suite "事件类型是稳定契约":

  test "10 个事件种类的字符串表示逐个精确匹配":
    check $rekRuntimeStarted == "RUNTIME_STARTED"
    check $rekBackendLoaded == "BACKEND_LOADED"
    check $rekDeviceDetected == "DEVICE_DETECTED"
    check $rekModelLoaded == "MODEL_LOADED"
    check $rekCompiling == "COMPILING"
    check $rekCacheHit == "CACHE_HIT"
    check $rekCacheMiss == "CACHE_MISS"
    check $rekInferenceStarted == "INFERENCE_STARTED"
    check $rekInferenceFinished == "INFERENCE_FINISHED"
    check $rekError == "ERROR"

  test "事件种类总数为 10,与 §29 列表一致":
    var count = 0
    for _ in RuntimeEventKind:
      inc count
    check count == 10
    check Section29EventNames.len == 10

  test "§29 列出的每个事件都有对应的稳定标识":
    var known = initHashSet[string]()
    for kind in RuntimeEventKind:
      known.incl($kind)
    for entry in Section29EventNames:
      check known.contains(entry.kind)

  test "§29 原文名去空格大写后与稳定标识一致":
    # 这条断言把「命名转换规则」固定下来:原文 "Cache Hit" -> "CACHE_HIT"。
    for entry in Section29EventNames:
      let derived = entry.section29Name.toUpperAscii.replace(" ", "_")
      check derived == entry.kind

  test "事件标识只含大写字母与下划线":
    for kind in RuntimeEventKind:
      check ($kind).allCharsInSet({'A'..'Z', '_'})

suite "事件总线:订阅与分发":

  test "无订阅者时发布不崩溃":
    let bus = newEventBus()
    bus.publish(rekRuntimeStarted, "启动")
    check bus.publishedCount == 1
    check bus.subscriberCount == 0

  test "单个订阅者收到事件的全部字段":
    let bus = newEventBus(fixedClock("2026-08-19T10:00:00"))
    var received: seq[RuntimeEvent] = @[]
    bus.subscribe(proc (e: RuntimeEvent) = received.add(e))

    bus.publish(rekDeviceDetected, "发现 NPU", %*{"device": "NPU"})

    check received.len == 1
    check received[0].kind == rekDeviceDetected
    check received[0].message == "发现 NPU"
    check received[0].payload != nil
    check received[0].payload["device"].getStr == "NPU"
    check formatEventTime(received[0].timestamp) == "2026-08-19T10:00:00.000Z"

  test "多个订阅者按注册顺序被调用":
    let bus = newEventBus()
    var order: seq[string] = @[]
    bus.subscribe(proc (e: RuntimeEvent) = order.add("first"))
    bus.subscribe(proc (e: RuntimeEvent) = order.add("second"))
    bus.subscribe(proc (e: RuntimeEvent) = order.add("third"))

    bus.publish(rekRuntimeStarted)

    check order == @["first", "second", "third"]

  test "多个事件按发布顺序到达":
    let bus = newEventBus()
    var kinds: seq[RuntimeEventKind] = @[]
    bus.subscribe(proc (e: RuntimeEvent) = kinds.add(e.kind))

    bus.publish(rekRuntimeStarted)
    bus.publish(rekBackendLoaded)
    bus.publish(rekDeviceDetected)
    bus.publish(rekInferenceStarted)
    bus.publish(rekInferenceFinished)

    check kinds == @[
      rekRuntimeStarted, rekBackendLoaded, rekDeviceDetected,
      rekInferenceStarted, rekInferenceFinished
    ]
    check bus.publishedCount == 5

  test "每个订阅者都收到同一条事件":
    let bus = newEventBus()
    var a, b = 0
    bus.subscribe(proc (e: RuntimeEvent) = inc a)
    bus.subscribe(proc (e: RuntimeEvent) = inc b)
    bus.publish(rekCacheHit)
    bus.publish(rekCacheMiss)
    check a == 2
    check b == 2

suite "事件总线:取消订阅":

  test "取消订阅后不再收到事件":
    let bus = newEventBus()
    var count = 0
    let id = bus.subscribe(proc (e: RuntimeEvent) = inc count)

    bus.publish(rekRuntimeStarted)
    check count == 1

    check bus.unsubscribe(id) == true
    check bus.subscriberCount == 0

    bus.publish(rekRuntimeStarted)
    check count == 1  # 未增加

  test "取消不存在的订阅返回 false":
    let bus = newEventBus()
    let id = bus.subscribe(proc (e: RuntimeEvent) = discard)
    check bus.unsubscribe(id) == true
    check bus.unsubscribe(id) == false  # 重复取消

  test "取消其中一个订阅不影响其它订阅":
    let bus = newEventBus()
    var kept = 0
    let removedId = bus.subscribe(proc (e: RuntimeEvent) = discard)
    bus.subscribe(proc (e: RuntimeEvent) = inc kept)

    bus.unsubscribe(removedId)
    bus.publish(rekRuntimeStarted)

    check bus.subscriberCount == 1
    check kept == 1

suite "事件总线:订阅者异常隔离":

  test "订阅者抛异常不影响后续订阅者,且被计数":
    # 一个 GUI 订阅者出错不应该让推理流程失败,
    # 但异常必须可观测,不能静默丢弃。
    let bus = newEventBus()
    var before, after = 0

    bus.subscribe(proc (e: RuntimeEvent) = inc before)
    bus.subscribe(proc (e: RuntimeEvent) =
      raise newException(ValueError, "订阅者内部错误"))
    bus.subscribe(proc (e: RuntimeEvent) = inc after)

    bus.publish(rekRuntimeStarted)

    check before == 1
    check after == 1                 # 异常没有中断分发
    check bus.handlerErrorCount == 1 # 异常被计数

  test "订阅者异常不传播给发布方":
    let bus = newEventBus()
    bus.subscribe(proc (e: RuntimeEvent) =
      raise newException(IOError, "boom"))
    # 若异常传播,这里会失败
    bus.publish(rekError, "some error")
    check bus.handlerErrorCount == 1

  test "多次异常累计计数":
    let bus = newEventBus()
    bus.subscribe(proc (e: RuntimeEvent) =
      raise newException(ValueError, "x"))
    bus.publish(rekRuntimeStarted)
    bus.publish(rekRuntimeStarted)
    bus.publish(rekRuntimeStarted)
    check bus.handlerErrorCount == 3

  test "正常情况下错误计数为零":
    let bus = newEventBus()
    bus.subscribe(proc (e: RuntimeEvent) = discard)
    bus.publish(rekRuntimeStarted)
    check bus.handlerErrorCount == 0

suite "事件总线:分发期间修改订阅列表":

  test "处理器内部新增订阅不会收到当前事件":
    # 使用订阅列表快照,保证分发过程的语义清晰。
    let bus = newEventBus()
    var lateCount = 0
    var firstFired = 0

    bus.subscribe(proc (e: RuntimeEvent) =
      inc firstFired
      if bus.subscriberCount == 1:
        bus.subscribe(proc (e2: RuntimeEvent) = inc lateCount)
    )

    bus.publish(rekRuntimeStarted)
    check firstFired == 1
    check lateCount == 0        # 新订阅者没有收到本次事件
    check bus.subscriberCount == 2

    bus.publish(rekRuntimeStarted)
    check lateCount == 1        # 下一次才收到

  test "处理器内部取消自身订阅不破坏本次分发":
    let bus = newEventBus()
    var tailFired = 0
    var selfId: SubscriptionId

    selfId = bus.subscribe(proc (e: RuntimeEvent) =
      bus.unsubscribe(selfId))
    bus.subscribe(proc (e: RuntimeEvent) = inc tailFired)

    bus.publish(rekRuntimeStarted)

    check tailFired == 1               # 后续订阅者仍被调用
    check bus.handlerErrorCount == 0
    check bus.subscriberCount == 1

suite "事件序列化":

  test "JSON 含 kind / timestamp / message":
    let bus = newEventBus(fixedClock("2026-01-02T03:04:05"))
    var captured: RuntimeEvent
    bus.subscribe(proc (e: RuntimeEvent) = captured = e)
    bus.publish(rekModelLoaded, "加载完成")

    let node = captured.toJsonNode()
    check node["kind"].getStr == "MODEL_LOADED"
    check node["timestamp"].getStr == "2026-01-02T03:04:05.000Z"
    check node["message"].getStr == "加载完成"

  test "payload 为 nil 时不输出 payload 字段":
    let e = RuntimeEvent(
      kind: rekRuntimeStarted,
      timestamp: getTime(),
      message: "",
      payload: nil
    )
    let node = e.toJsonNode()
    check not node.hasKey("payload")
    check node.len == 3

  test "payload 为空对象时不输出 payload 字段":
    let e = RuntimeEvent(
      kind: rekRuntimeStarted,
      timestamp: getTime(),
      message: "",
      payload: newJObject()
    )
    check not e.toJsonNode().hasKey("payload")

  test "非空 payload 被完整保留":
    let e = RuntimeEvent(
      kind: rekInferenceFinished,
      timestamp: getTime(),
      message: "done",
      payload: %*{"latencyMs": 12.5, "device": "CPU", "tokens": 42}
    )
    let node = e.toJsonNode()
    check node.hasKey("payload")
    check node["payload"]["latencyMs"].getFloat == 12.5
    check node["payload"]["device"].getStr == "CPU"
    check node["payload"]["tokens"].getInt == 42

  test "message 中的特殊字符被正确转义且可回解析":
    let nasty = "路径 C:\\a\\b \"引号\" 换行\n制表\t"
    let e = RuntimeEvent(
      kind: rekError,
      timestamp: getTime(),
      message: nasty,
      payload: nil
    )
    let reparsed = parseJson(e.toJson())
    check reparsed["message"].getStr == nasty

  test "所有事件种类都能生成合法 JSON":
    for kind in RuntimeEventKind:
      let e = RuntimeEvent(kind: kind, timestamp: getTime(), message: "x")
      let reparsed = parseJson(e.toJson())
      check reparsed["kind"].getStr == $kind

  test "时间戳统一为 UTC,格式为毫秒精度 ISO-8601":
    # 固定 UTC 而非本地时间,保证跨时区日志与 GUI 记录可对齐。
    let t = parse("2026-12-31T23:59:59", "yyyy-MM-dd'T'HH:mm:ss", utc()).toTime
    let s = formatEventTime(t)
    check s == "2026-12-31T23:59:59.000Z"
    check s.endsWith("Z")

suite "订阅句柄":

  test "订阅句柄互不相同":
    let bus = newEventBus()
    let a = bus.subscribe(proc (e: RuntimeEvent) = discard)
    let b = bus.subscribe(proc (e: RuntimeEvent) = discard)
    let c = bus.subscribe(proc (e: RuntimeEvent) = discard)
    check not (a == b)
    check not (b == c)
    check not (a == c)

  test "取消后新订阅不会复用已失效的句柄":
    # 防止「取消 A 后新订阅 B 拿到 A 的 id,导致误取消」这类问题。
    let bus = newEventBus()
    let a = bus.subscribe(proc (e: RuntimeEvent) = discard)
    bus.unsubscribe(a)
    let b = bus.subscribe(proc (e: RuntimeEvent) = discard)
    check not (a == b)
