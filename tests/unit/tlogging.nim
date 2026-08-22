## Task 3 测试:日志与「事件 → 日志」桥接

import std/[unittest, times, os, strutils, json]

import isvik/core/events
import isvik/core/errors
import isvik/logging/logger
import isvik/logging/event_log

type
  ## 测试专用 sink:不覆盖 write,因此会走基类实现并抛出 IsvikError。
  ## 定义在模块顶层而非 test 块内,因为 Nim 的 method 分派要求
  ## 参与继承体系的类型在模块级可见。
  BareSink = ref object of LogSink

proc fixedClock(iso: string): proc (): Time =
  let t = parse(iso, "yyyy-MM-dd'T'HH:mm:ss", utc()).toTime
  result = proc (): Time = t

var tmpDirCounter = 0

proc makeTempDir(): string =
  ## 为每个用例生成独立的临时目录。使用递增计数器而非随机数,
  ## 保证失败时目录名可预测、便于排查。
  inc tmpDirCounter
  result = getTempDir() / ("isvik_test_log_" & $tmpDirCounter)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "日志级别":

  test "五个级别的字符串表示符合 §34":
    check $llDebug == "DEBUG"
    check $llInfo == "INFO"
    check $llWarn == "WARN"
    check $llError == "ERROR"
    check $llFatal == "FATAL"

  test "级别总数为 5":
    var count = 0
    for _ in LogLevel:
      inc count
    check count == 5

  test "级别按严重程度递增排序":
    check ord(llDebug) < ord(llInfo)
    check ord(llInfo) < ord(llWarn)
    check ord(llWarn) < ord(llError)
    check ord(llError) < ord(llFatal)

suite "级别过滤":

  test "低于 minLevel 的记录被丢弃并计数":
    let log = newLogger(llWarn)
    let mem = newMemorySink()
    log.addSink(mem)

    log.debug("d")
    log.info("i")
    log.warn("w")
    log.error("e")
    log.fatal("f")

    check mem.records.len == 3
    check mem.records[0].level == llWarn
    check mem.records[1].level == llError
    check mem.records[2].level == llFatal
    check log.droppedCount == 2

  test "minLevel 为 DEBUG 时全部通过":
    let log = newLogger(llDebug)
    let mem = newMemorySink()
    log.addSink(mem)
    log.debug("d"); log.info("i"); log.warn("w"); log.error("e"); log.fatal("f")
    check mem.records.len == 5
    check log.droppedCount == 0

  test "minLevel 为 FATAL 时只有 FATAL 通过":
    let log = newLogger(llFatal)
    let mem = newMemorySink()
    log.addSink(mem)
    log.debug("d"); log.info("i"); log.warn("w"); log.error("e"); log.fatal("f")
    check mem.records.len == 1
    check mem.records[0].level == llFatal
    check log.droppedCount == 4

  test "isEnabled 与实际过滤行为一致":
    let log = newLogger(llWarn)
    check not log.isEnabled(llDebug)
    check not log.isEnabled(llInfo)
    check log.isEnabled(llWarn)
    check log.isEnabled(llError)
    check log.isEnabled(llFatal)

  test "运行时可调整 minLevel":
    let log = newLogger(llError)
    let mem = newMemorySink()
    log.addSink(mem)

    log.info("被丢弃")
    check mem.records.len == 0

    log.minLevel = llInfo
    log.info("被记录")
    check mem.records.len == 1
    check log.minLevel == llInfo

suite "日志格式":

  test "单行格式为 时间戳 [级别] 消息":
    let r = LogRecord(
      level: llInfo,
      timestamp: parse("2026-08-19T10:20:30", "yyyy-MM-dd'T'HH:mm:ss", utc()).toTime,
      message: "hello"
    )
    check formatLogRecord(r) == "2026-08-19T10:20:30.000Z [INFO ] hello"

  test "级别字段左对齐到 5 字符,使消息列对齐":
    let t = parse("2026-08-19T10:20:30", "yyyy-MM-dd'T'HH:mm:ss", utc()).toTime
    let infoLine = formatLogRecord(LogRecord(level: llInfo, timestamp: t, message: "m"))
    let fatalLine = formatLogRecord(LogRecord(level: llFatal, timestamp: t, message: "m"))
    check infoLine.len == fatalLine.len
    check infoLine.contains("[INFO ]")
    check fatalLine.contains("[FATAL]")

  test "时间戳为 UTC 毫秒精度,与事件时间戳格式一致":
    let t = parse("2026-01-01T00:00:00", "yyyy-MM-dd'T'HH:mm:ss", utc()).toTime
    check formatLogTime(t) == formatEventTime(t)

  test "中文与特殊字符原样保留":
    let r = LogRecord(level: llWarn, timestamp: getTime(),
                      message: "设备 NPU 不可用 \"quoted\" C:\\path")
    let line = formatLogRecord(r)
    check line.contains("设备 NPU 不可用")
    check line.contains("\"quoted\"")
    check line.contains("C:\\path")

suite "多 sink 分发":

  test "所有 sink 都收到同一条记录":
    let log = newLogger(llDebug)
    let a = newMemorySink()
    let b = newMemorySink()
    log.addSink(a)
    log.addSink(b)
    check log.sinkCount == 2

    log.info("broadcast")

    check a.records.len == 1
    check b.records.len == 1
    check a.records[0].message == "broadcast"
    check b.records[0].message == "broadcast"

  test "单个 sink 抛异常不影响其它 sink":
    # 「写日志失败」不应该让业务流程崩溃。
    let log = newLogger(llDebug)
    let good = newMemorySink()
    # BareSink 未覆盖 write,基类实现会抛 IsvikError
    log.addSink(BareSink())
    log.addSink(good)

    log.info("仍应到达 good")

    check good.records.len == 1

  test "未覆盖 write 的 sink 抛出 IsvikError(SERVER_ERROR)":
    let sink: LogSink = BareSink()
    var code: IsvikErrorCode
    var caught = false
    try:
      sink.write(LogRecord(level: llInfo, timestamp: getTime(), message: "x"))
    except IsvikError as e:
      caught = true
      code = e.code
    check caught
    check code == ecServerError

suite "MemorySink 容量限制":

  test "limit 为 0 时不限制条数":
    let mem = newMemorySink(0)
    let log = newLogger(llDebug)
    log.addSink(mem)
    for i in 1 .. 50:
      log.info("m" & $i)
    check mem.records.len == 50

  test "超出 limit 时丢弃最旧记录":
    let mem = newMemorySink(3)
    let log = newLogger(llDebug)
    log.addSink(mem)
    for i in 1 .. 6:
      log.info("m" & $i)
    check mem.records.len == 3
    check mem.records[0].message == "m4"
    check mem.records[1].message == "m5"
    check mem.records[2].message == "m6"

  test "lines 返回格式化后的文本":
    let mem = newMemorySink()
    let log = newLogger(llDebug, fixedClock("2026-08-19T00:00:00"))
    log.addSink(mem)
    log.warn("w1")
    let ls = mem.lines()
    check ls.len == 1
    check ls[0] == "2026-08-19T00:00:00.000Z [WARN ] w1"

suite "FileSink":

  setup:
    let tmpDir = makeTempDir()

  teardown:
    if dirExists(tmpDir):
      removeDir(tmpDir)

  test "写入文件并包含级别与消息":
    let path = tmpDir / "isvik.log"
    let sink = newFileSink(path)
    let log = newLogger(llDebug)
    log.addSink(sink)

    log.info("第一条")
    log.error("第二条")
    log.close()

    check fileExists(path)
    let content = readFile(path)
    check content.contains("[INFO ] 第一条")
    check content.contains("[ERROR] 第二条")

  test "父目录不存在时自动创建":
    let path = tmpDir / "nested" / "deeper" / "isvik.log"
    let sink = newFileSink(path)
    let log = newLogger(llDebug)
    log.addSink(sink)
    log.info("x")
    log.close()
    check fileExists(path)

  test "追加模式:再次打开不会截断已有内容":
    let path = tmpDir / "append.log"

    block:
      let log = newLogger(llDebug)
      log.addSink(newFileSink(path))
      log.info("第一次运行")
      log.close()

    block:
      let log = newLogger(llDebug)
      log.addSink(newFileSink(path))
      log.info("第二次运行")
      log.close()

    let content = readFile(path)
    check content.contains("第一次运行")
    check content.contains("第二次运行")

  test "关闭后写入变为无操作,不崩溃":
    let path = tmpDir / "closed.log"
    let sink = newFileSink(path)
    check not sink.isClosed

    sink.close()
    check sink.isClosed

    # 关闭后写入不应崩溃
    sink.write(LogRecord(level: llInfo, timestamp: getTime(), message: "丢弃"))

    let content = readFile(path)
    check not content.contains("丢弃")

  test "close 可重复调用":
    let sink = newFileSink(tmpDir / "twice.log")
    sink.close()
    sink.close()
    check sink.isClosed

  test "Logger.close 关闭全部 sink 并清空列表":
    let sink = newFileSink(tmpDir / "viaLogger.log")
    let log = newLogger(llDebug)
    log.addSink(sink)
    check log.sinkCount == 1

    log.close()

    check sink.isClosed
    check log.sinkCount == 0

  test "Logger.close 可重复调用":
    let log = newLogger(llDebug)
    log.addSink(newFileSink(tmpDir / "twiceLogger.log"))
    log.close()
    log.close()
    check log.sinkCount == 0

  test "日志内容立即落盘,不等到关闭":
    # 崩溃诊断依赖日志已经 flush。
    let path = tmpDir / "flush.log"
    let sink = newFileSink(path)
    let log = newLogger(llDebug)
    log.addSink(sink)

    log.fatal("崩溃前的最后一条")
    # 尚未 close,内容就应该已经可读
    check readFile(path).contains("崩溃前的最后一条")
    log.close()

suite "事件 → 日志 桥接":

  test "事件种类到日志级别的映射覆盖全部 10 种":
    # case 语句必须穷尽,这里确认每种都有确定的映射结果。
    for kind in RuntimeEventKind:
      discard levelFor(kind)

  test "ERROR 事件映射为 ERROR 级别":
    check levelFor(rekError) == llError

  test "生命周期里程碑事件映射为 INFO":
    check levelFor(rekRuntimeStarted) == llInfo
    check levelFor(rekBackendLoaded) == llInfo
    check levelFor(rekDeviceDetected) == llInfo
    check levelFor(rekModelLoaded) == llInfo

  test "高频事件映射为 DEBUG,避免淹没 INFO 日志":
    check levelFor(rekCompiling) == llDebug
    check levelFor(rekCacheHit) == llDebug
    check levelFor(rekCacheMiss) == llDebug
    check levelFor(rekInferenceStarted) == llDebug
    check levelFor(rekInferenceFinished) == llDebug

  test "事件文本形式为 KIND: message":
    let e = RuntimeEvent(kind: rekModelLoaded, timestamp: getTime(),
                         message: "qwen 已加载", payload: nil)
    check formatEventForLog(e) == "MODEL_LOADED: qwen 已加载"

  test "无 message 时只输出 KIND":
    let e = RuntimeEvent(kind: rekRuntimeStarted, timestamp: getTime(),
                         message: "", payload: nil)
    check formatEventForLog(e) == "RUNTIME_STARTED"

  test "payload 被附加到文本末尾":
    let e = RuntimeEvent(kind: rekCacheHit, timestamp: getTime(),
                         message: "命中", payload: %*{"key": "abc"})
    let text = formatEventForLog(e)
    check text.startsWith("CACHE_HIT: 命中")
    check text.contains("\"key\"")
    check text.contains("abc")

  test "空 payload 不附加多余内容":
    let e = RuntimeEvent(kind: rekCacheHit, timestamp: getTime(),
                         message: "命中", payload: newJObject())
    check formatEventForLog(e) == "CACHE_HIT: 命中"

  test "桥接后事件按级别写入日志":
    let bus = newEventBus()
    let log = newLogger(llDebug)
    let mem = newMemorySink()
    log.addSink(mem)
    bridgeEventsToLogger(bus, log)

    bus.publish(rekRuntimeStarted, "启动")
    bus.publish(rekError, "出错了")

    check mem.records.len == 2
    check mem.records[0].level == llInfo
    check mem.records[0].message == "RUNTIME_STARTED: 启动"
    check mem.records[1].level == llError
    check mem.records[1].message == "ERROR: 出错了"

  test "桥接遵守日志级别过滤":
    # minLevel=INFO 时,映射为 DEBUG 的高频事件不应落盘。
    let bus = newEventBus()
    let log = newLogger(llInfo)
    let mem = newMemorySink()
    log.addSink(mem)
    bridgeEventsToLogger(bus, log)

    bus.publish(rekCacheHit, "应被过滤")
    bus.publish(rekModelLoaded, "应被记录")

    check mem.records.len == 1
    check mem.records[0].message == "MODEL_LOADED: 应被记录"

  test "解除桥接后事件不再进入日志":
    let bus = newEventBus()
    let log = newLogger(llDebug)
    let mem = newMemorySink()
    log.addSink(mem)

    let id = bridgeEventsToLogger(bus, log)
    bus.publish(rekRuntimeStarted)
    check mem.records.len == 1

    bus.unsubscribe(id)
    bus.publish(rekRuntimeStarted)
    check mem.records.len == 1

  test "GUI 与日志可同时消费同一事件流":
    # §29 的核心:GUI 用结构化事件,日志是另一个独立消费者。
    let bus = newEventBus()
    let log = newLogger(llDebug)
    let mem = newMemorySink()
    log.addSink(mem)

    var guiEvents: seq[RuntimeEvent] = @[]
    bus.subscribe(proc (e: RuntimeEvent) = guiEvents.add(e))
    bridgeEventsToLogger(bus, log)

    bus.publish(rekDeviceDetected, "NPU", %*{"device": "NPU"})

    # GUI 拿到结构化事件(不需要解析日志文本)
    check guiEvents.len == 1
    check guiEvents[0].payload["device"].getStr == "NPU"
    # 日志同时拿到文本形式
    check mem.records.len == 1
    check mem.records[0].message.contains("DEVICE_DETECTED")
