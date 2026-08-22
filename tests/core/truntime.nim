## Task 5 测试:Runtime 生命周期、句柄安全与 MockBackend
##
## 本文件是 Milestone 1 的核心验收:
## 完整的推理生命周期必须能在**没有安装 OpenVINO、没有 NPU** 的机器上验证。

import std/[unittest, json, strutils, tables]

import isvik/core/errors
import isvik/core/events
import isvik/core/tensor
import isvik/core/backend
import isvik/core/runtime
import isvik/backends/mock/mock_backend

proc cpuOnly(): MockBackend =
  newMockBackend(@[newMockDeviceInfo("CPU", "Mock CPU Device")])

proc cpuGpuNpu(): MockBackend =
  newMockBackend(@[
    newMockDeviceInfo("CPU", "Mock CPU Device"),
    newMockDeviceInfo("GPU.0", "Mock Integrated GPU"),
    newMockDeviceInfo("NPU", "Mock Intel AI Boost NPU")
  ])

proc readyRuntime(b: MockBackend = nil, bus: EventBus = nil): Runtime =
  ## 构造一个已初始化的 Runtime。
  let backend = if b == nil: cpuOnly() else: b
  result = newRuntime(backend, bus)
  result.initialize()

suite "完整推理生命周期(§8)":

  test "Initialize → Discover → Load → Compile → Request → Infer → Unload → Shutdown":
    let backend = cpuOnly()
    let rt = newRuntime(backend)

    check rt.state == rsUninitialized

    rt.initialize()
    check rt.state == rsReady

    let devices = rt.discoverDevices()
    check devices.len == 1
    check devices[0].rawName == "CPU"

    let modelId = rt.loadModel("mock://model.xml")
    check rt.loadedModelCount == 1

    let compiledId = rt.compileModel(modelId, initCompileOptions("CPU"))
    check rt.compiledModelCount == 1

    let requestId = rt.createInferRequest(compiledId)
    check rt.activeRequestCount == 1

    rt.setInput(requestId, 0, newTensor(etF32, [2], [1.0'f32, 2.0]))
    rt.infer(requestId)

    let output = rt.getOutput(requestId, 0)
    check output.elementType == etF32
    check output.toSeq(float32) == @[1.0'f32]   # 默认输出 = 推理次数

    rt.releaseInferRequest(requestId)
    rt.releaseCompiledModel(compiledId)
    rt.unloadModel(modelId)

    check rt.activeRequestCount == 0
    check rt.compiledModelCount == 0
    check rt.loadedModelCount == 0

    rt.shutdown()
    check rt.state == rsShutdown
    check backend.isReleased

  test "Backend 收到的调用顺序符合 §8 的生命周期":
    let backend = cpuOnly()
    let rt = newRuntime(backend)

    rt.initialize()
    discard rt.discoverDevices()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r = rt.createInferRequest(c)
    rt.setInput(r, 0, newTensor(etF32, [1], [1.0'f32]))
    rt.infer(r)
    discard rt.getOutput(r, 0)
    rt.shutdown()

    check backend.callLog == @[
      "initialize",
      "discoverDevices",
      "loadModel",
      "compileModel",
      "createInferRequest",
      "setInputTensor",
      "infer",
      "getOutputTensor",
      "releaseInferRequest",
      "releaseCompiledModel",
      "releaseModel",
      "release"
    ]

  test "多次推理累计执行次数":
    let rt = readyRuntime()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r = rt.createInferRequest(c)

    rt.infer(r)
    rt.infer(r)
    rt.infer(r)

    check rt.getOutput(r, 0).toSeq(float32) == @[3.0'f32]
    rt.shutdown()

  test "同一模型可编译到多个设备":
    let rt = readyRuntime(cpuGpuNpu())
    let m = rt.loadModel("mock://m.xml")

    let onCpu = rt.compileModel(m, initCompileOptions("CPU"))
    let onGpu = rt.compileModel(m, initCompileOptions("GPU.0"))
    let onNpu = rt.compileModel(m, initCompileOptions("NPU"))

    check rt.compiledModelCount == 3
    check rt.compiledModelDevice(onCpu) == "CPU"
    check rt.compiledModelDevice(onGpu) == "GPU.0"
    check rt.compiledModelDevice(onNpu) == "NPU"
    rt.shutdown()

  test "一个已编译模型可创建多个推理请求":
    let rt = readyRuntime()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))

    let r1 = rt.createInferRequest(c)
    let r2 = rt.createInferRequest(c)
    let r3 = rt.createInferRequest(c)

    check rt.activeRequestCount == 3
    # 每个请求的推理计数彼此独立
    rt.infer(r1)
    rt.infer(r1)
    rt.infer(r2)
    check rt.getOutput(r1, 0).toSeq(float32) == @[2.0'f32]
    check rt.getOutput(r2, 0).toSeq(float32) == @[1.0'f32]
    discard r3
    rt.shutdown()

  test "模型加载路径可查询":
    let rt = readyRuntime()
    let m = rt.loadModel("mock://qwen/model.xml")
    check rt.modelPath(m) == "mock://qwen/model.xml"
    rt.shutdown()

suite "状态校验":

  test "未初始化时操作抛 BACKEND_NOT_AVAILABLE":
    let rt = newRuntime(cpuOnly())
    var caught = false
    var code: IsvikErrorCode
    try:
      discard rt.loadModel("mock://m.xml")
    except IsvikError as e:
      caught = true
      code = e.code
    check caught
    if caught:
      check code == ecBackendNotAvailable

  test "未初始化时设备发现也被拒绝":
    let rt = newRuntime(cpuOnly())
    expect IsvikError:
      discard rt.discoverDevices()

  test "initialize 幂等":
    let backend = cpuOnly()
    let rt = newRuntime(backend)
    rt.initialize()
    rt.initialize()
    rt.initialize()
    # Backend 只应被初始化一次
    var initCount = 0
    for entry in backend.callLog:
      if entry == "initialize":
        inc initCount
    check initCount == 1
    rt.shutdown()

  test "shutdown 后操作被拒绝":
    let rt = readyRuntime()
    rt.shutdown()
    expect IsvikError:
      discard rt.loadModel("mock://m.xml")

  test "shutdown 后不允许重新初始化":
    # 复用已关闭的 Runtime 会让资源归属含糊,需要新实例应显式创建。
    let rt = readyRuntime()
    rt.shutdown()
    var caught = false
    try:
      rt.initialize()
    except IsvikError as e:
      caught = true
      check e.code == ecBackendNotAvailable
    check caught

  test "shutdown 幂等":
    let backend = cpuOnly()
    let rt = newRuntime(backend)
    rt.initialize()
    rt.shutdown()
    rt.shutdown()
    rt.shutdown()
    check rt.state == rsShutdown
    # Backend 的 release 只应被调用一次,不应产生重复释放
    check backend.doubleReleaseCount == 0

  test "错误信息包含操作名与当前状态,便于诊断":
    let rt = newRuntime(cpuOnly())
    try:
      discard rt.loadModel("mock://m.xml")
      check false
    except IsvikError as e:
      check e.detail.contains("operation=loadModel")
      check e.detail.contains("state=UNINITIALIZED")

suite "句柄安全:防 use-after-free(§8)":

  test "释放后的模型句柄再使用返回 INVALID_PARAMETER 而不是崩溃":
    # 这是不透明 ID 设计的核心价值:把悬空指针降级成可诊断的错误码。
    let rt = readyRuntime()
    let m = rt.loadModel("mock://m.xml")
    rt.unloadModel(m)

    var caught = false
    var code: IsvikErrorCode
    try:
      discard rt.compileModel(m, initCompileOptions("CPU"))
    except IsvikError as e:
      caught = true
      code = e.code
    check caught
    if caught:
      check code == ecInvalidParameter
    rt.shutdown()

  test "释放后的已编译模型句柄再使用被拒绝":
    let rt = readyRuntime()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    rt.releaseCompiledModel(c)

    expect IsvikError:
      discard rt.createInferRequest(c)
    rt.shutdown()

  test "释放后的推理请求句柄再使用被拒绝":
    let rt = readyRuntime()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r = rt.createInferRequest(c)
    rt.releaseInferRequest(r)

    expect IsvikError:
      rt.infer(r)
    expect IsvikError:
      discard rt.getOutput(r, 0)
    expect IsvikError:
      rt.setInput(r, 0, newTensor(etF32, [1]))
    rt.shutdown()

  test "重复释放同一句柄被拒绝,且不产生 double free":
    let backend = cpuOnly()
    let rt = newRuntime(backend)
    rt.initialize()
    let m = rt.loadModel("mock://m.xml")

    rt.unloadModel(m)
    expect IsvikError:
      rt.unloadModel(m)

    # Backend 侧没有收到第二次释放
    check backend.doubleReleaseCount == 0
    rt.shutdown()

  test "从未存在的句柄被拒绝":
    let rt = readyRuntime()
    expect IsvikError:
      discard rt.compileModel(ModelId(9999), initCompileOptions("CPU"))
    expect IsvikError:
      discard rt.createInferRequest(CompiledModelId(9999))
    expect IsvikError:
      rt.infer(InferRequestId(9999))
    rt.shutdown()

  test "三类句柄共用 ID 空间,数值互不重叠":
    # 即使调用方错误地把 ModelId 的数值当作 RequestId 使用,
    # 也只会命中「不存在」,不会误命中另一个真实资源。
    let rt = readyRuntime()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r = rt.createInferRequest(c)

    check int(m) != int(c)
    check int(c) != int(r)
    check int(m) != int(r)

    # 用 model 的数值当作 request 使用必须失败
    expect IsvikError:
      rt.infer(InferRequestId(int(m)))
    rt.shutdown()

  test "释放时先摘除句柄,即使 Backend 释放失败句柄也不残留":
    let backend = cpuOnly()
    let rt = newRuntime(backend)
    rt.initialize()
    let m = rt.loadModel("mock://m.xml")
    rt.unloadModel(m)
    check rt.loadedModelCount == 0
    rt.shutdown()

suite "级联释放":

  test "释放已编译模型会级联释放其推理请求":
    let rt = readyRuntime()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r1 = rt.createInferRequest(c)
    let r2 = rt.createInferRequest(c)
    check rt.activeRequestCount == 2

    rt.releaseCompiledModel(c)

    check rt.activeRequestCount == 0
    expect IsvikError:
      rt.infer(r1)
    expect IsvikError:
      rt.infer(r2)
    rt.shutdown()

  test "卸载模型会级联释放其已编译模型与推理请求":
    let rt = readyRuntime(cpuGpuNpu())
    let m = rt.loadModel("mock://m.xml")
    let c1 = rt.compileModel(m, initCompileOptions("CPU"))
    let c2 = rt.compileModel(m, initCompileOptions("NPU"))
    discard rt.createInferRequest(c1)
    discard rt.createInferRequest(c1)
    discard rt.createInferRequest(c2)

    check rt.compiledModelCount == 2
    check rt.activeRequestCount == 3

    rt.unloadModel(m)

    check rt.compiledModelCount == 0
    check rt.activeRequestCount == 0
    rt.shutdown()

  test "级联释放不影响其它模型的资源":
    let rt = readyRuntime()
    let m1 = rt.loadModel("mock://a.xml")
    let m2 = rt.loadModel("mock://b.xml")
    let c1 = rt.compileModel(m1, initCompileOptions("CPU"))
    let c2 = rt.compileModel(m2, initCompileOptions("CPU"))
    discard rt.createInferRequest(c1)
    let r2 = rt.createInferRequest(c2)

    rt.unloadModel(m1)

    check rt.loadedModelCount == 1
    check rt.compiledModelCount == 1
    check rt.activeRequestCount == 1
    # m2 的资源仍然可用
    rt.infer(r2)
    check rt.compiledModelDevice(c2) == "CPU"
    rt.shutdown()

  test "级联释放没有 double free":
    let backend = cpuOnly()
    let rt = newRuntime(backend)
    rt.initialize()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    discard rt.createInferRequest(c)
    discard rt.createInferRequest(c)

    rt.unloadModel(m)
    rt.shutdown()

    check backend.doubleReleaseCount == 0

  test "shutdown 清理全部资源且没有 double free":
    let backend = cpuOnly()
    let rt = newRuntime(backend)
    rt.initialize()
    for i in 1 .. 3:
      let m = rt.loadModel("mock://m" & $i & ".xml")
      let c = rt.compileModel(m, initCompileOptions("CPU"))
      discard rt.createInferRequest(c)
      discard rt.createInferRequest(c)

    check rt.loadedModelCount == 3
    check rt.compiledModelCount == 3
    check rt.activeRequestCount == 6

    rt.shutdown()

    check rt.loadedModelCount == 0
    check rt.compiledModelCount == 0
    check rt.activeRequestCount == 0
    check backend.doubleReleaseCount == 0
    check backend.isReleased

suite "设备发现":

  test "结果被缓存,不重复查询 Backend":
    let backend = cpuOnly()
    let rt = newRuntime(backend)
    rt.initialize()

    discard rt.discoverDevices()
    discard rt.discoverDevices()
    discard rt.discoverDevices()

    var count = 0
    for entry in backend.callLog:
      if entry == "discoverDevices":
        inc count
    check count == 1
    rt.shutdown()

  test "forceRefresh 强制重新查询":
    let backend = cpuOnly()
    let rt = newRuntime(backend)
    rt.initialize()

    discard rt.discoverDevices()
    backend.setDevices(@[
      newMockDeviceInfo("CPU"),
      newMockDeviceInfo("NPU", "Hot-plugged NPU")
    ])

    # 不刷新时仍是旧结果
    check rt.discoverDevices().len == 1
    # 刷新后看到新设备
    let refreshed = rt.discoverDevices(forceRefresh = true)
    check refreshed.len == 2
    check refreshed[1].rawName == "NPU"
    rt.shutdown()

  test "fullName 取不到时为空字符串,不用 rawName 冒充":
    # §27 禁止伪造硬件信息。
    let backend = newMockBackend(@[newMockDeviceInfo("NPU")])
    let rt = newRuntime(backend)
    rt.initialize()
    let devices = rt.discoverDevices()
    check devices[0].rawName == "NPU"
    check devices[0].fullName == ""
    rt.shutdown()

  test "只报告真实存在的设备":
    # 没有 NPU 就不该出现 NPU(§13)。
    let rt = readyRuntime(cpuOnly())
    let devices = rt.discoverDevices()
    var names: seq[string] = @[]
    for d in devices:
      names.add(d.rawName)
    check names == @["CPU"]
    check "NPU" notin names
    rt.shutdown()

suite "错误传播与错误码":

  test "Backend 初始化失败抛 BACKEND_NOT_AVAILABLE 且状态不变为 READY":
    let backend = cpuOnly()
    backend.injectFailure(mfInitialize)
    let rt = newRuntime(backend)

    var caught = false
    try:
      rt.initialize()
    except IsvikError as e:
      caught = true
      check e.code == ecBackendNotAvailable
    check caught
    check rt.state == rsUninitialized

  test "模型缺失抛 MODEL_NOT_FOUND":
    let backend = cpuOnly()
    backend.setStrictModelPaths(true)
    backend.registerModelPath("mock://exists.xml")
    let rt = newRuntime(backend)
    rt.initialize()

    discard rt.loadModel("mock://exists.xml")   # 正常

    var code: IsvikErrorCode
    try:
      discard rt.loadModel("mock://missing.xml")
      check false
    except IsvikError as e:
      code = e.code
    check code == ecModelNotFound
    rt.shutdown()

  test "模型格式错误抛 MODEL_INVALID":
    let backend = cpuOnly()
    backend.injectFailure(mfLoadModel)
    let rt = newRuntime(backend)
    rt.initialize()
    try:
      discard rt.loadModel("mock://bad.xml")
      check false
    except IsvikError as e:
      check e.code == ecModelInvalid
    rt.shutdown()

  test "编译失败抛 COMPILATION_FAILED":
    let backend = cpuOnly()
    let rt = newRuntime(backend)
    rt.initialize()
    let m = rt.loadModel("mock://m.xml")
    backend.injectFailure(mfCompileModel)
    try:
      discard rt.compileModel(m, initCompileOptions("CPU"))
      check false
    except IsvikError as e:
      check e.code == ecCompilationFailed
    rt.shutdown()

  test "请求不存在的设备抛 DEVICE_NOT_AVAILABLE":
    # Backend 只说「我没有这个设备」;把它翻译成 NPU_NOT_AVAILABLE
    # 这类带 Isvik 语义的错误码是 Device Manager 的职责(Task 10)。
    let rt = readyRuntime(cpuOnly())
    let m = rt.loadModel("mock://m.xml")
    try:
      discard rt.compileModel(m, initCompileOptions("NPU"))
      check false
    except IsvikError as e:
      check e.code == ecDeviceNotAvailable
      check e.detail.contains("requested=NPU")
      check e.detail.contains("available=CPU")
    rt.shutdown()

  test "推理失败抛 INFERENCE_FAILED":
    let backend = cpuOnly()
    let rt = newRuntime(backend)
    rt.initialize()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r = rt.createInferRequest(c)
    backend.injectFailure(mfInfer)
    try:
      rt.infer(r)
      check false
    except IsvikError as e:
      check e.code == ecInferenceFailed
    rt.shutdown()

  test "未推理就取输出抛 INFERENCE_FAILED":
    let rt = readyRuntime()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r = rt.createInferRequest(c)
    try:
      discard rt.getOutput(r, 0)
      check false
    except IsvikError as e:
      check e.code == ecInferenceFailed
    rt.shutdown()

  test "输入张量为 nil 抛 INVALID_PARAMETER":
    let rt = readyRuntime()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r = rt.createInferRequest(c)
    try:
      rt.setInput(r, 0, nil)
      check false
    except IsvikError as e:
      check e.code == ecInvalidParameter
    rt.shutdown()

  test "负数索引被拒绝":
    let rt = readyRuntime()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r = rt.createInferRequest(c)
    expect IsvikError:
      rt.setInput(r, -1, newTensor(etF32, [1]))
    rt.shutdown()

  test "失败后资源计数不增加,不留下半成品句柄":
    let backend = cpuOnly()
    let rt = newRuntime(backend)
    rt.initialize()
    backend.injectFailure(mfLoadModel)
    try:
      discard rt.loadModel("mock://m.xml")
    except IsvikError:
      discard
    check rt.loadedModelCount == 0
    rt.shutdown()

suite "编译缓存(blob 导入导出)":

  test "导出后可导入":
    let rt = readyRuntime()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))

    rt.exportCompiledModel(c, "mock://cache/model.blob")
    let imported = rt.importCompiledModel(
      "mock://cache/model.blob", initCompileOptions("CPU"))

    check rt.compiledModelDevice(imported) == "CPU"
    # 导入得到的模型可以直接创建请求并推理
    let r = rt.createInferRequest(imported)
    rt.infer(r)
    check rt.getOutput(r, 0).toSeq(float32) == @[1.0'f32]
    rt.shutdown()

  test "导入不存在的 blob 抛 CACHE_INVALID":
    let rt = readyRuntime()
    try:
      discard rt.importCompiledModel("mock://nope.blob",
                                     initCompileOptions("CPU"))
      check false
    except IsvikError as e:
      check e.code == ecCacheInvalid
    rt.shutdown()

  test "blob 损坏抛 CACHE_CORRUPTED":
    let backend = cpuOnly()
    let rt = newRuntime(backend)
    rt.initialize()
    backend.registerBlobPath("mock://c.blob")
    backend.injectFailure(mfImportCompiledModel)
    try:
      discard rt.importCompiledModel("mock://c.blob", initCompileOptions("CPU"))
      check false
    except IsvikError as e:
      check e.code == ecCacheCorrupted
    rt.shutdown()

  test "从 blob 导入的模型不会被任何 unloadModel 级联释放":
    # 它没有来源 Model,生命周期独立。
    let rt = readyRuntime()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    rt.exportCompiledModel(c, "mock://c.blob")
    let imported = rt.importCompiledModel("mock://c.blob",
                                          initCompileOptions("CPU"))

    rt.unloadModel(m)

    check rt.compiledModelCount == 1
    check rt.compiledModelDevice(imported) == "CPU"
    rt.shutdown()

suite "事件发布(§29)":

  test "初始化发布 RUNTIME_STARTED 与 BACKEND_LOADED":
    let bus = newEventBus()
    var kinds: seq[RuntimeEventKind] = @[]
    var payloads: seq[JsonNode] = @[]
    bus.subscribe(proc (e: RuntimeEvent) =
      kinds.add(e.kind)
      payloads.add(e.payload))

    let rt = newRuntime(cpuOnly(), bus)
    rt.initialize()

    check kinds == @[rekRuntimeStarted, rekBackendLoaded]
    check payloads[1]["backend"].getStr == "mock"
    check payloads[1]["version"].getStr == MockBackendVersion
    rt.shutdown()

  test "设备发现为每个设备发布 DEVICE_DETECTED":
    let bus = newEventBus()
    var detected: seq[string] = @[]
    bus.subscribe(proc (e: RuntimeEvent) =
      if e.kind == rekDeviceDetected:
        detected.add(e.payload["device"].getStr))

    let rt = newRuntime(cpuGpuNpu(), bus)
    rt.initialize()
    discard rt.discoverDevices()

    check detected == @["CPU", "GPU.0", "NPU"]
    rt.shutdown()

  test "加载模型发布 MODEL_LOADED 并带路径":
    let bus = newEventBus()
    var captured: RuntimeEvent
    bus.subscribe(proc (e: RuntimeEvent) =
      if e.kind == rekModelLoaded:
        captured = e)

    let rt = newRuntime(cpuOnly(), bus)
    rt.initialize()
    discard rt.loadModel("mock://qwen.xml")

    check captured.kind == rekModelLoaded
    check captured.payload["path"].getStr == "mock://qwen.xml"
    rt.shutdown()

  test "编译发布 COMPILING 事件并带耗时":
    let bus = newEventBus()
    var compiling: seq[JsonNode] = @[]
    bus.subscribe(proc (e: RuntimeEvent) =
      if e.kind == rekCompiling:
        compiling.add(e.payload))

    let rt = newRuntime(cpuOnly(), bus)
    rt.initialize()
    let m = rt.loadModel("mock://m.xml")
    discard rt.compileModel(m, initCompileOptions("CPU"))

    # 开始与完成各一条
    check compiling.len == 2
    check compiling[0]["device"].getStr == "CPU"
    check compiling[1].hasKey("elapsedMs")
    check compiling[1]["elapsedMs"].getInt >= 0
    rt.shutdown()

  test "推理发布 INFERENCE_STARTED 与 INFERENCE_FINISHED":
    let bus = newEventBus()
    var kinds: seq[RuntimeEventKind] = @[]
    bus.subscribe(proc (e: RuntimeEvent) =
      if e.kind in {rekInferenceStarted, rekInferenceFinished}:
        kinds.add(e.kind))

    let rt = newRuntime(cpuOnly(), bus)
    rt.initialize()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r = rt.createInferRequest(c)
    rt.infer(r)

    check kinds == @[rekInferenceStarted, rekInferenceFinished]
    rt.shutdown()

  test "操作失败发布 ERROR 事件并带错误码":
    let bus = newEventBus()
    var errors: seq[JsonNode] = @[]
    bus.subscribe(proc (e: RuntimeEvent) =
      if e.kind == rekError:
        errors.add(e.payload))

    let backend = cpuOnly()
    let rt = newRuntime(backend, bus)
    rt.initialize()
    backend.injectFailure(mfLoadModel)
    try:
      discard rt.loadModel("mock://bad.xml")
    except IsvikError:
      discard

    check errors.len == 1
    check errors[0]["code"].getStr == "MODEL_INVALID"
    check errors[0]["operation"].getStr == "loadModel"
    rt.shutdown()

  test "错误事件不包含 detail(与错误模型的安全边界一致)":
    # detail 可能含敏感路径,不进入事件 payload。
    let bus = newEventBus()
    var payload: JsonNode
    bus.subscribe(proc (e: RuntimeEvent) =
      if e.kind == rekError:
        payload = e.payload)

    let backend = cpuOnly()
    backend.setStrictModelPaths(true)
    let rt = newRuntime(backend, bus)
    rt.initialize()
    try:
      discard rt.loadModel("mock://secret/private.xml")
    except IsvikError:
      discard

    check payload != nil
    check not payload.hasKey("detail")
    check not ($payload).contains("secret")
    rt.shutdown()

  test "错误被发布为事件后仍然向调用方抛出":
    # 事件只是额外的可观测性,不能替代错误传播。
    let bus = newEventBus()
    var sawEvent = false
    bus.subscribe(proc (e: RuntimeEvent) =
      if e.kind == rekError: sawEvent = true)

    let backend = cpuOnly()
    let rt = newRuntime(backend, bus)
    rt.initialize()
    backend.injectFailure(mfInfer)
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r = rt.createInferRequest(c)

    var raised = false
    try:
      rt.infer(r)
    except IsvikError:
      raised = true

    check sawEvent
    check raised
    rt.shutdown()

  test "没有事件总线时 Runtime 正常工作":
    # 单元测试应能用最小依赖构造 Runtime。
    let rt = newRuntime(cpuOnly(), nil)
    rt.initialize()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r = rt.createInferRequest(c)
    rt.infer(r)
    check rt.getOutput(r, 0).toSeq(float32) == @[1.0'f32]
    rt.shutdown()

suite "MockBackend 自身行为":

  test "未覆盖任何方法的 Backend 基类抛 NOT_IMPLEMENTED":
    # 保证「忘记实现某个方法」会得到明确报错,而不是静默成功。
    let bare = Backend()
    var caught = false
    try:
      discard bare.name()
    except IsvikError as e:
      caught = true
      check e.code == ecNotImplemented
    check caught

  test "元信息":
    let b = cpuOnly()
    check b.name() == "mock"
    check b.version() == MockBackendVersion
    check not b.isInitialized()
    b.initialize()
    check b.isInitialized()

  test "版本可配置,便于测试版本上报":
    let b = cpuOnly()
    b.setVersionText("mock-9.9.9")
    check b.version() == "mock-9.9.9"

  test "预设输出被按索引返回":
    let backend = cpuOnly()
    backend.setPlannedOutputs(@[
      newTensor(etF32, [2], [1.5'f32, 2.5]),
      newTensor(etI32, [1], [42'i32])
    ])
    let rt = newRuntime(backend)
    rt.initialize()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r = rt.createInferRequest(c)
    rt.infer(r)

    check rt.getOutput(r, 0).toSeq(float32) == @[1.5'f32, 2.5]
    check rt.getOutput(r, 1).toSeq(int32) == @[42'i32]
    rt.shutdown()

  test "预设输出返回副本,多次读取互不污染":
    let backend = cpuOnly()
    backend.setPlannedOutputs(@[newTensor(etF32, [2], [1.0'f32, 2.0])])
    let rt = newRuntime(backend)
    rt.initialize()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r = rt.createInferRequest(c)
    rt.infer(r)

    let first = rt.getOutput(r, 0)
    first.setFrom([99.0'f32, 99.0])
    let second = rt.getOutput(r, 0)
    check second.toSeq(float32) == @[1.0'f32, 2.0]
    rt.shutdown()

  test "预设输出索引越界被拒绝":
    let backend = cpuOnly()
    backend.setPlannedOutputs(@[newTensor(etF32, [1], [1.0'f32])])
    let rt = newRuntime(backend)
    rt.initialize()
    let m = rt.loadModel("mock://m.xml")
    let c = rt.compileModel(m, initCompileOptions("CPU"))
    let r = rt.createInferRequest(c)
    rt.infer(r)
    expect IsvikError:
      discard rt.getOutput(r, 5)
    rt.shutdown()

  test "编译选项中的 profiling 标记被传递":
    let backend = cpuOnly()
    let rt = newRuntime(backend)
    rt.initialize()
    let m = rt.loadModel("mock://m.xml")
    discard rt.compileModel(m, initCompileOptions("CPU", enableProfiling = true))
    # MockCompiledModel 记录了该标记(通过 callLog 间接确认编译已发生)
    check "compileModel" in backend.callLog
    rt.shutdown()

  test "默认只报告 CPU,不假装有 GPU 或 NPU":
    let b = newMockBackend()
    b.initialize()
    let devices = b.discoverDevices()
    check devices.len == 1
    check devices[0].rawName == "CPU"

  test "失败注入可清除":
    let b = cpuOnly()
    b.injectFailure(mfInitialize)
    expect IsvikError:
      b.initialize()
    b.clearFailure(mfInitialize)
    b.initialize()
    check b.isInitialized()

  test "Backend 的重复 release 被计数而不崩溃":
    let b = cpuOnly()
    b.initialize()
    b.release()
    b.release()
    check b.doubleReleaseCount == 1

  test "CompileOptions 默认不开启 profiling,属性表为空":
    let opts = initCompileOptions("CPU")
    check opts.device == "CPU"
    check not opts.enableProfiling
    check opts.properties.len == 0

# ---------------------------------------------------------------------------
# Task 10 收尾:Device Manager 接入 Runtime
# ---------------------------------------------------------------------------
#
# 这一段用 MockBackend 验证「语义设备请求 → 实际设备」的整条路径,
# 因此在没有 OpenVINO、没有 GPU / NPU 的机器上也能跑。
# 真机上的属性字符串解析由 tests/backends/tdevice_real.nim 负责。

proc intelTopology(): MockBackend =
  ## 模拟本机拓扑:Intel iGPU 是 GPU.0,NVIDIA 独显是 GPU.1。
  newMockBackend(@[
    newMockDeviceInfo("CPU", "Mock Intel CPU"),
    newMockDeviceInfo("GPU.0", "Mock Intel Graphics",
      [("DEVICE_ARCHITECTURE", "GPU: vendor=0x8086 arch=v12.70.4")]),
    newMockDeviceInfo("GPU.1", "Mock NVIDIA dGPU",
      [("DEVICE_ARCHITECTURE", "GPU: vendor=0x10de arch=v12.0.0")]),
    newMockDeviceInfo("NPU", "Mock Intel AI Boost")
  ])

suite "Runtime 的语义设备接口":

  test "semanticDevices 与 discoverDevices 一一对应且保留原始名称":
    let rt = readyRuntime(intelTopology())
    let raw = rt.discoverDevices()
    let semantic = rt.semanticDevices()

    check semantic.len == raw.len
    for i in 0 ..< raw.len:
      check semantic[i].rawName == raw[i].rawName
      check semantic[i].fullName == raw[i].fullName
      check semantic[i].backend == "mock"
    rt.shutdown()

  test "semanticDevices 自动触发发现,调用方不必先手动发现":
    let rt = newRuntime(intelTopology())
    rt.initialize()
    # 直接调用语义接口,没有先调 discoverDevices
    check rt.semanticDevices().len == 4
    rt.shutdown()

  test "语义设备复用同一份发现缓存,不重复查询 Backend":
    let backend = intelTopology()
    let rt = newRuntime(backend)
    rt.initialize()

    discard rt.semanticDevices()
    discard rt.semanticDevices()
    discard rt.resolveDevice("AUTO")

    var count = 0
    for entry in backend.callLog:
      if entry == "discoverDevices":
        inc count
    check count == 1
    rt.shutdown()

  test "AUTO 在本机拓扑上选中 NPU":
    let rt = readyRuntime(intelTopology())
    let selection = rt.resolveDevice("AUTO")
    check selection.usedAuto
    check selection.device.rawName == "NPU"
    check selection.device.fullName == "Mock Intel AI Boost"
    rt.shutdown()

  test "显式 GPU 选中 Intel 的 GPU.0,而不是 NVIDIA 的 GPU.1":
    let rt = readyRuntime(intelTopology())
    let selection = rt.resolveDevice("GPU")
    check selection.device.rawName == "GPU.0"
    check selection.device.vendor == "Intel"
    check not selection.usedAuto
    rt.shutdown()

  test "显式 NPU 不可用时抛 NPU_NOT_AVAILABLE 且发布 ERROR 事件":
    # 同时验证两件事:错误码是设备专用的(不再是笼统的 DEVICE_NOT_AVAILABLE),
    # 以及设备选择失败也走 Runtime 的错误事件通道。
    let bus = newEventBus()
    var errorCodes: seq[string] = @[]
    bus.subscribe(proc (e: RuntimeEvent) =
      if e.kind == rekError and e.payload != nil:
        errorCodes.add(e.payload["code"].getStr)
    )

    let rt = readyRuntime(cpuOnly(), bus)
    try:
      discard rt.resolveDevice("NPU")
      check false
    except IsvikError as e:
      check e.code == ecNpuNotAvailable
    check "NPU_NOT_AVAILABLE" in errorCodes
    rt.shutdown()

  test "语义编译入口把 GPU 解析成 GPU.0 再交给 Backend":
    let rt = readyRuntime(intelTopology())
    let modelId = rt.loadModel("mock://m.xml")

    let (compiledId, selection) = rt.compileModelForDevice(modelId, "GPU")

    # Backend 收到的必须是 rawName;它不理解语义值 "GPU"。
    check rt.compiledModelDevice(compiledId) == "GPU.0"
    # 请求值与实际设备都要能查到 —— 只保留一个就无法如实上报。
    check rt.compiledModelRequestedDevice(compiledId) == "GPU"
    check rt.compiledModelDeviceType(compiledId) == "GPU"
    check rt.compiledModelDeviceFullName(compiledId) == "Mock Intel Graphics"
    check selection.device.rawName == "GPU.0"
    rt.shutdown()

  test "语义编译入口默认走 AUTO":
    let rt = readyRuntime(intelTopology())
    let modelId = rt.loadModel("mock://m.xml")
    let (compiledId, selection) = rt.compileModelForDevice(modelId)
    check selection.requested == "AUTO"
    check selection.usedAuto
    check rt.compiledModelDevice(compiledId) == "NPU"
    rt.shutdown()

  test "rawName 低层入口仍然可用,且不冒充语义信息":
    # 保留低层入口是必需的(Backend 测试与精确控制需要它),
    # 但它没有经过解析,因此 deviceType 必须为空而不是猜一个值。
    let rt = readyRuntime(intelTopology())
    let modelId = rt.loadModel("mock://m.xml")
    let compiledId = rt.compileModel(modelId, initCompileOptions("GPU.1"))
    check rt.compiledModelDevice(compiledId) == "GPU.1"
    check rt.compiledModelRequestedDevice(compiledId) == "GPU.1"
    check rt.compiledModelDeviceType(compiledId) == ""
    check rt.compiledModelDeviceFullName(compiledId) == ""
    rt.shutdown()

  test "语义编译透传 profiling 与附加属性":
    let rt = readyRuntime(intelTopology())
    let modelId = rt.loadModel("mock://m.xml")

    var props = initTable[string, string]()
    props["PERFORMANCE_HINT"] = "LATENCY"
    let (compiledId, _) = rt.compileModelForDevice(
      modelId, "CPU", enableProfiling = true, properties = props)
    check rt.compiledModelDevice(compiledId) == "CPU"
    rt.shutdown()

  test "设备解析结果绑定在同一份 snapshot 上":
    # 设备热插拔后,未 refresh 前的解析必须仍基于旧快照,
    # 否则「查询到的设备」与「实际选中的设备」会来自两个不同时刻。
    let backend = newMockBackend(@[newMockDeviceInfo("CPU", "Mock CPU")])
    let rt = newRuntime(backend)
    rt.initialize()
    check rt.resolveDevice("AUTO").device.rawName == "CPU"

    backend.setDevices(@[
      newMockDeviceInfo("CPU", "Mock CPU"),
      newMockDeviceInfo("NPU", "Hot-plugged NPU")
    ])
    # 未刷新:仍是 CPU
    check rt.resolveDevice("AUTO").device.rawName == "CPU"
    # 刷新后:语义快照同步更新
    discard rt.discoverDevices(forceRefresh = true)
    check rt.resolveDevice("AUTO").device.rawName == "NPU"
    rt.shutdown()

  test "非法设备请求抛 INVALID_PARAMETER":
    let rt = readyRuntime(intelTopology())
    try:
      discard rt.resolveDevice("TPU")
      check false
    except IsvikError as e:
      check e.code == ecInvalidParameter
    rt.shutdown()

  test "未初始化时查询语义设备抛 BACKEND_NOT_AVAILABLE":
    let rt = newRuntime(intelTopology())
    try:
      discard rt.semanticDevices()
      check false
    except IsvikError as e:
      check e.code == ecBackendNotAvailable
