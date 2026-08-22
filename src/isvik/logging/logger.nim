## Isvik 日志
##
## 对应 Master Prompt §34:五级日志(DEBUG / INFO / WARN / ERROR / FATAL),
## 输出到 Console 与 File。
##
## 关键设计决策:
##
## 1. **Console sink 默认写 stderr,不写 stdout。**
##    CLI 的 `--json` 输出必须是纯净的、可被管道解析的 JSON。
##    如果日志混进 stdout,`isvik devices --json | ConvertFrom-Json` 会失败。
##
## 2. **资源释放是显式的。** Sink 提供 `close()`,由 Logger.close() 统一调用,
##    不依赖析构器的时机(§69 要求 native / OS 资源的所有权明确)。
##
## 3. **日志不是 GUI 的数据来源。** GUI Activity 页消费 core/events 的结构化事件
##    (§29),日志只是事件的另一个消费者。见 logging/event_log.nim。

import std/[times, os, strutils]

import isvik/core/errors

type
  LogLevel* = enum
    ## §34 规定的五个级别,按严重程度递增。
    ## 字符串值用于日志文本与配置文件(§33 的 logging 配置项)。
    llDebug = "DEBUG"
    llInfo = "INFO"
    llWarn = "WARN"
    llError = "ERROR"
    llFatal = "FATAL"

  LogRecord* = object
    ## 一条日志记录。
    level*: LogLevel
    timestamp*: Time
    message*: string

  LogSink* = ref object of RootObj
    ## 日志输出目标的基类。

  ConsoleSink* = ref object of LogSink
    ## 输出到控制台。
    useStderr*: bool
      ## true(默认)写 stderr。仅在明确需要时才写 stdout,
      ## 否则会污染 --json 的输出。

  FileSink* = ref object of LogSink
    ## 追加写入文件。
    path*: string
    handle: File
    isOpen: bool

  MemorySink* = ref object of LogSink
    ## 记录到内存,供测试与 GUI 的近期日志视图使用。
    records*: seq[LogRecord]
    limit*: int
      ## 最多保留的记录数,0 表示不限制。超出时丢弃最旧的。

  LoggerObj = object
    minLevel: LogLevel
    sinks: seq[LogSink]
    clock: proc (): Time
    dropped: int

  Logger* = ref LoggerObj
    ## 日志器。将记录分发给所有 sink。
    ##
    ## 当前实现是单线程的:没有加锁。多线程日志需要在引入 worker 时
    ## (§70)显式加同步。

# ---------------------------------------------------------------------------
# Sink 基类接口
# ---------------------------------------------------------------------------

method write*(sink: LogSink, r: LogRecord) {.base.} =
  ## 写入一条记录。子类必须覆盖。
  raiseIsvikError(
    ecServerError,
    "LogSink.write is not implemented by this sink",
    "sink=" & $sink.type
  )

method close*(sink: LogSink) {.base.} =
  ## 释放 sink 持有的资源。基类默认无资源可释放。
  discard

# ---------------------------------------------------------------------------
# 格式化
# ---------------------------------------------------------------------------

const logTimeFormat = "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'"

proc formatLogTime*(t: Time): string =
  ## 与事件时间戳一致的格式:UTC ISO-8601,毫秒精度。
  ## 统一使用 UTC,保证日志与 GUI Activity 记录可对齐。
  t.utc.format(logTimeFormat)

proc formatLogRecord*(r: LogRecord): string =
  ## 单行日志文本。级别左对齐到 5 字符宽(最长的 "FATAL"/"DEBUG" 即 5 字符),
  ## 使多行日志的消息列对齐。
  formatLogTime(r.timestamp) & " [" & alignLeft($r.level, 5) & "] " & r.message

# ---------------------------------------------------------------------------
# ConsoleSink
# ---------------------------------------------------------------------------

proc newConsoleSink*(useStderr: bool = true): ConsoleSink =
  ## 创建控制台 sink。默认写 stderr,理由见模块顶部说明。
  ConsoleSink(useStderr: useStderr)

method write*(sink: ConsoleSink, r: LogRecord) =
  let line = formatLogRecord(r)
  if sink.useStderr:
    stderr.writeLine(line)
  else:
    stdout.writeLine(line)

# ---------------------------------------------------------------------------
# FileSink
# ---------------------------------------------------------------------------

proc newFileSink*(path: string): FileSink =
  ## 创建文件 sink,以追加模式打开。父目录不存在时自动创建。
  ##
  ## 打开失败时抛 IsvikError(SERVER_ERROR),而不是静默丢日志 ——
  ## 「日志写不进去」本身是必须让人知道的故障。
  let parent = path.parentDir
  if parent.len > 0 and not dirExists(parent):
    try:
      createDir(parent)
    except OSError as e:
      raiseIsvikError(
        ecServerError,
        "Failed to create log directory",
        "path=" & parent & " os=" & e.msg
      )

  var f: File
  if not f.open(path, fmAppend):
    raiseIsvikError(
      ecServerError,
      "Failed to open log file for appending",
      "path=" & path
    )

  result = FileSink(path: path, handle: f, isOpen: true)

method write*(sink: FileSink, r: LogRecord) =
  ## 写入并立即 flush。
  ##
  ## flush 是有意的:崩溃诊断依赖日志已经落盘。日志量不构成性能瓶颈时,
  ## 可靠性优先于吞吐(§73 Correctness > Performance)。
  if not sink.isOpen:
    return
  sink.handle.writeLine(formatLogRecord(r))
  sink.handle.flushFile()

method close*(sink: FileSink) =
  ## 关闭文件。可重复调用。关闭后 write 变为无操作,不会崩溃。
  if sink.isOpen:
    sink.handle.close()
    sink.isOpen = false

proc isClosed*(sink: FileSink): bool =
  not sink.isOpen

# ---------------------------------------------------------------------------
# MemorySink
# ---------------------------------------------------------------------------

proc newMemorySink*(limit: int = 0): MemorySink =
  ## 创建内存 sink。limit 为 0 表示不限制条数。
  MemorySink(records: @[], limit: limit)

method write*(sink: MemorySink, r: LogRecord) =
  sink.records.add(r)
  if sink.limit > 0 and sink.records.len > sink.limit:
    # 丢弃最旧的记录,保持有界内存占用。
    # 注意:seq 的 delete 只有单索引重载,没有 slice 重载(那是 string 的),
    # 因此这里用切片重新赋值。
    let excess = sink.records.len - sink.limit
    sink.records = sink.records[excess .. ^1]

proc lines*(sink: MemorySink): seq[string] =
  ## 已记录内容的文本形式,便于断言。
  result = newSeqOfCap[string](sink.records.len)
  for r in sink.records:
    result.add(formatLogRecord(r))

# ---------------------------------------------------------------------------
# Logger
# ---------------------------------------------------------------------------

proc newLogger*(
  minLevel: LogLevel = llInfo,
  clock: proc (): Time = nil
): Logger =
  ## 创建日志器。低于 minLevel 的记录被丢弃。
  ##
  ## `clock` 为 nil 时使用系统时间;测试可注入固定时钟。
  new(result)
  result.minLevel = minLevel
  result.sinks = @[]
  if clock == nil:
    result.clock = proc (): Time = getTime()
  else:
    result.clock = clock

proc addSink*(logger: Logger, sink: LogSink) =
  doAssert sink != nil, "日志 sink 不能为 nil"
  logger.sinks.add(sink)

proc sinkCount*(logger: Logger): int =
  logger.sinks.len

proc minLevel*(logger: Logger): LogLevel =
  logger.minLevel

proc `minLevel=`*(logger: Logger, level: LogLevel) =
  logger.minLevel = level

proc droppedCount*(logger: Logger): int =
  ## 因级别过滤而被丢弃的记录数。可观测性,便于确认过滤确实在生效。
  logger.dropped

proc isEnabled*(logger: Logger, level: LogLevel): bool =
  ## 该级别是否会被输出。调用方可用它跳过昂贵的消息构造。
  ord(level) >= ord(logger.minLevel)

proc log*(logger: Logger, level: LogLevel, message: string) =
  ## 记录一条日志。
  ##
  ## 单个 sink 抛出的异常会被隔离:不影响其它 sink,也不传播给调用方。
  ## 「写日志失败」不应该让推理流程崩溃。
  if not logger.isEnabled(level):
    inc logger.dropped
    return

  let record = LogRecord(
    level: level,
    timestamp: logger.clock(),
    message: message
  )
  for sink in logger.sinks:
    try:
      sink.write(record)
    except CatchableError:
      discard

proc debug*(logger: Logger, message: string) = logger.log(llDebug, message)
proc info*(logger: Logger, message: string) = logger.log(llInfo, message)
proc warn*(logger: Logger, message: string) = logger.log(llWarn, message)
proc error*(logger: Logger, message: string) = logger.log(llError, message)
proc fatal*(logger: Logger, message: string) = logger.log(llFatal, message)

proc close*(logger: Logger) =
  ## 关闭所有 sink 并清空列表。
  ##
  ## 显式释放,不依赖析构时机(§69)。可重复调用。
  for sink in logger.sinks:
    try:
      sink.close()
    except CatchableError:
      discard
  logger.sinks.setLen(0)
