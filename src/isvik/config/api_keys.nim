## 本地 API Key 存储与校验。
##
## 服务端每次请求重新读取文件,使新增与撤销在服务运行期间立即生效,不需要
## 重启服务。
##
## ---
##
## ## 存储明文是一个**明确的**安全取舍
##
## v1 只保存 SHA-256 摘要,明文只在创建时显示一次。那样配置目录泄露也拿不到
## 可用凭据,但代价是 Key **不可取回** —— 没当场复制就只能撤销重建,而 Key
## 的用途恰恰是反复填进不同客户端。
##
## v2 起额外保存明文,使 Key 能像模型一样按编号随时调取。直接后果:
##
## ```text
## <ISVIK_HOME>/config/api_keys.json 一旦泄露,里面的 Key 立即可用。
## ```
##
## 这一点必须写在文档与 CLI 输出里,不能只留在代码注释中。选择它的理由是
## Isvik 是本地优先工具、该文件与 settings.json 同处用户自己的配置目录;
## 但「本地」不等于「安全」,所以取明文走单独的 `show` 命令,`list` 与所有
## JSON 输出默认不带明文,避免它出现在截图、日志和管道里。
##
## **拒绝**用「加密后存储」冒充更安全:密钥只能一起放在同一台机器上,
## 那是混淆而非保护,却会让人以为泄露没有后果。
##
## 摘要仍然保留,并且加载时校验 `sha256(secret) == digest` —— 手改过文件后
## 「show 出来的明文其实通不过校验」会表现为客户端 401,那种问题极难归因。

import std/[json, os, strutils, sysrand, times]

import isvik/core/errors
import isvik/util/checksum

type
  ApiKeyRecord* = object
    ## Key 的元数据。
    ##
    ## `digest` 与 `secret` 都是模块私有字段:元数据可以随意展示,凭据不能。
    ## 想拿明文必须走 `secretOf`,让「读取凭据」在调用处是一个显式动作,
    ## 而不是某个结构体字段被顺手序列化出去。
    id*: string
    name*: string
    createdAt*: string
    revokedAt*: string
    digest: string
    secret: string

  ApiKeyStore* = object
    version: int
    keys: seq[ApiKeyRecord]

const
  ApiKeyStoreVersion* = 2
    ## 写入用的版本。v1(只有摘要)仍可读取,见 `parseStore`。
  ApiKeyStoreMinVersion* = 1
  ApiKeySecretBytes = 32
  ApiKeyPrefix = "isvk_"
  ApiKeyIdPrefix = "key_"
  ApiKeyDefaultName = "local-client"
  ApiKeyMaxNameLength = 64

proc nowIso8601(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc randomHex(byteCount: int): string =
  ## 使用操作系统随机源,不使用 std/random 的可预测伪随机数。
  let bytes = urandom(byteCount)
  result = newStringOfCap(byteCount * 2)
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii)

proc newSecret(): string =
  ApiKeyPrefix & randomHex(ApiKeySecretBytes)

proc newId(): string =
  ApiKeyIdPrefix & randomHex(8)

proc constantTimeEqual(a, b: string): bool =
  ## 摘要长度固定为 64,仍按最大长度比较,避免用早退的 == 比较凭据。
  var difference = a.len xor b.len
  let count = max(a.len, b.len)
  for i in 0 ..< count:
    let left = if i < a.len: ord(a[i]) else: 0
    let right = if i < b.len: ord(b[i]) else: 0
    difference = difference or (left xor right)
  difference == 0

proc isActive*(key: ApiKeyRecord): bool =
  key.revokedAt.len == 0

proc rejectField(field, expected: string, got: JsonNodeKind) {.noreturn.} =
  raiseIsvikError(
    ecInvalidParameter,
    "Invalid API key store field type",
    "field=" & field & " expected=" & expected & " got=" & $got
  )

proc readString(node: JsonNode, key, field: string,
                fallback = ""): string =
  if node == nil or not node.hasKey(key):
    return fallback
  let value = node[key]
  if value.kind != JString:
    rejectField(field, "string", value.kind)
  value.getStr

proc readInt(node: JsonNode, key, field: string, fallback: int): int =
  if node == nil or not node.hasKey(key):
    return fallback
  let value = node[key]
  if value.kind != JInt:
    rejectField(field, "integer", value.kind)
  value.getInt

proc parseStore(node: JsonNode, path: string): ApiKeyStore =
  if node == nil or node.kind != JObject:
    raiseIsvikError(
      ecInvalidParameter,
      "API key store must contain a JSON object",
      "path=" & path
    )

  let version = readInt(node, "version", "version", ApiKeyStoreVersion)
  if version < ApiKeyStoreMinVersion or version > ApiKeyStoreVersion:
    # 低版本要能读:升级 Isvik 不应让已经发给客户端的 Key 全部失效。
    # 高版本不猜:那是降级运行,字段含义未知,继续读比报错危险。
    raiseIsvikError(
      ecInvalidParameter,
      "Unsupported API key store version",
      "path=" & path & " version=" & $version &
        " supported=" & $ApiKeyStoreMinVersion & ".." & $ApiKeyStoreVersion
    )

  if not node.hasKey("keys") or node["keys"].kind != JArray:
    raiseIsvikError(
      ecInvalidParameter,
      "API key store must contain a keys array",
      "path=" & path & " field=keys"
    )

  result = ApiKeyStore(version: version, keys: @[])
  var ids: seq[string] = @[]
  let items = node["keys"]
  for index in 0 ..< items.len:
    let item = items[index]
    let field = "keys[" & $index & "]"
    if item.kind != JObject:
      rejectField(field, "object", item.kind)
    let id = readString(item, "id", field & ".id")
    let name = readString(item, "name", field & ".name")
    let createdAt = readString(item, "created_at", field & ".created_at")
    let revokedAt = readString(item, "revoked_at", field & ".revoked_at")
    let digest = readString(item, "digest", field & ".digest")
    # v1 的记录没有 secret,这不是损坏 —— 那些 Key 仍然可用于校验,只是
    # 取不回明文。取明文的路径会如实说明这一点,而不是假装它是空字符串。
    let secret = readString(item, "secret", field & ".secret")
    if id.len == 0 or name.len == 0 or createdAt.len == 0 or digest.len != 64:
      raiseIsvikError(
        ecInvalidParameter,
        "API key store contains an incomplete record",
        "path=" & path & " field=" & field
      )
    if secret.len > 0 and sha256Hex(secret) != digest.toLowerAscii:
      # 手改过文件的直接后果:show 出来的明文通不过服务端校验,客户端只会
      # 看到 401。在这里就报错,比让人去查「Key 明明是复制的却不管用」好。
      raiseIsvikError(
        ecInvalidParameter,
        "API key secret does not match its digest",
        "path=" & path & " field=" & field & " id=" & id
      )
    if id in ids:
      raiseIsvikError(
        ecInvalidParameter,
        "API key store contains duplicate ids",
        "path=" & path & " id=" & id
      )
    ids.add(id)
    result.keys.add(ApiKeyRecord(
      id: id,
      name: name,
      createdAt: createdAt,
      revokedAt: revokedAt,
      digest: digest.toLowerAscii,
      secret: secret
    ))

proc loadApiKeyStore*(path: string): ApiKeyStore =
  ## 文件不存在代表还没有创建过 Key,不是错误。
  if not fileExists(path):
    return ApiKeyStore(version: ApiKeyStoreVersion, keys: @[])

  let raw =
    try:
      readFile(path)
    except IOError as e:
      raiseIsvikError(
        ecServerError,
        "Failed to read API key store",
        "path=" & path & " io=" & e.msg
      )

  let node =
    try:
      parseJson(raw)
    except JsonParsingError as e:
      raiseIsvikError(
        ecInvalidParameter,
        "API key store is not valid JSON",
        "path=" & path & " parse=" & e.msg
      )
  parseStore(node, path)

proc storeJson(store: ApiKeyStore): JsonNode =
  var keys = newJArray()
  for key in store.keys:
    var item = newJObject()
    item["id"] = %key.id
    item["name"] = %key.name
    item["created_at"] = %key.createdAt
    item["revoked_at"] = %key.revokedAt
    item["digest"] = %key.digest
    # 只在真的有明文时写该字段。从 v1 读来的记录保持没有 `secret`,
    # 不写一个空串冒充「有明文但是空的」。
    if key.secret.len > 0:
      item["secret"] = %key.secret
    keys.add(item)
  var node = newJObject()
  node["version"] = %ApiKeyStoreVersion
  node["keys"] = keys
  node

proc saveApiKeyStore*(path: string, store: ApiKeyStore) =
  ## 与 settings.saveSettings 相同的临时文件替换策略。
  let parent = path.parentDir
  if parent.len > 0 and not dirExists(parent):
    try:
      createDir(parent)
    except OSError as e:
      raiseIsvikError(
        ecServerError,
        "Failed to create API key directory",
        "path=" & parent & " os=" & e.msg
      )

  let tempPath = path & ".tmp"
  try:
    writeFile(tempPath, store.storeJson().pretty() & "\n")
  except IOError as e:
    raiseIsvikError(
      ecServerError,
      "Failed to write temporary API key store",
      "path=" & tempPath & " io=" & e.msg
    )

  try:
    if fileExists(path):
      removeFile(path)
    moveFile(tempPath, path)
  except OSError as e:
    raiseIsvikError(
      ecServerError,
      "Failed to replace API key store",
      "path=" & path & " temp=" & tempPath & " os=" & e.msg
    )

proc validateName(name: string): string =
  result = name.strip()
  if result.len == 0:
    result = ApiKeyDefaultName
  if result.len > ApiKeyMaxNameLength:
    raiseIsvikError(
      ecInvalidParameter,
      "API key name is too long",
      "max=" & $ApiKeyMaxNameLength
    )
  for c in result:
    if ord(c) < 32 or c in {'\r', '\n'}:
      raiseIsvikError(
        ecInvalidParameter,
        "API key name contains a control character"
      )

proc createApiKey*(path, name: string): tuple[record: ApiKeyRecord, secret: string] =
  ## 创建一个 Key。返回值中的 secret 只应在当前 CLI 调用中展示一次。
  var store = loadApiKeyStore(path)
  let keyName = validateName(name)

  var id = ""
  for attempt in 0 ..< 16:
    let candidate = newId()
    var exists = false
    for key in store.keys:
      if key.id == candidate:
        exists = true
        break
    if not exists:
      id = candidate
      break
    if attempt == 15:
      raiseIsvikError(
        ecServerError,
        "Could not allocate a unique API key id"
      )
  let secret = newSecret()
  let record = ApiKeyRecord(
    id: id,
    name: keyName,
    createdAt: nowIso8601(),
    revokedAt: "",
    digest: sha256Hex(secret),
    secret: secret
  )
  store.keys.add(record)
  saveApiKeyStore(path, store)
  (record, secret)

proc listApiKeys*(path: string): seq[ApiKeyRecord] =
  ## 列表顺序即**创建顺序**,也就是 CLI 里的 `[1] [2]` 编号。
  ##
  ## 撤销不删除记录,所以编号不会因为撤销而整体前移 —— 昨天记下的 `[2]`
  ## 今天仍然指同一个 Key。
  loadApiKeyStore(path).keys

proc hasSecret*(key: ApiKeyRecord): bool =
  ## 该记录能否取回明文。v1 时代创建的 Key 只有摘要,答案是否。
  key.secret.len > 0

proc secretOf*(key: ApiKeyRecord): string =
  ## 取明文。调用方必须自己决定要不要显示 —— 不要把它塞进通用输出路径。
  key.secret

proc parseApiKeySelector*(value: string): int =
  ## 解析 `1` 与 `[1]` 形式的列表编号;返回 0 表示「不是编号」。
  ##
  ## 与工作台选模型的 `parseModelIndex` 行为一致:Key 的调取方式刻意和模型
  ## 一样,用户不需要记两套规则。
  var raw = value.strip()
  if raw.len >= 3 and raw[0] == '[' and raw[^1] == ']':
    raw = raw[1 .. ^2].strip()
  if raw.len == 0:
    return 0
  for c in raw:
    if c notin {'0' .. '9'}:
      return 0
  try:
    result = parseInt(raw)
  except ValueError:
    return 0
  if result <= 0:
    result = 0

proc resolveApiKey*(path, selector: string): ApiKeyRecord =
  ## 按列表编号或 Key 标识解析一条记录。
  ##
  ## 编号越界与标识不存在报的是**不同的**消息:前者要告诉用户有效范围,
  ## 后者要提示去 `list` 里找标识。
  let trimmed = selector.strip()
  if trimmed.len == 0:
    raiseIsvikError(ecInvalidParameter, "API key selector must not be empty")

  let keys = loadApiKeyStore(path).keys
  let index = parseApiKeySelector(trimmed)
  if index > 0:
    if index > keys.len:
      raiseIsvikError(
        ecInvalidParameter,
        "API key index is out of range",
        "requested=" & $index & " count=" & $keys.len
      )
    return keys[index - 1]

  for key in keys:
    if key.id == trimmed:
      return key
  raiseIsvikError(
    ecInvalidParameter,
    "API key id was not found",
    "id=" & trimmed
  )

proc activeApiKeyCount*(path: string): int =
  for key in loadApiKeyStore(path).keys:
    if key.isActive:
      inc result

proc revokeApiKey*(path, selector: string): ApiKeyRecord =
  ## 撤销一条记录。`selector` 与 `resolveApiKey` 同样接受编号或标识 ——
  ## 能用 `[2]` 取出来却只能用长标识撤销,是没有道理的不一致。
  let target = resolveApiKey(path, selector)
  var store = loadApiKeyStore(path)
  for index in 0 ..< store.keys.len:
    if store.keys[index].id == target.id:
      if store.keys[index].revokedAt.len == 0:
        store.keys[index].revokedAt = nowIso8601()
        saveApiKeyStore(path, store)
      return store.keys[index]
  raiseIsvikError(
    ecInvalidParameter,
    "API key id was not found",
    "id=" & target.id
  )

proc verifyApiKey*(path, presented: string): bool =
  ## 文件损坏/读取失败向上抛错,不能静默把服务变成「所有请求 401」。
  let candidate = presented.strip()
  if candidate.len == 0:
    return false
  let digest = sha256Hex(candidate)
  for key in loadApiKeyStore(path).keys:
    if key.isActive and constantTimeEqual(key.digest, digest):
      return true
  false

proc publicApiKeyJson*(key: ApiKeyRecord): JsonNode =
  ## 对外只返回元数据,绝不返回 digest。
  var node = %*{
    "id": key.id,
    "name": key.name,
    "createdAt": key.createdAt,
    "active": key.isActive
  }
  if key.revokedAt.len > 0:
    node["revokedAt"] = %key.revokedAt
  else:
    node["revokedAt"] = newJNull()
  node
