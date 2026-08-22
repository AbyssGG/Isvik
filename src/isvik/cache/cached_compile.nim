## 带缓存的编译(把 Compiled Cache 接到 Runtime 上)
##
## ---
##
## ## 为什么不把这段逻辑放进 Runtime
##
## `core/runtime.nim` 位于 Core,而缓存需要知道模型 id、缓存目录、配置 ——
## 那些都是上层概念。让 Core 依赖 `isvik/cache` 会把依赖方向反过来。
##
## 所以顺序是:
##
## ```text
## services / cli  →  cache/cached_compile  →  core/runtime + cache/compiled_cache
## ```
##
## Runtime 保持只认「模型句柄 + 设备 rawName」,不知道缓存的存在。
##
## ---
##
## ## 流程
##
## ```text
## 1. 解析设备(AUTO → 实际 rawName)      Runtime.resolveDevice
## 2. 用实际 rawName 算缓存键              键里必须是 rawName,不是 GPU
## 3. 查缓存
##    命中  → importCompiledModel(blob)
##    未命中 → compileModel + exportCompiledModel + commit
## 4. 如实报告本次是编译还是命中,以及 profiling 是否可用
## ```
##
## 第 2 步的顺序是必须的:AUTO 在不同机器上会选到不同设备,先解析再算键
## 才能保证键对应的是真正用到的那块硬件。
##
## ---
##
## ## 导出失败不算编译失败
##
## 编译成功但导出 blob 失败(磁盘满、权限不足)时,**返回已编译好的模型**,
## 只是没缓存下来。把它当成整体失败会让一个纯粹的磁盘问题挡住推理 ——
## 缓存本来就是可丢弃的。失败原因记在结果里,由上层决定是否提示。

import std/[tables, monotimes, times]

import isvik/core/errors
import isvik/core/backend
import isvik/core/runtime
import isvik/cache/compiled_cache

type
  CompileSource* = enum
    ## 本次已编译模型的来源。
    ccsCompiled = "compiled"
      ## 现场编译。
    ccsCacheHit = "cache-hit"
      ## 从缓存 blob 导入。

  CachedCompileResult* = object
    ## 一次带缓存编译的完整结果。
    compiled*: CompiledModelId
    selection*: DeviceSelection
      ## 设备解析结果。含实际 rawName 与 fullName。
    source*: CompileSource
    cacheStatus*: CacheStatus
    cacheKey*: string
    elapsedMs*: int64
      ## 本次操作的墙钟耗时(编译或导入)。
    profilingEnabled*: bool
      ## **实际**是否启用了 profiling。
      ##
      ## 与调用方请求的可能不同:走缓存时一定是 false,因为 blob 不含
      ## 运行期属性。
    profilingUnavailableReason*: string
      ## 请求了 profiling 但拿不到时的原因。空表示没有这个问题。
      ##
      ## **非空时上层必须如实上报**,不得声称采集成功(§35)。
    cacheWriteError*: string
      ## 导出 blob 失败的原因。空表示成功或未尝试。
      ##
      ## 非空**不代表编译失败** —— 模型仍然可用,只是没被缓存。

  CachedCompileOptions* = object
    ## 编译选项。
    device*: string
      ## 语义设备请求(AUTO / CPU / GPU / NPU)。
    enableProfiling*: bool
      ## 是否需要 per-layer profiling。
      ##
      ## 注意这**不会**自动绕过缓存 —— 是否绕过由 `bypassCache` 决定。
      ## 两者分开是因为「想要 profiling」与「愿意付重新编译的代价」
      ## 是两个决定,Benchmark 会同时设置它们,而普通推理只想快点启动。
    bypassCache*: bool
      ## 强制现场编译。Benchmark 需要 per-layer 数据时必须设为 true。
    writeCache*: bool
      ## 现场编译后是否写入缓存。默认 true。
    properties*: Table[string, string]

proc initCachedCompileOptions*(device: string = DeviceRequestAuto,
                               enableProfiling: bool = false,
                               bypassCache: bool = false):
    CachedCompileOptions =
  CachedCompileOptions(
    device: device,
    enableProfiling: enableProfiling,
    bypassCache: bypassCache,
    writeCache: true,
    properties: initTable[string, string]()
  )

proc benchmarkCompileOptions*(device: string = DeviceRequestAuto):
    CachedCompileOptions =
  ## Benchmark 用的选项:要 profiling,因此必须绕过缓存。
  ##
  ## 单独给一个构造函数,是为了让「Benchmark 必须绕过缓存」这条约束
  ## 有一个不会被忘记的入口 —— 忘了绕过就会得到一份没有 profiling 数据的
  ## 结果,而那正是 §35 禁止的伪造来源。
  result = initCachedCompileOptions(device, enableProfiling = true,
                                    bypassCache = true)
  # 绕过缓存时也不写缓存:profiling 编译产物与普通产物的属性不同,
  # 把它存进缓存会让后续普通编译命中一份带 PERF_COUNT 的 blob。
  result.writeCache = false

proc compileWithCache*(rt: Runtime, cache: CompiledCache,
                       modelId: ModelId,
                       modelKey: string,
                       modelFilePath: string,
                       options: CachedCompileOptions):
    CachedCompileResult =
  ## 编译模型,尽可能复用缓存。
  ##
  ## `modelKey` 是模型库中的 id(进入缓存键),`modelFilePath` 是主模型文件的
  ## 实际路径(用于取文件身份)。两者都由上层提供 —— Runtime 只有句柄,
  ## 不知道模型叫什么。
  let selection = rt.resolveDevice(options.device)

  var keyInputs = initCacheKeyInputs(
    modelId = modelKey,
    entrypointPath = modelFilePath,
    deviceRawName = selection.device.rawName,   # 必须是 rawName
    backendName = rt.backendName,
    backendVersion = rt.backendVersion)
  keyInputs.properties = options.properties
  if options.enableProfiling:
    # profiling 会改变编译产物的运行期属性,必须进键 —— 否则普通编译
    # 可能命中一份带 PERF_COUNT 的 blob(或反之)。
    keyInputs.properties["ISVIK_PROFILING"] = "YES"
  keyInputs = keyInputs.withFileIdentity(modelFilePath)

  let outcome = cache.lookup(keyInputs,
                             bypass = options.bypassCache,
                             profilingRequested = options.enableProfiling)

  result = CachedCompileResult(
    selection: selection,
    source: ccsCompiled,
    cacheStatus: outcome.status,
    cacheKey: outcome.key,
    elapsedMs: 0,
    profilingEnabled: false,
    profilingUnavailableReason: outcome.profilingUnavailableReason,
    cacheWriteError: ""
  )

  # --- 命中:直接导入 ---
  if outcome.isUsable:
    let started = getMonoTime()
    var options2 = initCompileOptions(selection.device.rawName)
    # blob 不含运行期属性,因此这里不设 enableProfiling —— 设了也不会生效,
    # 而 Backend 会如实把 profilingEnabled 记为 false。
    let imported = rt.importCompiledModel(outcome.blobPath, options2)
    result.elapsedMs = (getMonoTime() - started).inMilliseconds
    result.compiled = imported
    result.source = ccsCacheHit
    result.profilingEnabled = false
    return

  # --- 未命中:现场编译 ---
  let started = getMonoTime()
  let (compiledId, _) = rt.compileModelForDevice(
    modelId, options.device, options.enableProfiling, options.properties)
  result.elapsedMs = (getMonoTime() - started).inMilliseconds
  result.compiled = compiledId
  result.source = ccsCompiled
  result.profilingEnabled = options.enableProfiling

  # --- 写缓存(失败不影响可用性)---
  if not options.writeCache or not cache.isEnabled or options.bypassCache:
    return

  try:
    let blobPath = cache.reserve(keyInputs)
    rt.exportCompiledModel(compiledId, blobPath)
    discard cache.commit(keyInputs)
  except IsvikError as e:
    # 编译已经成功,模型可用。缓存没写上只是下次还得重编。
    result.cacheWriteError = $e.code & ": " & e.msg
    cache.dropEntry(outcome.key)
  except CatchableError as e:
    result.cacheWriteError = e.msg
    cache.dropEntry(outcome.key)

proc describe*(r: CachedCompileResult): string =
  ## 一行人类可读摘要。供日志与 `--verbose` 输出使用。
  ##
  ## 刻意把「实际设备」与「是否命中缓存」都写进去:这两项是排查
  ## 「为什么这次启动慢」时最先要看的。
  result = $r.source & " device=" & r.selection.device.rawName
  if r.selection.device.fullName.len > 0:
    result.add(" (" & r.selection.device.fullName & ")")
  result.add(" elapsed=" & $r.elapsedMs & "ms")
  result.add(" cache=" & $r.cacheStatus)
  if r.profilingEnabled:
    result.add(" profiling=on")
  if r.profilingUnavailableReason.len > 0:
    result.add(" profiling=unavailable")
  if r.cacheWriteError.len > 0:
    result.add(" cacheWriteError=" & r.cacheWriteError)
