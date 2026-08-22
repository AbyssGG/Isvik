## 事件 → 日志 桥接
##
## Master Prompt §29 要求 GUI Activity 使用结构化事件,**不解析日志文件**;
## §34 又要求日志输出到 Console 与 File。
##
## 这两条不冲突,前提是把关系理清:
##
## ```text
##            core/events (EventBus)
##                    │
##        ┌───────────┴───────────┐
##        ▼                       ▼
##   GUI Activity            本模块的桥接
##   (结构化消费)                  │
##                                ▼
##                        logging/logger → Console / File
## ```
##
## 事件是唯一事实来源,日志是它的一个消费者。
## 这样 Core 只需发布事件,既不依赖 logging,也不需要在两处重复写记录代码。

import std/json

import isvik/core/events
import isvik/logging/logger

proc levelFor*(kind: RuntimeEventKind): LogLevel =
  ## 运行时事件到日志级别的映射。
  ##
  ## 高频事件(编译、缓存命中、单次推理起止)归入 DEBUG,
  ## 否则一次批量推理就会把 INFO 日志刷满,淹没真正重要的信息。
  ## 生命周期里程碑事件归入 INFO。
  case kind
  of rekError: llError
  of rekRuntimeStarted, rekBackendLoaded, rekDeviceDetected, rekModelLoaded:
    llInfo
  of rekCompiling, rekCacheHit, rekCacheMiss,
     rekInferenceStarted, rekInferenceFinished:
    llDebug

proc formatEventForLog*(e: RuntimeEvent): string =
  ## 事件的日志文本形式:`KIND: message {payload}`
  ##
  ## 时间戳不在此处拼接 —— 由 logger 的格式化统一负责,避免出现两个时间戳。
  result = $e.kind
  if e.message.len > 0:
    result.add(": " & e.message)
  if e.payload != nil and e.payload.kind == JObject and e.payload.len > 0:
    result.add(" " & $e.payload)

proc bridgeEventsToLogger*(bus: EventBus, log: Logger): SubscriptionId
    {.discardable.} =
  ## 让 logger 订阅事件总线。返回订阅句柄,可用于解除桥接。
  ##
  ## 注意:事件自带 timestamp,而日志记录使用 logger 自己的时钟。
  ## 两者在正常情况下相差极小,但如果需要严格以事件时间为准,
  ## 应扩展 Logger 以接受外部时间戳,而不是在这里拼字符串伪造。
  ## 当前阶段保持简单,该差异已知且已记录。
  bus.subscribe(proc (e: RuntimeEvent) =
    log.log(levelFor(e.kind), formatEventForLog(e))
  )
