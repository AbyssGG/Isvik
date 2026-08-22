## Server-Sent Events 编码(§20.5.4)
##
## ---
##
## ## 为什么物理格式在这里而不在 Adapter
##
## `ProtocolStreamChunk` 刻意只描述「这个块叫什么、内容是什么、是否是结束
## 标记」,不含 `event:` / `data:` 前缀与空行分隔 —— 那属于**传输层**。
##
## 好处是同一个 Adapter 未来能用于 WebSocket 或其它传输方式而不必修改;
## 而 SSE 的换行规则、`[DONE]` 字面量这类细节只在这一个文件里。
##
## ---
##
## ## 换行是协议的一部分,不是排版
##
## SSE 用空行分隔事件,用 `data:` 前缀标记数据行。一条 data 里若含换行,
## **必须**拆成多个 `data:` 行,否则那个换行会被解析成「事件结束」,
## 后面的内容变成下一个事件的开头 —— 客户端收到的是两个残缺的 JSON。
##
## JSON 序列化通常不产生换行,但这不是可以依赖的假设(缩进输出就会),
## 因此这里一律按多行处理。

import std/[json, strutils]

import isvik/core/protocol

const
  SseContentType* = "text/event-stream"
  SseDoneLiteral* = "[DONE]"
    ## OpenAI 的流结束标记。它是**字面量**,不是 JSON ——
    ## 因此不能由 Adapter 放进 `data` 里,只能在传输层生成。

proc sseFrame*(eventName, data: string): string =
  ## 编码一个 SSE 事件。
  ##
  ## `eventName` 为空时省略 `event:` 行(OpenAI 不用具名事件,
  ## Anthropic 用)。
  result = ""
  if eventName.len > 0:
    result.add("event: " & eventName & "\n")
  if data.len == 0:
    # 没有数据也必须有一个 data 行,否则客户端收不到事件。
    result.add("data: \n")
  else:
    for line in data.splitLines():
      result.add("data: " & line & "\n")
  result.add("\n")

proc sseComment*(text: string): string =
  ## 注释帧。用于保持连接活跃,客户端会忽略它。
  ":" & text & "\n\n"

proc encodeChunk*(chunk: ProtocolStreamChunk,
                  doneLiteral: string = SseDoneLiteral): string =
  ## 把一个协议流块编码成 SSE 帧。
  ##
  ## 结束标记块的处理:`doneLiteral` 非空时输出该字面量(OpenAI 需要
  ## `data: [DONE]`),为空时不输出任何内容 —— Anthropic 用具名的
  ## `message_stop` 事件表示结束,再补一个 `[DONE]` 会让它的状态机
  ## 收到一个不认识的帧。
  if chunk.isDone and chunk.data == nil:
    if doneLiteral.len == 0:
      return ""
    return sseFrame(chunk.eventName, doneLiteral)
  if chunk.data == nil:
    return sseFrame(chunk.eventName, "")
  result = sseFrame(chunk.eventName, $chunk.data)

proc encodeChunks*(chunks: seq[ProtocolStreamChunk],
                   doneLiteral: string = SseDoneLiteral): string =
  result = ""
  for chunk in chunks:
    result.add(encodeChunk(chunk, doneLiteral))

proc doneLiteralFor*(protocolName: string): string =
  ## 各协议的结束标记约定。
  ##
  ## 只有 OpenAI 系用 `[DONE]`。Anthropic 与 Isvik Native 靠自己的终止事件,
  ## 因此返回空串表示「不需要额外的结束帧」。
  if protocolName.startsWith("openai"): SseDoneLiteral else: ""
