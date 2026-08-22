## Task 3 Demo:结构化事件同时驱动 GUI 消费者与 Console / File 日志
##
## 运行:
## ```powershell
## nimble demo_events
## ```
##
## 这个 demo 演示 Master Prompt §29 与 §34 如何共存:
## 事件总线是唯一事实来源,GUI 与日志是它的两个独立消费者。
## GUI 侧拿到的是结构化 JSON,不需要去解析日志文本。

import std/[json, os, strutils]

import isvik/core/events
import isvik/logging/logger
import isvik/logging/event_log
import isvik/cli/console

proc main() =
  enableUtf8Console()

  let logPath = "build" / "demo" / "isvik-demo.log"
  removeFile(logPath)  # 让每次 demo 的输出清晰可读

  # --- 组装:一条事件总线,两个消费者 ---
  let bus = newEventBus()

  # 消费者 1:日志(Console + File)
  let log = newLogger(llDebug)
  log.addSink(newConsoleSink())        # 写 stderr,不污染 stdout
  log.addSink(newFileSink(logPath))
  bridgeEventsToLogger(bus, log)

  # 消费者 2:模拟 GUI Activity 页,收集结构化事件
  var activityFeed: seq[JsonNode] = @[]
  bus.subscribe(proc (e: RuntimeEvent) =
    activityFeed.add(e.toJsonNode())
  )

  # --- 发布一串典型的运行时事件 ---
  bus.publish(rekRuntimeStarted, "Isvik 运行时已启动",
              %*{"version": "0.1.0"})
  bus.publish(rekBackendLoaded, "Backend 已加载",
              %*{"backend": "mock", "note": "OpenVINO Backend 尚未实现"})
  bus.publish(rekDeviceDetected, "检测到设备",
              %*{"device": "CPU", "available": true})
  bus.publish(rekDeviceDetected, "检测到设备",
              %*{"device": "NPU", "available": false,
                 "reason": "NOT AVAILABLE IN CURRENT ENVIRONMENT"})
  bus.publish(rekCacheMiss, "编译缓存未命中",
              %*{"key": "demo-model@CPU"})
  bus.publish(rekError, "示例错误事件",
              %*{"code": "NPU_NOT_AVAILABLE"})

  log.close()

  # --- 展示两个消费者各自得到了什么 ---
  echo ""
  echo "=== GUI Activity 消费者收到的结构化事件(", activityFeed.len, " 条)==="
  for node in activityFeed:
    echo "  ", $node

  echo ""
  echo "=== 落盘日志:", logPath, " ==="
  if fileExists(logPath):
    for line in readFile(logPath).splitLines:
      if line.len > 0:
        echo "  ", line

  echo ""
  echo "事件发布总数:", bus.publishedCount
  echo "订阅者数量:", bus.subscriberCount
  echo "订阅者异常数:", bus.handlerErrorCount
  echo ""
  echo "注意:上面 stderr 里的日志行与文件内容一致,而 GUI 消费者拿到的是"
  echo "结构化 JSON —— GUI 不需要解析日志文本(§29)。"

when isMainModule:
  main()
