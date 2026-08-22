## 协议层共用的严格 JSON 读取辅助
##
## ---
##
## ## 为什么独立成模块
##
## 每个 Protocol Adapter 都要把外部 JSON 读成统一请求,而「怎么处理字段
## 缺失与类型错误」是一条必须**处处一致**的规则:
##
## ```text
## 字段缺失        用默认值。向前兼容靠这个。
## 字段存在但类型错  报 INVALID_PARAMETER,并指明字段名与期望类型。
## ```
##
## 静默忽略类型错误等于篡改调用方的意图 —— 客户端写了 `"temperature": "0.7"`
## (字符串),得到的却是默认贪心,而它以为自己设置成功了。
##
## 这套规则原本只存在于 `native.nim` 内部。新增 OpenAI / Anthropic Adapter 时
## 若各抄一份,三份会慢慢分叉:某一个协议开始容忍字符串数字,另外两个不容忍,
## 而差异只在特定字段上暴露。

import std/[json, options, strutils]

import isvik/core/errors

proc jsonKindName*(kind: JsonNodeKind): string =
  case kind
  of JString: "string"
  of JInt: "integer"
  of JFloat: "float"
  of JBool: "boolean"
  of JObject: "object"
  of JArray: "array"
  of JNull: "null"

proc rejectType*(field, expected: string, got: JsonNodeKind) {.noreturn.} =
  ## 字段类型错误一律报 INVALID_PARAMETER,并指明字段名与期望类型。
  raiseIsvikError(
    ecInvalidParameter,
    "Invalid field type in request",
    "field=" & field & " expected=" & expected & " got=" & jsonKindName(got)
  )

proc requireObject*(body: JsonNode, what: string) =
  ## 请求体本身必须是对象。
  ##
  ## 这属于**形状**错误而不是字段错误,因此报 INVALID_REQUEST ——
  ## 两者对客户端的含义不同:一个是「整个请求发错了」,
  ## 另一个是「某个字段填错了」。
  if body == nil:
    raiseIsvikError(
      ecInvalidRequest,
      "Request body must not be empty",
      "expected=" & what
    )
  if body.kind != JObject:
    raiseIsvikError(
      ecInvalidRequest,
      "Request body must be a JSON object",
      "expected=" & what & " got=" & jsonKindName(body.kind)
    )

proc readStr*(node: JsonNode, key, field, fallback: string): string =
  if node == nil or not node.hasKey(key):
    return fallback
  let v = node[key]
  if v.kind != JString:
    rejectType(field, "string", v.kind)
  v.getStr

proc readRequiredStr*(node: JsonNode, key, field: string): string =
  ## 必填字符串。缺失与空串都报错 —— 「有这个键但值是空字符串」
  ## 与「没这个键」对调用方是同一个问题:没提供。
  let value = readStr(node, key, field, "")
  if value.strip().len == 0:
    raiseIsvikError(
      ecInvalidRequest,
      "Required field is missing or empty",
      "field=" & field
    )
  value

proc readBoolField*(node: JsonNode, key, field: string, fallback: bool): bool =
  if node == nil or not node.hasKey(key):
    return fallback
  let v = node[key]
  if v.kind != JBool:
    rejectType(field, "boolean", v.kind)
  v.getBool

proc readOptInt*(node: JsonNode, key, field: string): Option[int] =
  if node == nil or not node.hasKey(key) or node[key].kind == JNull:
    return none(int)
  let v = node[key]
  if v.kind != JInt:
    rejectType(field, "integer", v.kind)
  some(v.getInt)

proc readOptFloat*(node: JsonNode, key, field: string): Option[float] =
  if node == nil or not node.hasKey(key) or node[key].kind == JNull:
    return none(float)
  let v = node[key]
  # 整数字面量对浮点参数是合法输入(temperature: 1 等价于 1.0)。
  if v.kind notin {JFloat, JInt}:
    rejectType(field, "number", v.kind)
  some(v.getFloat)

proc readObj*(node: JsonNode, key, field: string): JsonNode =
  if node == nil or not node.hasKey(key) or node[key].kind == JNull:
    return nil
  let v = node[key]
  if v.kind != JObject:
    rejectType(field, "object", v.kind)
  v

proc readArr*(node: JsonNode, key, field: string): JsonNode =
  if node == nil or not node.hasKey(key) or node[key].kind == JNull:
    return nil
  let v = node[key]
  if v.kind != JArray:
    rejectType(field, "array", v.kind)
  v

proc readStrSeq*(node: JsonNode, key, field: string): seq[string] =
  ## 读字符串数组。同时接受**单个字符串** —— OpenAI 与 Anthropic 的
  ## `stop` / `stop_sequences` 都允许这两种写法。
  result = @[]
  if node == nil or not node.hasKey(key) or node[key].kind == JNull:
    return
  let v = node[key]
  if v.kind == JString:
    result.add(v.getStr)
    return
  if v.kind != JArray:
    rejectType(field, "array or string", v.kind)
  for i in 0 ..< v.len:
    # 遍历 JArray 必须用索引:`for x in node` 会走到只支持 JObject 的
    # pairs(),在运行时断言失败。
    let item = v[i]
    if item.kind != JString:
      rejectType(field & "[" & $i & "]", "string", item.kind)
    result.add(item.getStr)
