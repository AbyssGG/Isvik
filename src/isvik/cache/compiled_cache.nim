## Compiled Cache(Master Prompt §17 / §55)
##
## ---
##
## ## 为什么这是可用性项,不是优化项
##
## NimVoice 的实测(DEVLOG 6.2 第 8 条):HiFi-GAN 在 NPU 上首次编译约
## **13.5 秒**,blob 缓存命中后约 **850 ms**。NPU 驱动侧没有内建缓存,
## 每次冷启都要重编。13.5 秒的启动等待对交互式使用是不可接受的。
##
## (那个倍数是 NimVoice 的模型,**不是 Isvik 的性能数据**。Isvik 自己的
## 数字要到 Benchmark 阶段实测。)
##
## ---
##
## ## 缓存键必须包含什么 —— 少一项就是一个静默错误
##
## ```text
## 模型文件身份    大小 + 修改时间(有校验和时用校验和)
## 设备 rawName    GPU.0 与 GPU.1 的 blob 不通用
## Backend 版本    OpenVINO 版本变了 blob 格式可能不兼容
## 编译属性        PERFORMANCE_HINT 等会改变编译产物
## 键算法版本      改了键的构成方式就必须让旧缓存全部失效
## ```
##
## 设备用 **rawName** 而不是语义名是关键:本机 `GPU.0` 是 Intel iGPU、
## `GPU.1` 是 NVIDIA 独显,两者的编译产物完全不能互换。如果键里只写 `GPU`,
## 换一张卡就会加载到一份为另一张卡编译的 blob —— 而失败方式是不可预测的。
##
## 反过来说,任何一项变化都会产生不同的键,于是**自动失效**。这比维护一张
## 「什么情况下要清缓存」的规则表可靠得多。
##
## ---
##
## ## 与 Benchmark 的功能互斥(DEVLOG 6.1 第 1 条)
##
## `.blob` 序列化产物**不含运行期 property**,而本机 NPU 驱动对 import
## 之后的模型执行 `set_property("PERF_COUNT","YES")` 直接返回
## `GENERAL_ERROR`。这是驱动行为,不是 bug。
##
## 后果是:**缓存命中与 per-layer profiling 在 NPU 上不能同时成立。**
## 因此本模块提供:
##
## - `bypassCache`:Benchmark 需要 profiling 时显式绕过缓存重新编译
## - `CacheOutcome.profilingUnavailableReason`:命中且请求了 profiling 时,
##   如实说明「本次没有 profiling 数据,原因是走了缓存」
##
## 绝不能静默返回空数据却声称采集成功 —— 那就是伪造 Benchmark(§35)。
##
## ---
##
## ## 完整性校验
##
## blob 落盘时记录 SHA-256,加载前比对。损坏的条目按 miss 处理并删除,
## 而不是把坏 blob 交给 OpenVINO —— 后者的失败信息晦涩得多。
##
## 校验一份 blob 的成本远小于编译一次模型,因此这里**默认开启**校验
## (与模型文件校验的取舍相反,那边动辄 4 GB)。

import std/[os, json, times, tables, algorithm, strutils]

import isvik/core/errors
import isvik/config/paths
import isvik/config/settings
import isvik/util/checksum

type
  CacheKeyInputs* = object
    ## 构成缓存键的全部输入。
    ##
    ## 全部字段都会进入键;新增字段等于让旧缓存失效,这是有意的。
    modelId*: string
    entrypointPath*: string
      ## 主模型文件的路径(相对或绝对,只作身份的一部分)。
    fileBytes*: int64
    fileMtime*: int64
      ## Unix 秒。校验和为空时用它识别「文件变了」。
    fileChecksum*: string
      ## SHA-256。有值时优先于 mtime —— mtime 会被复制/解压重置,
      ## 而内容没变;反过来内容变了 mtime 也可能被保留。
    deviceRawName*: string
      ## **必须是 Backend rawName**(如 GPU.0),不是语义名。
    backendName*: string
    backendVersion*: string
    properties*: Table[string, string]

  CacheEntryMeta* = object
    ## 缓存条目的元数据(与 blob 同名的 .json)。
    schemaVersion*: int
    key*: string
    inputs*: CacheKeyInputs
    blobBytes*: int64
    blobChecksum*: string
    createdAt*: string
    keyAlgorithm*: string
      ## 键算法标识。记录下来使人能看出一个条目是用哪套规则生成的。

  CacheStatus* = enum
    ## 一次缓存查询的结果。
    csHit = "hit"
      ## 命中且完整性校验通过。
    csMiss = "miss"
      ## 没有对应条目。
    csCorrupted = "corrupted"
      ## 有条目但校验失败。已被删除,按 miss 对待。
    csBypassed = "bypassed"
      ## 调用方要求绕过缓存(通常是 Benchmark 需要 profiling)。
    csDisabled = "disabled"
      ## 缓存被配置关闭。

  CacheOutcome* = object
    ## 查询结果。
    status*: CacheStatus
    key*: string
    blobPath*: string
      ## 命中时可直接 import 的 blob 路径;否则为空。
    meta*: CacheEntryMeta
    reason*: string
      ## 为什么是这个结果。miss / corrupted 时尤其有用。
    profilingUnavailableReason*: string
      ## 命中且调用方请求了 profiling 时,说明为何拿不到 profiling 数据。
      ##
      ## 空字符串表示「没有这个问题」。**非空时调用方必须如实上报**,
      ## 不得声称采集成功(见模块顶部与 §35)。

  CacheMetrics* = object
    ## 进程内累计指标(§55 要求 Metrics)。
    ##
    ## 刻意**不持久化**:跨进程累计的命中率会把「上次运行」的情况混进来,
    ## 而调用方关心的通常是本次运行的行为。需要长期统计时由上层落盘。
    hits*: int
    misses*: int
    corrupted*: int
    bypassed*: int
    writes*: int
    evictions*: int
    bytesWritten*: int64
    bytesServed*: int64

  CompiledCache* = ref object
    ## 已编译模型的 blob 缓存。
    directory: string
    enabled: bool
    verifyOnRead: bool
    metrics: CacheMetrics

const
  CacheSchemaVersion* = 1
  CacheKeyAlgorithm* = "isvik-compiled-cache-v1"
    ## 键算法标识。**改动键的构成方式时必须同时改这个字符串** ——
    ## 它进入键的计算,因此旧条目会自动变成 miss 而不是被错误命中。

  BlobExtension* = ".blob"
  MetaExtension* = ".json"

  CompiledSubdirectory* = "compiled"
    ## 位于缓存根之下,与将来可能的其它缓存种类分开。

# ---------------------------------------------------------------------------
# 构造
# ---------------------------------------------------------------------------

proc newCompiledCache*(paths: IsvikPaths, s: Settings,
                       enabled: bool = true): CompiledCache =
  ## 依据配置构造缓存。
  ##
  ## `settings.cache_directory` 非空时优先(允许把缓存放到大容量磁盘)。
  new(result)
  let override = s.cacheDirectory.strip()
  let base =
    if override.len > 0: normalizedPath(absolutePath(expandTilde(override)))
    else: paths.cache
  result.directory = base / CompiledSubdirectory
  result.enabled = enabled
  result.verifyOnRead = true
  result.metrics = CacheMetrics()

proc newCompiledCache*(directory: string, enabled: bool = true): CompiledCache =
  ## 直接指定目录。主要供测试使用。
  new(result)
  result.directory = normalizedPath(absolutePath(directory))
  result.enabled = enabled
  result.verifyOnRead = true
  result.metrics = CacheMetrics()

proc directory*(c: CompiledCache): string = c.directory
proc isEnabled*(c: CompiledCache): bool = c.enabled
proc metrics*(c: CompiledCache): CacheMetrics = c.metrics

proc setEnabled*(c: CompiledCache, enabled: bool) =
  c.enabled = enabled

proc setVerifyOnRead*(c: CompiledCache, verify: bool) =
  ## 关闭读取校验。
  ##
  ## 提供这个开关是为了让「校验开销是否值得」可被实测,但**默认开启**:
  ## 把坏 blob 交给 OpenVINO 得到的错误信息比「缓存损坏」晦涩得多。
  c.verifyOnRead = verify

proc resetMetrics*(c: CompiledCache) =
  c.metrics = CacheMetrics()

proc hitRate*(m: CacheMetrics): float =
  ## 命中率。
  ##
  ## 分母只算 hit + miss + corrupted:`bypassed` 是调用方主动跳过,
  ## 把它算进未命中会让「Benchmark 跑了几轮」污染缓存有效性的判断。
  let total = m.hits + m.misses + m.corrupted
  if total == 0: 0.0 else: m.hits / total

# ---------------------------------------------------------------------------
# 键
# ---------------------------------------------------------------------------

proc initCacheKeyInputs*(modelId, entrypointPath, deviceRawName,
                         backendName, backendVersion: string): CacheKeyInputs =
  CacheKeyInputs(
    modelId: modelId,
    entrypointPath: entrypointPath,
    fileBytes: 0,
    fileMtime: 0,
    fileChecksum: "",
    deviceRawName: deviceRawName,
    backendName: backendName,
    backendVersion: backendVersion,
    properties: initTable[string, string]()
  )

proc withFileIdentity*(inputs: CacheKeyInputs, path: string): CacheKeyInputs =
  ## 从磁盘读取文件身份(大小 + 修改时间)填入键输入。
  ##
  ## 不自动计算校验和:主模型文件可达 1.3 GB,每次查缓存都算一遍会让缓存
  ## 本身成为瓶颈。需要更强的身份判定时由调用方显式设 `fileChecksum`。
  result = inputs
  if not fileExists(path):
    raiseIsvikError(
      ecModelNotFound,
      "Cannot compute cache key for a file that does not exist",
      "path=" & path
    )
  result.fileBytes = getFileSize(path)
  result.fileMtime = getLastModificationTime(path).toUnix

proc canonicalForm*(inputs: CacheKeyInputs): string =
  ## 键输入的规范文本形式。
  ##
  ## 属性**按键排序**:Table 的迭代顺序不保证稳定,不排序会让同一组属性
  ## 在两次运行中算出不同的键,缓存永远不命中而且看不出原因。
  var lines: seq[string] = @[
    CacheKeyAlgorithm,
    "model=" & inputs.modelId,
    "entry=" & inputs.entrypointPath.extractFilename,
    "bytes=" & $inputs.fileBytes,
    # 有校验和时不把 mtime 计入:复制或解压会重置 mtime 而内容未变,
    # 那种情况下不该让缓存失效。
    (if inputs.fileChecksum.len > 0: "sha256=" & inputs.fileChecksum
     else: "mtime=" & $inputs.fileMtime),
    "device=" & inputs.deviceRawName,
    "backend=" & inputs.backendName,
    "backendVersion=" & inputs.backendVersion
  ]

  var propKeys: seq[string] = @[]
  for k in inputs.properties.keys:
    propKeys.add(k)
  sort(propKeys)
  for k in propKeys:
    lines.add("prop:" & k & "=" & inputs.properties[k])

  result = lines.join("\n")

proc cacheKey*(inputs: CacheKeyInputs): string =
  ## 缓存键:规范形式的 SHA-256(64 个十六进制字符)。
  ##
  ## 用哈希而不是把输入拼成文件名:设备名与属性值可能含路径分隔符或
  ## 非法字符,而 64 个十六进制字符在任何文件系统上都安全。
  sha256Hex(inputs.canonicalForm())

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------

proc blobPathFor*(c: CompiledCache, key: string): string =
  c.directory / (key & BlobExtension)

proc metaPathFor*(c: CompiledCache, key: string): string =
  c.directory / (key & MetaExtension)

proc ensureDirectory*(c: CompiledCache) =
  if dirExists(c.directory):
    return
  try:
    createDir(c.directory)
  except OSError as e:
    raiseIsvikError(
      ecServerError,
      "Failed to create compiled cache directory",
      "path=" & c.directory & " os=" & e.msg
    )

# ---------------------------------------------------------------------------
# 元数据序列化
# ---------------------------------------------------------------------------

proc toJsonNode*(inputs: CacheKeyInputs): JsonNode =
  var props = newJObject()
  var keys: seq[string] = @[]
  for k in inputs.properties.keys:
    keys.add(k)
  sort(keys)
  for k in keys:
    props[k] = %inputs.properties[k]

  %*{
    "model_id": inputs.modelId,
    "entrypoint_path": inputs.entrypointPath,
    "file_bytes": inputs.fileBytes,
    "file_mtime": inputs.fileMtime,
    "file_sha256": inputs.fileChecksum,
    "device_raw_name": inputs.deviceRawName,
    "backend_name": inputs.backendName,
    "backend_version": inputs.backendVersion,
    "properties": props
  }

proc toJsonNode*(m: CacheEntryMeta): JsonNode =
  %*{
    "schema_version": m.schemaVersion,
    "key": m.key,
    "key_algorithm": m.keyAlgorithm,
    "inputs": m.inputs.toJsonNode(),
    "blob_bytes": m.blobBytes,
    "blob_sha256": m.blobChecksum,
    "created_at": m.createdAt
  }

proc keyInputsFromJson(node: JsonNode): CacheKeyInputs =
  result = initCacheKeyInputs("", "", "", "", "")
  if node == nil or node.kind != JObject:
    return
  proc str(k: string): string =
    if node.hasKey(k) and node[k].kind == JString: node[k].getStr else: ""
  proc num(k: string): int64 =
    if node.hasKey(k) and node[k].kind == JInt: node[k].getBiggestInt else: 0

  result.modelId = str("model_id")
  result.entrypointPath = str("entrypoint_path")
  result.fileBytes = num("file_bytes")
  result.fileMtime = num("file_mtime")
  result.fileChecksum = str("file_sha256")
  result.deviceRawName = str("device_raw_name")
  result.backendName = str("backend_name")
  result.backendVersion = str("backend_version")
  if node.hasKey("properties") and node["properties"].kind == JObject:
    for k, v in node["properties"]:
      if v.kind == JString:
        result.properties[k] = v.getStr

proc metaFromJson*(node: JsonNode): CacheEntryMeta =
  ## 从 JSON 构造元数据。
  ##
  ## 容错读取:缓存元数据损坏不应抛异常,而应让条目被判为不可用 ——
  ## 缓存本来就是可以丢弃的东西,为它中断整个操作不值得。
  result = CacheEntryMeta(
    schemaVersion: 0,
    key: "",
    inputs: initCacheKeyInputs("", "", "", "", ""),
    blobBytes: 0,
    blobChecksum: "",
    createdAt: "",
    keyAlgorithm: ""
  )
  if node == nil or node.kind != JObject:
    return
  if node.hasKey("schema_version") and node["schema_version"].kind == JInt:
    result.schemaVersion = node["schema_version"].getInt
  if node.hasKey("key") and node["key"].kind == JString:
    result.key = node["key"].getStr
  if node.hasKey("key_algorithm") and node["key_algorithm"].kind == JString:
    result.keyAlgorithm = node["key_algorithm"].getStr
  if node.hasKey("blob_bytes") and node["blob_bytes"].kind == JInt:
    result.blobBytes = node["blob_bytes"].getBiggestInt
  if node.hasKey("blob_sha256") and node["blob_sha256"].kind == JString:
    result.blobChecksum = node["blob_sha256"].getStr
  if node.hasKey("created_at") and node["created_at"].kind == JString:
    result.createdAt = node["created_at"].getStr
  if node.hasKey("inputs"):
    result.inputs = keyInputsFromJson(node["inputs"])

proc readMeta(c: CompiledCache, key: string): CacheEntryMeta =
  let path = c.metaPathFor(key)
  if not fileExists(path):
    return metaFromJson(nil)
  try:
    result = metaFromJson(parseJson(readFile(path)))
  except CatchableError:
    # 元数据读不出来就当条目不可用。
    result = metaFromJson(nil)

# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

proc dropEntry*(c: CompiledCache, key: string) =
  ## 删除一个条目(blob + 元数据)。缺失时静默,便于清理半成品。
  for path in [c.blobPathFor(key), c.metaPathFor(key)]:
    if fileExists(path):
      try: removeFile(path)
      except CatchableError: discard

proc lookup*(c: CompiledCache, inputs: CacheKeyInputs,
             bypass: bool = false,
             profilingRequested: bool = false): CacheOutcome =
  ## 查询缓存。
  ##
  ## `bypass` 为 true 时直接返回 `csBypassed`,不读磁盘 —— Benchmark 需要
  ## 现场编译才能拿到 per-layer 数据。
  let key = cacheKey(inputs)
  result = CacheOutcome(
    status: csMiss,
    key: key,
    blobPath: "",
    meta: metaFromJson(nil),
    reason: "",
    profilingUnavailableReason: ""
  )

  if not c.enabled:
    result.status = csDisabled
    result.reason = "compiled cache is disabled"
    return

  if bypass:
    inc c.metrics.bypassed
    result.status = csBypassed
    result.reason = "caller requested a cache bypass"
    return

  let blob = c.blobPathFor(key)
  if not fileExists(blob):
    inc c.metrics.misses
    result.reason = "no cache entry for this key"
    return

  let meta = c.readMeta(key)
  result.meta = meta

  # 元数据缺失或键算法不符:条目来路不明,不冒险使用。
  if meta.key != key or meta.keyAlgorithm != CacheKeyAlgorithm or
     meta.schemaVersion != CacheSchemaVersion:
    inc c.metrics.corrupted
    c.dropEntry(key)
    result.status = csCorrupted
    result.reason = "cache metadata is missing or does not match the current" &
      " key algorithm; entry was dropped"
    return

  let actualBytes = getFileSize(blob)
  if meta.blobBytes > 0 and actualBytes != meta.blobBytes:
    inc c.metrics.corrupted
    c.dropEntry(key)
    result.status = csCorrupted
    result.reason = "cached blob size mismatch: expected " & $meta.blobBytes &
      ", found " & $actualBytes & "; entry was dropped"
    return

  if c.verifyOnRead and meta.blobChecksum.len > 0:
    var actual = ""
    try:
      actual = sha256FileHex(blob)
    except IOError as e:
      inc c.metrics.corrupted
      c.dropEntry(key)
      result.status = csCorrupted
      result.reason = "cached blob could not be read: " & e.msg
      return
    if actual != meta.blobChecksum.toLowerAscii:
      inc c.metrics.corrupted
      c.dropEntry(key)
      result.status = csCorrupted
      result.reason = "cached blob checksum mismatch; entry was dropped"
      return

  inc c.metrics.hits
  c.metrics.bytesServed += actualBytes
  result.status = csHit
  result.blobPath = blob
  result.reason = "cache hit"

  # 命中且请求了 profiling:必须说清楚拿不到 profiling 数据。
  # blob 不含运行期属性,而本机 NPU 驱动会拒绝 import 后设置 PERF_COUNT
  # (DEVLOG 6.1 第 1 条)。静默返回空数据就是伪造 Benchmark。
  if profilingRequested:
    result.profilingUnavailableReason =
      "loaded from compiled cache; a serialized blob carries no runtime " &
      "properties, so per-layer profiling is unavailable. Re-compile with " &
      "the cache bypassed to collect it."

proc isUsable*(o: CacheOutcome): bool =
  ## 是否可以直接使用缓存中的 blob。
  o.status == csHit and o.blobPath.len > 0

# ---------------------------------------------------------------------------
# 写入
# ---------------------------------------------------------------------------

proc reserve*(c: CompiledCache, inputs: CacheKeyInputs): string =
  ## 为一次写入准备目标 blob 路径。
  ##
  ## 调用方(Backend 的 `exportCompiledModel`)需要一个路径来落盘,
  ## 而元数据只有在导出成功之后才能算 —— 因此写入分成 reserve / commit 两步。
  c.ensureDirectory()
  result = c.blobPathFor(cacheKey(inputs))

proc commit*(c: CompiledCache, inputs: CacheKeyInputs): CacheEntryMeta =
  ## 在 blob 已落盘之后写入元数据,使该条目正式可用。
  ##
  ## **必须在 blob 写完之后调用。** 元数据的存在即「这个条目完整」的标志:
  ## 若先写元数据再写 blob,中途崩溃会留下一个看起来有效、实际不完整的条目。
  let key = cacheKey(inputs)
  let blob = c.blobPathFor(key)

  if not fileExists(blob):
    raiseIsvikError(
      ecServerError,
      "Cannot commit a cache entry whose blob does not exist",
      "key=" & key & " expected=" & blob
    )

  let size = getFileSize(blob)
  if size <= 0:
    # 空 blob 不可能是有效的编译产物。留着它只会在下次命中时才失败。
    c.dropEntry(key)
    raiseIsvikError(
      ecServerError,
      "Refused to commit an empty compiled cache blob",
      "key=" & key & " path=" & blob
    )

  result = CacheEntryMeta(
    schemaVersion: CacheSchemaVersion,
    key: key,
    inputs: inputs,
    blobBytes: size,
    blobChecksum: sha256FileHex(blob),
    createdAt: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    keyAlgorithm: CacheKeyAlgorithm
  )

  let metaPath = c.metaPathFor(key)
  let tmp = metaPath & ".tmp"
  try:
    writeFile(tmp, result.toJsonNode().pretty(2) & "\n")
    if fileExists(metaPath):
      removeFile(metaPath)
    moveFile(tmp, metaPath)
  except CatchableError as e:
    if fileExists(tmp):
      try: removeFile(tmp)
      except CatchableError: discard
    # 元数据写不成就把 blob 也删掉:一个没有元数据的 blob 永远不会被命中,
    # 留着只是占磁盘。
    c.dropEntry(key)
    raiseIsvikError(
      ecServerError,
      "Failed to write compiled cache metadata",
      "path=" & metaPath & " reason=" & e.msg
    )

  inc c.metrics.writes
  c.metrics.bytesWritten += size

# ---------------------------------------------------------------------------
# 维护
# ---------------------------------------------------------------------------

proc listKeys*(c: CompiledCache): seq[string] =
  ## 列出全部**完整**条目的键(blob 与元数据都在)。
  result = @[]
  if not dirExists(c.directory):
    return
  for kind, path in walkDir(c.directory):
    if kind != pcFile:
      continue
    let name = path.extractFilename
    if not name.endsWith(BlobExtension):
      continue
    let key = name[0 ..< name.len - BlobExtension.len]
    if fileExists(c.metaPathFor(key)):
      result.add(key)
  sort(result)

proc entries*(c: CompiledCache): seq[CacheEntryMeta] =
  ## 全部条目的元数据。
  result = @[]
  for key in c.listKeys():
    let meta = c.readMeta(key)
    if meta.key == key:
      result.add(meta)

proc totalBytes*(c: CompiledCache): int64 =
  ## 缓存占用的总字节数(仅 blob)。
  for key in c.listKeys():
    let blob = c.blobPathFor(key)
    if fileExists(blob):
      result += getFileSize(blob)

proc invalidateModel*(c: CompiledCache, modelId: string): int =
  ## 删除某个模型的全部缓存条目。返回删除数量。
  ##
  ## 用途:模型被重新导入或删除后,它的旧 blob 已无意义。虽然键里含文件
  ## 身份、内容变了自然会 miss,但**主动清理**能立刻回收磁盘 ——
  ## 一份 4 GB 模型在三个设备上的 blob 加起来不是小数目。
  for key in c.listKeys():
    let meta = c.readMeta(key)
    if meta.inputs.modelId == modelId:
      c.dropEntry(key)
      inc result
      inc c.metrics.evictions

proc invalidateDevice*(c: CompiledCache, deviceRawName: string): int =
  ## 删除某个设备的全部缓存条目。返回删除数量。
  for key in c.listKeys():
    let meta = c.readMeta(key)
    if meta.inputs.deviceRawName == deviceRawName:
      c.dropEntry(key)
      inc result
      inc c.metrics.evictions

proc invalidateStaleBackend*(c: CompiledCache, backendName,
                            backendVersion: string): int =
  ## 删除**不是**由当前 Backend 版本产生的条目。返回删除数量。
  ##
  ## 升级 OpenVINO 之后调用:旧版本的 blob 不会被命中(键里含版本),
  ## 但会一直占着磁盘。
  for key in c.listKeys():
    let meta = c.readMeta(key)
    if meta.inputs.backendName != backendName or
       meta.inputs.backendVersion != backendVersion:
      c.dropEntry(key)
      inc result
      inc c.metrics.evictions

proc verifyAll*(c: CompiledCache): seq[tuple[key: string, problem: string]] =
  ## 校验全部条目的完整性,返回有问题的条目。**不删除**任何东西 ——
  ## 这是诊断用的,决定要不要删由调用方(或 `purgeCorrupted`)做。
  result = @[]
  for key in c.listKeys():
    let meta = c.readMeta(key)
    let blob = c.blobPathFor(key)

    if meta.key != key:
      result.add((key: key, problem: "metadata key mismatch"))
      continue
    if meta.keyAlgorithm != CacheKeyAlgorithm:
      result.add((key: key,
                  problem: "produced by a different key algorithm: " &
                    meta.keyAlgorithm))
      continue
    if not fileExists(blob):
      result.add((key: key, problem: "blob is missing"))
      continue

    let size = getFileSize(blob)
    if meta.blobBytes > 0 and size != meta.blobBytes:
      result.add((key: key, problem: "blob size mismatch: expected " &
        $meta.blobBytes & ", found " & $size))
      continue

    if meta.blobChecksum.len > 0:
      var actual = ""
      try:
        actual = sha256FileHex(blob)
      except IOError as e:
        result.add((key: key, problem: "blob unreadable: " & e.msg))
        continue
      if actual != meta.blobChecksum.toLowerAscii:
        result.add((key: key, problem: "blob checksum mismatch"))

proc purgeCorrupted*(c: CompiledCache): int =
  ## 删除全部损坏条目。返回删除数量。
  for issue in c.verifyAll():
    c.dropEntry(issue.key)
    inc result
    inc c.metrics.evictions

proc purgeOrphans*(c: CompiledCache): int =
  ## 删除孤立文件:有 blob 没元数据,或有元数据没 blob。
  ##
  ## 这类残留来自写入过程中的崩溃。它们不会被命中,但会占磁盘。
  result = 0
  if not dirExists(c.directory):
    return
  var blobKeys: seq[string] = @[]
  var metaKeys: seq[string] = @[]
  for kind, path in walkDir(c.directory):
    if kind != pcFile:
      continue
    let name = path.extractFilename
    if name.endsWith(BlobExtension):
      blobKeys.add(name[0 ..< name.len - BlobExtension.len])
    elif name.endsWith(MetaExtension):
      metaKeys.add(name[0 ..< name.len - MetaExtension.len])

  for key in blobKeys:
    if key notin metaKeys:
      c.dropEntry(key)
      inc result
  for key in metaKeys:
    if key notin blobKeys:
      c.dropEntry(key)
      inc result

proc clear*(c: CompiledCache): int =
  ## 清空缓存。返回删除的条目数。
  for key in c.listKeys():
    c.dropEntry(key)
    inc result
    inc c.metrics.evictions
  discard c.purgeOrphans()
