## Compiled Cache 测试
##
## 用临时目录里的假 blob,不依赖 OpenVINO —— 缓存的正确性与后端无关。
## 真实 blob 的导出 / 导入由 `tests/backends/tovbackend.nim` 覆盖。
##
## 重点验证三件事:
##
## 1. **键的构成完整**:任何一项输入变化都必须导致不同的键。少一项就是
##    一个静默错误(比如换了显卡却加载到为另一张卡编译的 blob)。
## 2. **损坏被识别并丢弃**,不把坏 blob 交给后端。
## 3. **命中且请求 profiling 时必须给出原因**,不静默返回空数据(§35)。

import std/[unittest, os, json, strutils, tables]

import isvik/core/errors
import isvik/config/paths
import isvik/config/settings
import isvik/cache/compiled_cache
import isvik/util/checksum

var tmpCounter = 0

proc makeTempDir(): string =
  inc tmpCounter
  result = getTempDir() / ("isvik_test_cache_" & $tmpCounter & "_" &
    $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc sampleInputs(): CacheKeyInputs =
  result = initCacheKeyInputs(
    modelId = "demo",
    entrypointPath = "D:/models/demo/openvino_model.xml",
    deviceRawName = "CPU",
    backendName = "openvino",
    backendVersion = "2026.3.0-22451")
  result.fileBytes = 1024
  result.fileMtime = 1_700_000_000

proc writeBlob(cache: CompiledCache, inputs: CacheKeyInputs,
               content: string = "fake-compiled-blob"): string =
  ## 模拟 Backend 的 exportCompiledModel:先落盘 blob,再 commit 元数据。
  result = cache.reserve(inputs)
  writeFile(result, content)
  discard cache.commit(inputs)

# ---------------------------------------------------------------------------
# 键
# ---------------------------------------------------------------------------

suite "缓存键:构成必须完整":

  test "相同输入得到相同键":
    check cacheKey(sampleInputs()) == cacheKey(sampleInputs())

  test "键是 64 个十六进制字符,文件名安全":
    let key = cacheKey(sampleInputs())
    check key.len == 64
    for c in key:
      check c in {'0' .. '9', 'a' .. 'f'}

  test "模型变了键就变":
    var other = sampleInputs()
    other.modelId = "another"
    check cacheKey(other) != cacheKey(sampleInputs())

  test "设备 rawName 变了键就变 —— GPU.0 与 GPU.1 的 blob 不通用":
    # 这是最关键的一条。本机 GPU.0 是 Intel iGPU、GPU.1 是 NVIDIA 独显,
    # 若键里只区分到「GPU」,换卡就会加载到为另一张卡编译的产物。
    var intelGpu = sampleInputs()
    intelGpu.deviceRawName = "GPU.0"
    var nvidiaGpu = sampleInputs()
    nvidiaGpu.deviceRawName = "GPU.1"
    check cacheKey(intelGpu) != cacheKey(nvidiaGpu)

    var npu = sampleInputs()
    npu.deviceRawName = "NPU"
    check cacheKey(npu) != cacheKey(intelGpu)
    check cacheKey(npu) != cacheKey(sampleInputs())

  test "Backend 版本变了键就变":
    var upgraded = sampleInputs()
    upgraded.backendVersion = "2027.1.0"
    check cacheKey(upgraded) != cacheKey(sampleInputs())

  test "Backend 名字变了键就变":
    var other = sampleInputs()
    other.backendName = "someotherbackend"
    check cacheKey(other) != cacheKey(sampleInputs())

  test "文件大小变了键就变":
    var grown = sampleInputs()
    grown.fileBytes = 2048
    check cacheKey(grown) != cacheKey(sampleInputs())

  test "编译属性变了键就变":
    var withProps = sampleInputs()
    withProps.properties["PERFORMANCE_HINT"] = "LATENCY"
    check cacheKey(withProps) != cacheKey(sampleInputs())

    var differentValue = sampleInputs()
    differentValue.properties["PERFORMANCE_HINT"] = "THROUGHPUT"
    check cacheKey(differentValue) != cacheKey(withProps)

  test "属性顺序不影响键":
    # Table 的迭代顺序不保证稳定;不排序会让同一组属性在两次运行中
    # 算出不同的键,缓存永远不命中而且看不出原因。
    var a = sampleInputs()
    a.properties["A"] = "1"
    a.properties["B"] = "2"
    a.properties["C"] = "3"
    var b = sampleInputs()
    b.properties["C"] = "3"
    b.properties["B"] = "2"
    b.properties["A"] = "1"
    check cacheKey(a) == cacheKey(b)

  test "有校验和时 mtime 不参与键":
    # 复制或解压会重置 mtime 而内容未变,那种情况下不该让缓存失效。
    var a = sampleInputs()
    a.fileChecksum = sha256Hex("weights")
    a.fileMtime = 1
    var b = a
    b.fileMtime = 999_999
    check cacheKey(a) == cacheKey(b)

  test "没有校验和时 mtime 参与键":
    var a = sampleInputs()
    var b = a
    b.fileMtime = a.fileMtime + 1
    check cacheKey(a) != cacheKey(b)

  test "校验和不同则键不同":
    var a = sampleInputs()
    a.fileChecksum = sha256Hex("v1")
    var b = sampleInputs()
    b.fileChecksum = sha256Hex("v2")
    check cacheKey(a) != cacheKey(b)

  test "规范形式含键算法标识与全部输入":
    let text = sampleInputs().canonicalForm()
    check text.contains(CacheKeyAlgorithm)
    check text.contains("model=demo")
    check text.contains("device=CPU")
    check text.contains("backend=openvino")
    check text.contains("backendVersion=2026.3.0-22451")

  test "只用文件名而非完整路径参与键":
    # 同一份模型被移动到别处不该让缓存失效 —— 内容没变。
    var moved = sampleInputs()
    moved.entrypointPath = "E:/elsewhere/openvino_model.xml"
    check cacheKey(moved) == cacheKey(sampleInputs())

  test "withFileIdentity 从磁盘读取真实身份":
    let dir = makeTempDir()
    let path = dir / "openvino_model.xml"
    writeFile(path, "<net/>")
    let inputs = initCacheKeyInputs("m", path, "CPU", "openvino", "1")
      .withFileIdentity(path)
    check inputs.fileBytes == getFileSize(path)
    check inputs.fileMtime > 0
    removeDir(dir)

  test "对不存在的文件计算身份抛 MODEL_NOT_FOUND":
    var code: IsvikErrorCode
    try:
      discard initCacheKeyInputs("m", "x", "CPU", "openvino", "1")
        .withFileIdentity(getTempDir() / "isvik_no_such_cache_file")
      check false
    except IsvikError as e:
      code = e.code
    check code == ecModelNotFound

# ---------------------------------------------------------------------------
# 命中与未命中
# ---------------------------------------------------------------------------

suite "查询:命中、未命中与绕过":

  test "空缓存返回 miss":
    let cache = newCompiledCache(makeTempDir())
    let outcome = cache.lookup(sampleInputs())
    check outcome.status == csMiss
    check not outcome.isUsable
    check outcome.blobPath == ""
    check outcome.reason.len > 0
    check cache.metrics.misses == 1

  test "写入后命中,并给出可用的 blob 路径":
    let cache = newCompiledCache(makeTempDir())
    let blob = cache.writeBlob(sampleInputs())

    let outcome = cache.lookup(sampleInputs())
    check outcome.status == csHit
    check outcome.isUsable
    check outcome.blobPath == blob
    check cache.metrics.hits == 1
    check cache.metrics.writes == 1
    check cache.metrics.bytesServed > 0

  test "键的任一输入变化都导致 miss":
    let cache = newCompiledCache(makeTempDir())
    discard cache.writeBlob(sampleInputs())

    var otherDevice = sampleInputs()
    otherDevice.deviceRawName = "GPU.0"
    check cache.lookup(otherDevice).status == csMiss

    var otherVersion = sampleInputs()
    otherVersion.backendVersion = "9.9.9"
    check cache.lookup(otherVersion).status == csMiss

    var otherSize = sampleInputs()
    otherSize.fileBytes = 4096
    check cache.lookup(otherSize).status == csMiss

    # 原键仍然命中。
    check cache.lookup(sampleInputs()).status == csHit

  test "禁用缓存时返回 disabled,且不读磁盘":
    let cache = newCompiledCache(makeTempDir())
    discard cache.writeBlob(sampleInputs())
    cache.setEnabled(false)

    let outcome = cache.lookup(sampleInputs())
    check outcome.status == csDisabled
    check not outcome.isUsable
    # disabled 不计入命中率统计。
    check cache.metrics.hits == 0
    check cache.metrics.misses == 0

  test "bypass 返回 bypassed,不读磁盘也不算 miss":
    # Benchmark 需要现场编译才能拿到 per-layer 数据。
    let cache = newCompiledCache(makeTempDir())
    discard cache.writeBlob(sampleInputs())

    let outcome = cache.lookup(sampleInputs(), bypass = true)
    check outcome.status == csBypassed
    check not outcome.isUsable
    check cache.metrics.bypassed == 1
    check cache.metrics.hits == 0
    check cache.metrics.misses == 0

  test "命中率的分母不含 bypassed":
    # 否则「Benchmark 跑了几轮」会污染缓存有效性的判断。
    let cache = newCompiledCache(makeTempDir())
    discard cache.writeBlob(sampleInputs())
    discard cache.lookup(sampleInputs())                    # hit
    discard cache.lookup(sampleInputs(), bypass = true)      # bypassed
    var miss = sampleInputs()
    miss.modelId = "other"
    discard cache.lookup(miss)                               # miss

    check cache.metrics.hits == 1
    check cache.metrics.misses == 1
    check cache.metrics.bypassed == 1
    check cache.metrics.hitRate == 0.5

# ---------------------------------------------------------------------------
# profiling 互斥
# ---------------------------------------------------------------------------

suite "与 profiling 的互斥必须被显式上报":

  test "命中且请求 profiling 时给出不可用原因":
    # blob 不含运行期属性,本机 NPU 驱动会拒绝 import 后设置 PERF_COUNT。
    # 静默返回空数据就是伪造 Benchmark(§35)。
    let cache = newCompiledCache(makeTempDir())
    discard cache.writeBlob(sampleInputs())

    let outcome = cache.lookup(sampleInputs(), profilingRequested = true)
    check outcome.status == csHit
    check outcome.profilingUnavailableReason.len > 0
    check outcome.profilingUnavailableReason.contains("cache")
    # 原因里必须告诉用户怎么才能拿到数据。
    check outcome.profilingUnavailableReason.contains("bypass")

  test "不请求 profiling 时不产生这条原因":
    let cache = newCompiledCache(makeTempDir())
    discard cache.writeBlob(sampleInputs())
    check cache.lookup(sampleInputs()).profilingUnavailableReason == ""

  test "未命中时不产生这条原因":
    # 没命中就会现场编译,profiling 是可用的。
    let cache = newCompiledCache(makeTempDir())
    let outcome = cache.lookup(sampleInputs(), profilingRequested = true)
    check outcome.status == csMiss
    check outcome.profilingUnavailableReason == ""

  test "绕过缓存时不产生这条原因":
    let cache = newCompiledCache(makeTempDir())
    discard cache.writeBlob(sampleInputs())
    let outcome = cache.lookup(sampleInputs(), bypass = true,
                               profilingRequested = true)
    check outcome.status == csBypassed
    check outcome.profilingUnavailableReason == ""

# ---------------------------------------------------------------------------
# 完整性
# ---------------------------------------------------------------------------

suite "完整性校验":

  test "blob 内容被改动后按 corrupted 处理并删除条目":
    let cache = newCompiledCache(makeTempDir())
    let blob = cache.writeBlob(sampleInputs(), "original-content")
    check cache.lookup(sampleInputs()).status == csHit

    # 保持长度不变地改内容 —— 只有校验和能发现。
    writeFile(blob, "tampered-content")
    let outcome = cache.lookup(sampleInputs())
    check outcome.status == csCorrupted
    check not outcome.isUsable
    check outcome.reason.contains("checksum")
    check cache.metrics.corrupted == 1
    # 坏条目必须被删掉,否则每次查询都要重算一遍校验和。
    check not fileExists(blob)

  test "blob 大小不符按 corrupted 处理":
    let cache = newCompiledCache(makeTempDir())
    let blob = cache.writeBlob(sampleInputs(), "original")
    writeFile(blob, "a-much-longer-content-than-before")
    let outcome = cache.lookup(sampleInputs())
    check outcome.status == csCorrupted
    check outcome.reason.contains("size")

  test "元数据缺失时不使用该 blob":
    # 来路不明的 blob 不冒险使用。
    let cache = newCompiledCache(makeTempDir())
    discard cache.writeBlob(sampleInputs())
    removeFile(cache.metaPathFor(cacheKey(sampleInputs())))

    let outcome = cache.lookup(sampleInputs())
    check outcome.status == csCorrupted
    check outcome.reason.contains("metadata")

  test "键算法不符的旧条目被丢弃":
    let cache = newCompiledCache(makeTempDir())
    let key = cacheKey(sampleInputs())
    discard cache.writeBlob(sampleInputs())

    # 手工把元数据改成另一套算法产生的样子。
    var meta = parseJson(readFile(cache.metaPathFor(key)))
    meta["key_algorithm"] = %"isvik-compiled-cache-v0"
    writeFile(cache.metaPathFor(key), $meta)

    let outcome = cache.lookup(sampleInputs())
    check outcome.status == csCorrupted
    check outcome.reason.contains("key algorithm")

  test "关闭读取校验后不再比对内容":
    # 开关存在是为了让「校验开销是否值得」可被实测。
    let cache = newCompiledCache(makeTempDir())
    let blob = cache.writeBlob(sampleInputs(), "original")
    cache.setVerifyOnRead(false)
    writeFile(blob, "tampered")     # 同长度改动
    check cache.lookup(sampleInputs()).status == csHit

  test "verifyAll 报告问题但不删除":
    let cache = newCompiledCache(makeTempDir())
    let blob = cache.writeBlob(sampleInputs(), "original")
    check cache.verifyAll().len == 0

    writeFile(blob, "tampered")
    let issues = cache.verifyAll()
    check issues.len == 1
    check issues[0].key == cacheKey(sampleInputs())
    check issues[0].problem.contains("checksum")
    # 诊断不该有副作用。
    check fileExists(blob)

  test "purgeCorrupted 删除损坏条目":
    let cache = newCompiledCache(makeTempDir())
    let blob = cache.writeBlob(sampleInputs(), "original")
    var other = sampleInputs()
    other.modelId = "healthy"
    discard cache.writeBlob(other, "healthy-blob")

    writeFile(blob, "tampered")
    check cache.purgeCorrupted() == 1
    check cache.verifyAll().len == 0
    # 健康条目必须留着。
    check cache.lookup(other).status == csHit

# ---------------------------------------------------------------------------
# 写入
# ---------------------------------------------------------------------------

suite "写入:两步提交":

  test "reserve 只给路径并建目录,不写文件":
    let dir = makeTempDir() / "nested" / "cache"
    let cache = newCompiledCache(dir)
    let path = cache.reserve(sampleInputs())
    check dirExists(cache.directory)
    check not fileExists(path)

  test "未落盘就 commit 会报错":
    # 元数据的存在即「条目完整」的标志,不能先于 blob 写入。
    let cache = newCompiledCache(makeTempDir())
    discard cache.reserve(sampleInputs())
    expect IsvikError:
      discard cache.commit(sampleInputs())

  test "空 blob 被拒绝提交":
    # 空文件不可能是有效的编译产物。留着它只会在下次命中时才失败。
    let cache = newCompiledCache(makeTempDir())
    let path = cache.reserve(sampleInputs())
    writeFile(path, "")
    expect IsvikError:
      discard cache.commit(sampleInputs())
    # 失败后不留残骸。
    check not fileExists(path)

  test "commit 记录真实大小与校验和":
    let cache = newCompiledCache(makeTempDir())
    let content = "compiled-blob-bytes"
    let path = cache.reserve(sampleInputs())
    writeFile(path, content)
    let meta = cache.commit(sampleInputs())

    check meta.schemaVersion == CacheSchemaVersion
    check meta.keyAlgorithm == CacheKeyAlgorithm
    check meta.key == cacheKey(sampleInputs())
    check meta.blobBytes == content.len
    check meta.blobChecksum == sha256Hex(content)
    check meta.createdAt.len > 0
    # 键输入被完整记录下来,便于人工排查「为什么这次没命中」。
    check meta.inputs.deviceRawName == "CPU"
    check meta.inputs.modelId == "demo"

  test "元数据可被读回且字段一致":
    let cache = newCompiledCache(makeTempDir())
    var inputs = sampleInputs()
    inputs.properties["PERFORMANCE_HINT"] = "LATENCY"
    discard cache.writeBlob(inputs)

    let entries = cache.entries()
    check entries.len == 1
    check entries[0].inputs.properties.getOrDefault("PERFORMANCE_HINT") ==
      "LATENCY"

  test "重复写入同一键覆盖而不重复占空间":
    let cache = newCompiledCache(makeTempDir())
    discard cache.writeBlob(sampleInputs(), "first-version")
    discard cache.writeBlob(sampleInputs(), "second-version-longer")
    check cache.listKeys().len == 1
    check cache.lookup(sampleInputs()).status == csHit

# ---------------------------------------------------------------------------
# 维护
# ---------------------------------------------------------------------------

suite "失效与维护":

  test "按模型失效":
    let cache = newCompiledCache(makeTempDir())
    for device in ["CPU", "GPU.0", "NPU"]:
      var inputs = sampleInputs()
      inputs.deviceRawName = device
      discard cache.writeBlob(inputs)
    var other = sampleInputs()
    other.modelId = "keep-me"
    discard cache.writeBlob(other)

    check cache.listKeys().len == 4
    check cache.invalidateModel("demo") == 3
    check cache.listKeys().len == 1
    check cache.lookup(other).status == csHit

  test "按设备失效":
    let cache = newCompiledCache(makeTempDir())
    for device in ["CPU", "GPU.0", "GPU.1"]:
      var inputs = sampleInputs()
      inputs.deviceRawName = device
      discard cache.writeBlob(inputs)

    check cache.invalidateDevice("GPU.1") == 1
    check cache.listKeys().len == 2
    var gpu1 = sampleInputs()
    gpu1.deviceRawName = "GPU.1"
    check cache.lookup(gpu1).status == csMiss

  test "清理非当前 Backend 版本的条目":
    # 升级 OpenVINO 后旧 blob 不会被命中,但会一直占磁盘。
    let cache = newCompiledCache(makeTempDir())
    var old = sampleInputs()
    old.backendVersion = "2025.4.0"
    discard cache.writeBlob(old)
    discard cache.writeBlob(sampleInputs())    # 2026.3.0-22451

    check cache.listKeys().len == 2
    check cache.invalidateStaleBackend("openvino", "2026.3.0-22451") == 1
    check cache.listKeys().len == 1
    check cache.lookup(sampleInputs()).status == csHit

  test "清理孤立文件":
    let cache = newCompiledCache(makeTempDir())
    discard cache.writeBlob(sampleInputs())
    let key = cacheKey(sampleInputs())

    # 模拟写入过程中崩溃:只剩 blob,没有元数据。
    removeFile(cache.metaPathFor(key))
    # 再造一个只有元数据的残骸。
    writeFile(cache.metaPathFor("deadbeef"), "{}")

    check cache.purgeOrphans() == 2
    check cache.listKeys().len == 0

  test "totalBytes 汇总 blob 占用":
    let cache = newCompiledCache(makeTempDir())
    discard cache.writeBlob(sampleInputs(), "12345")
    var other = sampleInputs()
    other.modelId = "second"
    discard cache.writeBlob(other, "1234567890")
    check cache.totalBytes == 15

  test "clear 清空全部条目":
    let cache = newCompiledCache(makeTempDir())
    for i in 0 .. 2:
      var inputs = sampleInputs()
      inputs.modelId = "model-" & $i
      discard cache.writeBlob(inputs)
    check cache.clear() == 3
    check cache.listKeys().len == 0
    check cache.totalBytes == 0

  test "listKeys 只列完整条目":
    let cache = newCompiledCache(makeTempDir())
    discard cache.writeBlob(sampleInputs())
    # 手造一个没有元数据的 blob。
    writeFile(cache.blobPathFor("aabbcc"), "orphan")
    check cache.listKeys().len == 1

  test "指标可重置":
    let cache = newCompiledCache(makeTempDir())
    discard cache.writeBlob(sampleInputs())
    discard cache.lookup(sampleInputs())
    check cache.metrics.hits == 1
    cache.resetMetrics()
    check cache.metrics.hits == 0
    check cache.metrics.writes == 0

  test "空缓存的目录不存在时列举与统计不报错":
    # 首次运行的正常状态。
    let cache = newCompiledCache(makeTempDir() / "never-created")
    check cache.listKeys().len == 0
    check cache.totalBytes == 0
    check cache.verifyAll().len == 0
    check cache.purgeOrphans() == 0

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------

suite "缓存位置来自配置":

  test "默认位于 ISVIK_HOME/cache/compiled":
    let root = makeTempDir()
    let cache = newCompiledCache(newIsvikPaths(root), defaultSettings())
    check cache.directory == newIsvikPaths(root).cache / CompiledSubdirectory
    removeDir(root)

  test "cache_directory 覆盖默认位置":
    let root = makeTempDir()
    var s = defaultSettings()
    s.cacheDirectory = root / "big-disk-cache"
    let cache = newCompiledCache(newIsvikPaths(root), s)
    check cache.directory ==
      normalizedPath(absolutePath(root / "big-disk-cache")) /
        CompiledSubdirectory
    removeDir(root)

  test "默认开启,且默认校验读取内容":
    let cache = newCompiledCache(makeTempDir())
    check cache.isEnabled
    let blob = cache.writeBlob(sampleInputs(), "original")
    writeFile(blob, "tampered")
    # 默认校验开启,因此能发现。
    check cache.lookup(sampleInputs()).status == csCorrupted
