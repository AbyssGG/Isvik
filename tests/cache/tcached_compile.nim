## 带缓存编译的测试
##
## 用 MockBackend,因此在没有 OpenVINO 的机器上也能跑。MockBackend 的
## `exportCompiledModel` 会把路径登记为有效 blob,`importCompiledModel`
## 会校验路径是否登记过 —— 足以验证「命中走 import、未命中走 compile」
## 这条分支逻辑。
##
## 真实 blob 的字节级正确性由 `tests/backends/tovbackend.nim` 覆盖。

import std/[unittest, os, tables, strutils]

import isvik/core/errors
import isvik/core/runtime
import isvik/backends/mock/mock_backend
import isvik/cache/compiled_cache
import isvik/cache/cached_compile

var tmpCounter = 0

proc makeTempDir(): string =
  inc tmpCounter
  result = getTempDir() / ("isvik_test_cc_" & $tmpCounter & "_" &
    $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc intelTopology(): MockBackend =
  newMockBackend(@[
    newMockDeviceInfo("CPU", "Mock Intel CPU"),
    newMockDeviceInfo("GPU.0", "Mock Intel Graphics",
      [("DEVICE_ARCHITECTURE", "GPU: vendor=0x8086 arch=v12")]),
    newMockDeviceInfo("GPU.1", "Mock NVIDIA dGPU",
      [("DEVICE_ARCHITECTURE", "GPU: vendor=0x10de arch=v12")]),
    newMockDeviceInfo("NPU", "Mock Intel AI Boost")
  ])

type Fixture = object
  rt: Runtime
  backend: MockBackend
  cache: CompiledCache
  modelPath: string
  modelId: ModelId

proc setupFixture(): Fixture =
  ## 造一个「模型文件 + Runtime + 缓存」的完整环境。
  let dir = makeTempDir()
  result.modelPath = dir / "openvino_model.xml"
  writeFile(result.modelPath, "<net name=\"demo\"/>")

  result.backend = intelTopology()
  result.rt = newRuntime(result.backend)
  result.rt.initialize()
  result.modelId = result.rt.loadModel(result.modelPath)
  result.cache = newCompiledCache(dir / "cache")

proc compileOnce(f: Fixture, options: CachedCompileOptions):
    CachedCompileResult =
  compileWithCache(f.rt, f.cache, f.modelId, "demo", f.modelPath, options)

suite "带缓存编译:命中与未命中":

  test "首次编译是现场编译并写入缓存":
    let f = setupFixture()
    let r = f.compileOnce(initCachedCompileOptions("CPU"))

    check r.source == ccsCompiled
    check r.cacheStatus == csMiss
    check r.cacheKey.len == 64
    check r.cacheWriteError == ""
    check f.rt.compiledModelDevice(r.compiled) == "CPU"
    check f.cache.listKeys().len == 1
    check f.cache.metrics.writes == 1
    f.rt.shutdown()

  test "第二次编译命中缓存并走 import":
    let f = setupFixture()
    discard f.compileOnce(initCachedCompileOptions("CPU"))
    f.backend.clearCallLog()

    let second = f.compileOnce(initCachedCompileOptions("CPU"))
    check second.source == ccsCacheHit
    check second.cacheStatus == csHit

    # 命中必须走 import,不能再 compile 一次。
    check "importCompiledModel" in f.backend.callLog
    check "compileModel" notin f.backend.callLog
    f.rt.shutdown()

  test "AUTO 先解析设备再算键,键里是实际 rawName":
    let f = setupFixture()
    let r = f.compileOnce(initCachedCompileOptions("AUTO"))
    # 本拓扑下 AUTO 选 NPU。
    check r.selection.device.rawName == "NPU"
    check f.rt.compiledModelDevice(r.compiled) == "NPU"

    let entries = f.cache.entries()
    check entries.len == 1
    check entries[0].inputs.deviceRawName == "NPU"
    f.rt.shutdown()

  test "同一模型在不同设备上各有一份缓存":
    let f = setupFixture()
    for device in ["CPU", "GPU", "NPU"]:
      discard f.compileOnce(initCachedCompileOptions(device))
    check f.cache.listKeys().len == 3

    # 每一份都命中自己的那条。
    for device in ["CPU", "GPU", "NPU"]:
      check f.compileOnce(initCachedCompileOptions(device)).source == ccsCacheHit
    f.rt.shutdown()

  test "显式 GPU 的缓存记的是 GPU.0 而不是 GPU":
    # 键里必须是 rawName,否则换到 GPU.1 会命中为 Intel 卡编译的 blob。
    let f = setupFixture()
    discard f.compileOnce(initCachedCompileOptions("GPU"))
    check f.cache.entries()[0].inputs.deviceRawName == "GPU.0"
    f.rt.shutdown()

  test "模型文件内容变化后不再命中":
    let f = setupFixture()
    discard f.compileOnce(initCachedCompileOptions("CPU"))
    check f.compileOnce(initCachedCompileOptions("CPU")).source == ccsCacheHit

    # 改文件大小 —— 文件身份变了。
    writeFile(f.modelPath, "<net name=\"demo\"><changed/></net>")
    let after = f.compileOnce(initCachedCompileOptions("CPU"))
    check after.source == ccsCompiled
    check after.cacheStatus == csMiss
    f.rt.shutdown()

  test "编译属性不同则各自缓存":
    let f = setupFixture()
    var withHint = initCachedCompileOptions("CPU")
    withHint.properties["PERFORMANCE_HINT"] = "LATENCY"

    discard f.compileOnce(initCachedCompileOptions("CPU"))
    discard f.compileOnce(withHint)
    check f.cache.listKeys().len == 2
    f.rt.shutdown()

suite "带缓存编译:绕过与 profiling":

  test "bypassCache 强制现场编译,即使缓存里有":
    let f = setupFixture()
    discard f.compileOnce(initCachedCompileOptions("CPU"))
    f.backend.clearCallLog()

    var opts = initCachedCompileOptions("CPU")
    opts.bypassCache = true
    let r = f.compileOnce(opts)

    check r.source == ccsCompiled
    check r.cacheStatus == csBypassed
    check "compileModel" in f.backend.callLog
    check "importCompiledModel" notin f.backend.callLog
    f.rt.shutdown()

  test "绕过缓存时不写缓存,不覆盖已有条目":
    let f = setupFixture()
    discard f.compileOnce(initCachedCompileOptions("CPU"))
    let writesBefore = f.cache.metrics.writes

    var opts = initCachedCompileOptions("CPU")
    opts.bypassCache = true
    discard f.compileOnce(opts)
    check f.cache.metrics.writes == writesBefore
    f.rt.shutdown()

  test "命中且请求 profiling 时如实报告拿不到数据":
    # 这条是 §35 的落实点:不得声称采集成功。
    let f = setupFixture()
    discard f.compileOnce(initCachedCompileOptions("CPU"))

    var opts = initCachedCompileOptions("CPU", enableProfiling = true)
    # 注意 enableProfiling 会进键,所以先用不带 profiling 的键预热是不够的。
    # 这里手工构造「缓存里已有带 profiling 键的条目」的场景:
    discard f.compileOnce(opts)                  # 首次:编译并写入
    let second = f.compileOnce(opts)             # 第二次:命中

    check second.source == ccsCacheHit
    # 实际没有 profiling —— blob 不含运行期属性。
    check not second.profilingEnabled
    check second.profilingUnavailableReason.len > 0
    check second.profilingUnavailableReason.contains("bypass")
    f.rt.shutdown()

  test "现场编译时 profiling 真的启用了":
    let f = setupFixture()
    let r = f.compileOnce(
      initCachedCompileOptions("CPU", enableProfiling = true))
    check r.source == ccsCompiled
    check r.profilingEnabled
    check r.profilingUnavailableReason == ""
    f.rt.shutdown()

  test "profiling 与非 profiling 的编译不共用缓存条目":
    # 否则普通编译可能命中一份带 PERF_COUNT 的 blob(或反之)。
    let f = setupFixture()
    discard f.compileOnce(initCachedCompileOptions("CPU"))
    discard f.compileOnce(
      initCachedCompileOptions("CPU", enableProfiling = true))
    check f.cache.listKeys().len == 2
    f.rt.shutdown()

  test "benchmarkCompileOptions 一定绕过缓存且不写缓存":
    # 忘了绕过就会得到一份没有 profiling 数据的结果,而那正是伪造的来源。
    let opts = benchmarkCompileOptions("NPU")
    check opts.enableProfiling
    check opts.bypassCache
    check not opts.writeCache

    let f = setupFixture()
    let r = f.compileOnce(opts)
    check r.source == ccsCompiled
    check r.cacheStatus == csBypassed
    check r.profilingEnabled
    check f.cache.listKeys().len == 0
    f.rt.shutdown()

suite "带缓存编译:失败路径":

  test "缓存被禁用时每次都现场编译,且不报错":
    let f = setupFixture()
    f.cache.setEnabled(false)
    let first = f.compileOnce(initCachedCompileOptions("CPU"))
    let second = f.compileOnce(initCachedCompileOptions("CPU"))
    check first.source == ccsCompiled
    check second.source == ccsCompiled
    check second.cacheStatus == csDisabled
    check f.cache.listKeys().len == 0
    f.rt.shutdown()

  test "导出 blob 失败不影响模型可用性":
    # 编译成功但缓存没写上,只是下次还得重编。把它当整体失败会让一个
    # 纯粹的磁盘问题挡住推理。
    let f = setupFixture()
    f.backend.injectFailure(mfExportCompiledModel)

    let r = f.compileOnce(initCachedCompileOptions("CPU"))
    check r.source == ccsCompiled
    check r.cacheWriteError.len > 0
    # 模型句柄仍然有效 —— 能创建推理请求就是证据。
    let request = f.rt.createInferRequest(r.compiled)
    check f.rt.activeRequestCount == 1
    f.rt.releaseInferRequest(request)
    # 失败后不留下半成品条目。
    check f.cache.listKeys().len == 0
    f.rt.shutdown()

  test "编译本身失败仍然抛出,不被缓存逻辑吞掉":
    let f = setupFixture()
    f.backend.injectFailure(mfCompileModel)
    var code: IsvikErrorCode
    try:
      discard f.compileOnce(initCachedCompileOptions("CPU"))
      check false
    except IsvikError as e:
      code = e.code
    check code == ecCompilationFailed
    f.rt.shutdown()

  test "请求不存在的设备时报设备类错误,不产生缓存条目":
    let f = setupFixture()
    let cpuOnly = newMockBackend(@[newMockDeviceInfo("CPU", "Mock CPU")])
    let rt = newRuntime(cpuOnly)
    rt.initialize()
    let dir = makeTempDir()
    let path = dir / "m.xml"
    writeFile(path, "<net/>")
    let mid = rt.loadModel(path)
    let cache = newCompiledCache(dir / "cache")

    var code: IsvikErrorCode
    try:
      discard compileWithCache(rt, cache, mid, "demo", path,
                              initCachedCompileOptions("NPU"))
      check false
    except IsvikError as e:
      code = e.code
    check code == ecNpuNotAvailable
    check cache.listKeys().len == 0
    rt.shutdown()
    f.rt.shutdown()

  test "缓存条目损坏后回落到现场编译":
    let f = setupFixture()
    let r = f.compileOnce(initCachedCompileOptions("CPU"))
    let blob = f.cache.blobPathFor(r.cacheKey)
    check fileExists(blob)

    # 同长度篡改,只有校验和能发现。
    let original = readFile(blob)
    writeFile(blob, "x".repeat(original.len))

    let after = f.compileOnce(initCachedCompileOptions("CPU"))
    check after.cacheStatus == csCorrupted
    check after.source == ccsCompiled
    f.rt.shutdown()

suite "结果摘要":

  test "describe 含实际设备、耗时与缓存状态":
    let f = setupFixture()
    let r = f.compileOnce(initCachedCompileOptions("AUTO"))
    let text = r.describe()
    check text.contains("NPU")
    check text.contains("Mock Intel AI Boost")
    check text.contains("elapsed=")
    check text.contains("cache=")
    f.rt.shutdown()

  test "describe 在 profiling 不可用时明确标出":
    let f = setupFixture()
    var opts = initCachedCompileOptions("CPU", enableProfiling = true)
    discard f.compileOnce(opts)
    let second = f.compileOnce(opts)
    check second.describe().contains("profiling=unavailable")
    f.rt.shutdown()
