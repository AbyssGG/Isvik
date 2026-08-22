## CLI 输出:文本与 JSON 两种形态
##
## ---
##
## ## 为什么错误输出集中在这里
##
## 每个子命令自己写 `stderr.writeLine("错误:" & e.msg)` 会让三件事各自漂移:
## 前缀措辞、是否打印 detail、返回什么退出码。集中到 `reportError`,
## 这三件事就只有一处定义。
##
## ---
##
## ## detail 的边界
##
## `detail` 可能含绝对路径等本地信息(见 `core/errors.nim` 的安全边界说明)。
## 规则是:
##
## ```text
## 文本模式   打印 detail 到 stderr(本地 CLI,用户就是机主)
## JSON 模式  只输出 code 与 message,与 §22 的 API 响应形状一致
## ```
##
## JSON 模式刻意与 HTTP 错误响应保持同一形状 —— 脚本解析 CLI 输出与解析
## API 响应可以复用同一段代码。若这里多塞一个 detail 字段,两者就分叉了。

import std/[json, strutils, sequtils]

import isvik/core/errors
import isvik/cli/context
import isvik/cli/exit_codes

proc reportError*(ctx: CliContext, e: ref IsvikError): int =
  ## 输出错误并返回对应的退出码。
  ##
  ## `ctx` 允许为 nil:全局选项或语言解析阶段就失败时上下文还没建立,
  ## 那种情况下退化为不本地化的输出 —— 总比什么都不打印好。
  if ctx != nil and ctx.isJson:
    # §22 形状,不含 detail。
    echo $e.toJsonNode()
    return exitCodeFor(e)

  let prefix = if ctx != nil: ctx.t("error.prefix") else: "Error"
  stderr.writeLine(prefix & " [" & $e.code & "] " & e.msg)

  if e.detail.len > 0:
    let label = if ctx != nil: ctx.t("error.detail") else: "Detail"
    stderr.writeLine(label & ": " & e.detail)

  result = exitCodeFor(e)

proc reportUsageError*(ctx: CliContext, message: string): int =
  ## 输出用法类错误(未知命令等),返回 `ExitUsage`。
  ##
  ## 与 `reportError` 分开是因为这类问题没有 IsvikError 载体 —— 为
  ## 「用户打错了命令」专门构造一个异常并不会让代码更清楚。
  if ctx != nil and ctx.isJson:
    echo $errorJson(ecInvalidRequest, message)
  else:
    let prefix = if ctx != nil: ctx.t("error.prefix") else: "Error"
    stderr.writeLine(prefix & ": " & message)
  result = ExitUsage

# ---------------------------------------------------------------------------
# 文本排版
# ---------------------------------------------------------------------------

proc kvLine*(label: string, value: string, labelWidth: int = 18): string =
  ## `  标签        取值` 形式的一行。
  ##
  ## 按**显示宽度**对齐需要处理 CJK 全角字符,这里只做字符数填充 ——
  ## 中英文混排时列不会完美对齐,但不会错位到读不懂。这是有意的取舍:
  ## 为当前的输出量引入一张完整的东亚宽度表不值得。
  var padded = label
  while padded.len < labelWidth:
    padded.add(' ')
  result = "  " & padded & value

proc renderTable*(headers: openArray[string],
                  rows: openArray[seq[string]]): seq[string] =
  ## 渲染等宽文本表格,返回逐行文本。
  ##
  ## 列宽取该列所有单元格的最大字符数。**空表返回空序列** ——
  ## 只输出一行表头的表格没有信息量,反而让人以为「有列但没数据」。
  result = @[]
  if rows.len == 0:
    return

  let columnCount = headers.len
  var widths = newSeq[int](columnCount)
  for i, h in headers:
    widths[i] = h.len
  for row in rows:
    for i in 0 ..< min(columnCount, row.len):
      if row[i].len > widths[i]:
        widths[i] = row[i].len

  proc renderRow(cells: openArray[string]): string =
    var parts: seq[string] = @[]
    for i in 0 ..< columnCount:
      let cell = if i < cells.len: cells[i] else: ""
      if i == columnCount - 1:
        # 最后一列不填充,避免行尾拖一串空格。
        parts.add(cell)
      else:
        var padded = cell
        while padded.len < widths[i]:
          padded.add(' ')
        parts.add(padded)
    result = "  " & parts.join("  ")

  result.add(renderRow(headers))
  result.add("  " & widths.mapIt("-".repeat(it)).join("  "))
  for row in rows:
    result.add(renderRow(row))

proc emitJson*(node: JsonNode) =
  ## 输出 JSON。
  ##
  ## 用 `pretty` 而非紧凑格式:CLI 的 JSON 输出既给脚本也给人看,
  ## 紧凑格式对后者很不友好,而 JSON 解析器不在乎缩进。
  echo node.pretty(2)
