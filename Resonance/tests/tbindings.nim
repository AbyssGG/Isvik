## Resonance 绑定层测试
##
## 这是 Resonance 的第一个测试(其 ROADMAP v0.2 的待办项)。
##
## ---
##
## ## 测试分成两类,原因很实际
##
## 1. **不需要 openvino_c.dll 的测试**:枚举数值是否与官方头文件一致、
##    ABI shim 是否能编译并被调用、常量是否正确。这些必须在任何机器上都能跑。
## 2. **需要 openvino_c.dll 的测试**:真实取版本号、真实取设备属性。
##    DLL 缺失时这些用例**跳过并明确说明**,而不是假装通过。
##
## 第 1 类占绝大多数,而且恰好覆盖了最危险的部分 —— 枚举数值错配不会
## 报错,只会静默产生错误结果。
##
## ---
##
## ## 枚举数值为什么必须逐个硬编码断言
##
## `ov_element_type_e` 的数值在 OpenVINO 版本之间会变(见 c_api.nim 顶部表格)。
## 用循环「自己和自己比」毫无意义;只有把官方头文件里的数字逐个写进断言,
## 才能在有人改动枚举、或升级目标版本时立刻发现。

import std/[unittest, strutils, os]

import resonance

let openVinoUsable = tryLoadOpenVino()
let openVinoProbeError = openVinoLoadError()
  ## 探测结果。
  ##
  ## `tryLoadOpenVino` 既不终止进程也不抛异常,因此这两行可以安全地在模块
  ## 顶层执行 —— 这正是把绑定改为手动加载所换来的能力。
  ## 改造之前,仅仅 import 这个模块就会让进程在 DLL 缺失时直接退出,
  ## 连第一个测试都跑不到。

suite "ov_status_e 与官方头文件一致(OpenVINO 2026.3)":

  test "全部 18 个状态码的数值逐个匹配":
    # 数值取自 src/bindings/c/include/openvino/c/ov_common.h
    #
    # 注意 `OK` 必须写成 `OvStatus.OK`:unittest 的 TestStatus 枚举也有 OK,
    # 不加限定会报 ambiguous identifier。
    check ord(OvStatus.OK) == 0
    check ord(GENERAL_ERROR) == -1
    check ord(NOT_IMPLEMENTED) == -2
    check ord(NETWORK_NOT_LOADED) == -3
    check ord(PARAMETER_MISMATCH) == -4
    check ord(NOT_FOUND) == -5
    check ord(OUT_OF_BOUNDS) == -6
    check ord(UNEXPECTED) == -7
    check ord(REQUEST_BUSY) == -8
    check ord(RESULT_NOT_READY) == -9
    check ord(NOT_ALLOCATED) == -10
    check ord(INFER_NOT_STARTED) == -11
    check ord(NETWORK_NOT_READ) == -12
    check ord(INFER_CANCELLED) == -13
    check ord(INVALID_C_PARAM) == -14
    check ord(UNKNOWN_C_ERROR) == -15
    check ord(NOT_IMPLEMENT_C_METHOD) == -16
    check ord(UNKNOW_EXCEPTION) == -17

  test "状态码总数为 18":
    # OvStatus 的值是递减的(0, -1, ... -17),在 Nim 中构成 holey enum,
    # 不满足 Ordinal 约束,因此无法用 `for x in OvStatus` 迭代。
    # 显式列出全部值反而更好:新增枚举值时必须同时更新这里,
    # 从而不会悄悄漏掉。
    const allStatuses = [
      OvStatus.OK, GENERAL_ERROR, NOT_IMPLEMENTED, NETWORK_NOT_LOADED,
      PARAMETER_MISMATCH, NOT_FOUND, OUT_OF_BOUNDS, UNEXPECTED,
      REQUEST_BUSY, RESULT_NOT_READY, NOT_ALLOCATED, INFER_NOT_STARTED,
      NETWORK_NOT_READ, INFER_CANCELLED, INVALID_C_PARAM, UNKNOWN_C_ERROR,
      NOT_IMPLEMENT_C_METHOD, UNKNOW_EXCEPTION
    ]
    check allStatuses.len == 18

    # 数值两两不同
    for i in 0 ..< allStatuses.len:
      for j in (i + 1) ..< allStatuses.len:
        check ord(allStatuses[i]) != ord(allStatuses[j])

  test "C wrapper 层的四个状态码存在":
    # 这四个由 C 封装层自身抛出,其中 INVALID_C_PARAM 在参数错误时很常见。
    # 若枚举里没有它们,从 C 返回该值会让 `$status` 与 case 语句失效。
    check ord(INVALID_C_PARAM) == -14
    check ord(UNKNOWN_C_ERROR) == -15
    check ord(NOT_IMPLEMENT_C_METHOD) == -16
    check ord(UNKNOW_EXCEPTION) == -17

suite "ov_element_type_e 与官方头文件一致(OpenVINO 2026.3)":

  test "全部 26 个元素类型的数值逐个匹配":
    # 数值取自 OpenVINO 2026.3 的 ov_common.h。
    # 2026.3 移除了 UNDEFINED 这个名字,值 0 现在叫 DYNAMIC。
    check ord(DYNAMIC) == 0
    check ord(BOOLEAN) == 1
    check ord(BF16) == 2
    check ord(F16) == 3
    check ord(F32) == 4
    check ord(F64) == 5
    check ord(I4) == 6
    check ord(I8) == 7
    check ord(I16) == 8
    check ord(I32) == 9
    check ord(I64) == 10
    check ord(U1) == 11
    check ord(U2) == 12
    check ord(U3) == 13
    check ord(U4) == 14
    check ord(U6) == 15
    check ord(U8) == 16
    check ord(U16) == 17
    check ord(U32) == 18
    check ord(U64) == 19
    check ord(NF4) == 20
    check ord(F8E4M3) == 21
    check ord(F8E5M3) == 22
    check ord(STRING) == 23
    check ord(F4E2M1) == 24
    check ord(F8E8M0) == 25

  test "DYNAMIC 与两个兼容别名指向同一个值":
    # 2026.3 移除了 UNDEFINED 这个名字,值 0 只叫 DYNAMIC。
    # 2025.4 及更早的头文件写的是 `DYNAMIC = UNDEFINED`(两者同为 0),
    # Nim 枚举不允许重复值,所以枚举里只能留一个名字,
    # 另外两个拼写以常量别名形式提供,使按旧名写的代码仍然正确。
    check ord(DYNAMIC) == 0
    check ord(OvElementTypeDynamic) == 0
    check ord(OvElementTypeUndefined) == 0
    check OvElementTypeDynamic == DYNAMIC
    check OvElementTypeUndefined == DYNAMIC

  test "U2 / U3 / U6 存在":
    # 这三个类型在 2023.x 中不存在,是 2025.x 新增的。
    # 缺少它们会让 U4 及之后的所有类型数值偏移,
    # 其中 U8 偏移的后果最严重 —— 图像输入几乎都是 U8。
    check ord(U2) == 12
    check ord(U3) == 13
    check ord(U6) == 15

  test "U8 的数值是 16,不是 13":
    # 这是一个具体的回归防护。此前的绑定把 U8 写成 13,
    # 而 13 在 2025.x 中实际是 U3 —— 张量会被静默按错误类型解释。
    check ord(U8) == 16
    check ord(U8) != 13

  test "元素类型总数为 26":
    var count = 0
    for _ in OvElementType:
      inc count
    check count == 26

suite "属性键常量":

  test "常用属性键的字面量正确":
    check OvPropertyKeyEnableProfiling == "PERF_COUNT"
    check OvPropertyKeyFullDeviceName == "FULL_DEVICE_NAME"
    check OvPropertyKeySupportedProperties == "SUPPORTED_PROPERTIES"
    check OvPropertyKeyAvailableDevices == "AVAILABLE_DEVICES"
    check OvPropertyKeyDeviceArchitecture == "DEVICE_ARCHITECTURE"
    check OvPropertyKeyCacheDir == "CACHE_DIR"
    check OvPropertyKeyPerformanceHint == "PERFORMANCE_HINT"
    check OvPropertyKeyNumStreams == "NUM_STREAMS"

  test "属性键全部为大写加下划线":
    for key in [OvPropertyKeyEnableProfiling, OvPropertyKeyFullDeviceName,
                OvPropertyKeySupportedProperties, OvPropertyKeyAvailableDevices,
                OvPropertyKeyDeviceArchitecture, OvPropertyKeyDeviceType,
                OvPropertyKeyOptimalNumberOfInferRequests,
                OvPropertyKeyCacheDir, OvPropertyKeyPerformanceHint,
                OvPropertyKeyNumStreams,
                OvPropertyKeyInferencePrecisionHint]:
      check key.len > 0
      check key.allCharsInSet({'A'..'Z', '_', '0'..'9'})

suite "ABI shim 可编译并可调用(不需要 openvino_c.dll)":

  test "nv_max_property_pairs 返回正数上限":
    # 这个调用不触碰 openvino_c.dll,只验证 C shim 真的被编译进来且可调用。
    # 它同时是「shim 链接成功」的最小证据。
    let limit = maxPropertyPairs()
    check limit > 0
    check limit == 8

  test "上限足够覆盖当前所有调用点的需求":
    # 目前最多同时传 CACHE_DIR + PERFORMANCE_HINT + PERF_COUNT。
    check maxPropertyPairs() >= 4

suite "运行时加载不会终止进程":

  test "仅导入本模块不会因 DLL 缺失而退出":
    # 这个用例的存在本身就是证明:如果绑定仍使用 {.dynlib.},
    # 进程会在模块初始化阶段打印 "could not load: openvino_c.dll" 并退出,
    # 这一行永远不会被执行到。
    check true

  test "tryLoadOpenVino 可重复调用且结果一致":
    let first = tryLoadOpenVino()
    let second = tryLoadOpenVino()
    check first == second
    check second == isOpenVinoLoaded()

  test "加载失败时有可读的原因,成功时原因为空":
    if isOpenVinoLoaded():
      check openVinoLoadError() == ""
    else:
      check openVinoLoadError().len > 0

  test "报告探测结果(信息性,不判定成败)":
    # 把环境事实写进测试输出,使日志能自证「后面的用例为什么被跳过」。
    if openVinoUsable:
      checkpoint("openvino_c.dll 可用")
    else:
      checkpoint("openvino_c.dll 不可用:" & openVinoProbeError)
      checkpoint("NOT TESTED IN CURRENT ENVIRONMENT")
    check true

  test "未加载时调用 ov_* 抛可捕获异常,而不是终止进程":
    if isOpenVinoLoaded():
      skip()
    else:
      var caught = false
      try:
        var core: ptr OvCore = nil
        discard ov_core_create(addr core)
      except OpenVinoUnavailableError as e:
        caught = true
        check e.msg.contains("not available")
      check caught

  test "未加载时释放类函数是无操作,不崩溃":
    # 析构器里会调用这些函数,它们必须在任何状态下都安全。
    if isOpenVinoLoaded():
      skip()
    else:
      ov_core_free(nil)
      ov_model_free(nil)
      ov_tensor_free(nil)
      ov_free(nil)
      check ov_get_last_err_msg() == nil
      check true

suite "需要 openvino_c.dll 的真实调用":

  test "取得 OpenVINO Runtime 版本":
    if not openVinoUsable:
      skip()
    else:
      let version = getOpenVinoVersion()
      checkpoint("buildNumber=" & version.buildNumber)
      # 枚举数值是按 2026.3 的头文件抄的。若实际运行的不是 2026.x,
      # 上面那些逐值断言的前提就不成立了 —— 显式提示而不是静默通过。
      if not version.buildNumber.startsWith("2026."):
        checkpoint("警告:绑定按 OpenVINO 2026.3 转写,当前运行时为 " &
                   version.buildNumber & ",元素类型数值可能不一致")
      checkpoint("description=" & version.description)
      check version.buildNumber.len > 0
      # 版本号形如 "2026.3.0-22451-8a17657b995-releases/2026/3"(本机实测)
      check version.buildNumber.contains(".")
      check ($version).len > 0

  test "创建 Core 并枚举设备":
    if not openVinoUsable:
      skip()
    else:
      let core = newCore()
      let devices = core.getAvailableDevices()
      checkpoint("devices=" & devices.join(", "))
      # 任何可用的 OpenVINO 安装至少应报告 CPU。
      check devices.len > 0

  test "取得 CPU 的 FULL_DEVICE_NAME":
    if not openVinoUsable:
      skip()
    else:
      let core = newCore()
      let fullName = core.getFullDeviceName("CPU")
      checkpoint("CPU FULL_DEVICE_NAME=" & fullName)
      # 取不到时返回空字符串,不用 "CPU" 冒充。
      if fullName.len == 0:
        checkpoint("该设备未报告 FULL_DEVICE_NAME")
      check true

  test "查询不支持的属性时 tryGetProperty 返回回落值":
    if not openVinoUsable:
      skip()
    else:
      let core = newCore()
      let value = core.tryGetProperty("CPU", "DEFINITELY_NOT_A_REAL_PROPERTY",
                                     "fallback")
      check value == "fallback"

  test "查询不支持的属性时 getProperty 抛异常":
    if not openVinoUsable:
      skip()
    else:
      let core = newCore()
      var raised = false
      try:
        discard core.getProperty("CPU", "DEFINITELY_NOT_A_REAL_PROPERTY")
      except OpenVinoError:
        raised = true
      check raised

# ---------------------------------------------------------------------------
# 多属性编译:需要 openvino_c.dll 与一个真实模型
# ---------------------------------------------------------------------------
#
# 为什么单独一个 suite:这条路径要经过 ABI shim 转给变参的
# `ov_core_compile_model`,而变参调用的正确性无法靠读代码确认 —— 只能真机跑。
#
# 此前这条路径只在「1 个属性对」下有过证据。多于一对时,shim 里的循环与
# `property_args_size = 2 * pair_count` 的算法都没被验证过。这个数字传错的
# 后果是 `-14 INVALID_C_PARAM`,而错误信息里不会提到真正的原因(OpenVINO
# 内部只做了一个 `property_args_size % 2 != 0` 的偶数校验)。
#
# 模型通过环境变量提供,而不是硬编码路径 —— 硬编码某台机器的路径会让这个
# 测试在别处永远失败或永远跳过,两种都没有价值:
#
#   RESONANCE_TEST_MODEL_XML   IR 的 .xml 路径
#   RESONANCE_TEST_MODEL_BIN   IR 的 .bin 路径(可省略,默认同名 .bin)
#
# 未提供时整个 suite 跳过,并在输出里说明如何启用 —— 不把「没测」显示成「测过」。

let testModelXml = getEnv("RESONANCE_TEST_MODEL_XML")
let testModelBin =
  if getEnv("RESONANCE_TEST_MODEL_BIN").len > 0:
    getEnv("RESONANCE_TEST_MODEL_BIN")
  elif testModelXml.len > 0:
    testModelXml.changeFileExt("bin")
  else:
    ""

let modelUsable =
  openVinoUsable and testModelXml.len > 0 and
  fileExists(testModelXml) and fileExists(testModelBin)

suite "多属性编译(需要 openvino_c.dll 与真实模型)":

  test "报告模型探测结果(信息性,不判定成败)":
    if testModelXml.len == 0:
      checkpoint("未设置 RESONANCE_TEST_MODEL_XML,本 suite 将全部跳过")
      checkpoint("启用方式:set RESONANCE_TEST_MODEL_XML=<某个 IR 的 .xml 路径>")
    elif not fileExists(testModelXml):
      checkpoint("RESONANCE_TEST_MODEL_XML 指向的文件不存在:" & testModelXml)
    elif not fileExists(testModelBin):
      checkpoint("对应的 .bin 不存在:" & testModelBin)
    else:
      checkpoint("模型可用:" & testModelXml)
    check true

  test "0 个属性对可编译(基线)":
    if not modelUsable:
      skip()
    else:
      let core = newCore()
      let model = core.readModel(testModelXml, testModelBin)
      let compiled = core.compileModelWithProperties(model, "CPU", [])
      # 编译返回成功不等于产物可用,再创建一个 infer request 证明它真能用。
      discard compiled.createInferRequest()
      check true

  test "1 个属性对可编译":
    if not modelUsable:
      skip()
    else:
      let core = newCore()
      let model = core.readModel(testModelXml, testModelBin)
      let compiled = core.compileModelWithProperties(
        model, "CPU", [(OvPropertyKeyEnableProfiling, "YES")])
      discard compiled.createInferRequest()
      check true

  test "2 个属性对可编译":
    if not modelUsable:
      skip()
    else:
      let core = newCore()
      let model = core.readModel(testModelXml, testModelBin)
      let compiled = core.compileModelWithProperties(model, "CPU", [
        (OvPropertyKeyEnableProfiling, "YES"),
        (OvPropertyKeyPerformanceHint, "LATENCY")
      ])
      discard compiled.createInferRequest()
      check true

  test "4 个属性对可编译":
    # 这条是本 suite 存在的主要理由:证明 shim 的属性对循环与
    # property_args_size 的算法在多于一对时也正确。
    if not modelUsable:
      skip()
    else:
      let core = newCore()
      let model = core.readModel(testModelXml, testModelBin)
      let compiled = core.compileModelWithProperties(model, "CPU", [
        (OvPropertyKeyEnableProfiling, "YES"),
        (OvPropertyKeyPerformanceHint, "LATENCY"),
        (OvPropertyKeyNumStreams, "1"),
        (OvPropertyKeyInferencePrecisionHint, "f32")
      ])
      discard compiled.createInferRequest()
      check true

  test "超过 shim 上限时显式报错,不静默丢弃属性":
    # 静默丢弃比报错糟糕得多:调用方会以为属性生效了。
    # 这条不需要真实模型也能触发(上限检查在调用 shim 之前),
    # 但需要 Core 与 Model 才能走到那一步,所以仍归在本 suite。
    if not modelUsable:
      skip()
    else:
      let core = newCore()
      let model = core.readModel(testModelXml, testModelBin)
      var tooMany: seq[(string, string)] = @[]
      for i in 0 .. maxPropertyPairs():
        tooMany.add((OvPropertyKeyEnableProfiling, "YES"))
      checkpoint("传入 " & $tooMany.len & " 对,上限 " & $maxPropertyPairs())
      var raised = false
      try:
        discard core.compileModelWithProperties(model, "CPU", tooMany)
      except OpenVinoError:
        raised = true
      check raised

# ---------------------------------------------------------------------------
# Bind by name, and port introspection
# ---------------------------------------------------------------------------
#
# Why this suite exists: a KV-cache model has dozens of inputs whose *indices*
# are an implementation detail of the graph. Binding by index means hardcoding
# an ordering that can change between exports, and the failure mode is silent
# (inference succeeds, tokens are wrong). These tests establish that names can
# be discovered and used.

suite "Port introspection (requires openvino_c.dll and a real model)":

  test "reports probe result (informational, not a verdict)":
    if not modelUsable:
      checkpoint("model not available; this suite is skipped")
    else:
      checkpoint("model: " & testModelXml)
    check true

  test "input and output counts are positive":
    if not modelUsable:
      skip()
    else:
      let core = newCore()
      let model = core.readModel(testModelXml, testModelBin)
      let compiled = core.compileModelWithProperties(model, "CPU", [])
      check compiled.inputCount > 0
      check compiled.outputCount > 0
      checkpoint("inputs=" & $compiled.inputCount &
                 " outputs=" & $compiled.outputCount)

  test "every port reports a non-empty name":
    # An empty name would make binding by name impossible, and the failure
    # would only show up much later as "port not found".
    if not modelUsable:
      skip()
    else:
      let core = newCore()
      let model = core.readModel(testModelXml, testModelBin)
      let compiled = core.compileModelWithProperties(model, "CPU", [])

      for port in compiled.inputPorts:
        checkpoint("input[" & $port.index & "] " & port.name &
                   " type=" & $port.elementType & " shape=" & $port.shape)
        check port.name.len > 0
      for port in compiled.outputPorts:
        checkpoint("output[" & $port.index & "] " & port.name &
                   " type=" & $port.elementType & " shape=" & $port.shape)
        check port.name.len > 0

  test "port index round-trips through its name":
    if not modelUsable:
      skip()
    else:
      let core = newCore()
      let model = core.readModel(testModelXml, testModelBin)
      let compiled = core.compileModelWithProperties(model, "CPU", [])
      for port in compiled.inputPorts:
        check compiled.findInputPort(port.name) == port.index
        check compiled.hasInputPort(port.name)

  test "an absent port name yields -1 rather than raising":
    # "does this model have a KV-cache?" is a question asked in order to decide
    # what to do, not an error condition.
    if not modelUsable:
      skip()
    else:
      let core = newCore()
      let model = core.readModel(testModelXml, testModelBin)
      let compiled = core.compileModelWithProperties(model, "CPU", [])
      check compiled.findInputPort("no_such_port_xyz") == -1
      check not compiled.hasInputPort("no_such_port_xyz")

  test "port count matches the number of enumerated ports":
    if not modelUsable:
      skip()
    else:
      let core = newCore()
      let model = core.readModel(testModelXml, testModelBin)
      let compiled = core.compileModelWithProperties(model, "CPU", [])
      check compiled.inputPorts.len == compiled.inputCount
      check compiled.outputPorts.len == compiled.outputCount

suite "Binding tensors by name (requires openvino_c.dll and a real model)":

  test "a tensor bound by name produces the same result as by index":
    # This is the substantive check: the two APIs must be interchangeable for a
    # single-input model. If they diverge, one of them is wired wrong.
    if not modelUsable:
      skip()
    else:
      let core = newCore()
      let model = core.readModel(testModelXml, testModelBin)
      let compiled = core.compileModelWithProperties(model, "CPU", [])
      let inputName = compiled.inputPort(0).name
      let outputName = compiled.outputPort(0).name

      var tokens = [1'i64, 2, 1]
      let dims = @[1'i64, 3'i64]

      # --- by index ---
      let byIndex = compiled.createInferRequest()
      let t1 = newTensor(I64, dims, addr tokens[0])
      byIndex.setInputTensor(0, t1)
      byIndex.infer()
      let outIndex = byIndex.getOutputTensor(0)
      let indexBytes = outIndex.getByteSize()
      let indexFirst = outIndex.getData(float32)[0]

      # --- by name ---
      let byName = compiled.createInferRequest()
      let t2 = newTensor(I64, dims, addr tokens[0])
      byName.setTensor(inputName, t2)
      byName.infer()
      let outName = byName.getTensor(outputName)
      let nameFirst = outName.getData(float32)[0]

      checkpoint("input=" & inputName & " output=" & outputName)
      check outName.getByteSize() == indexBytes
      check nameFirst == indexFirst

  test "binding an unknown port name raises a catchable error":
    if not modelUsable:
      skip()
    else:
      let core = newCore()
      let model = core.readModel(testModelXml, testModelBin)
      let compiled = core.compileModelWithProperties(model, "CPU", [])
      let req = compiled.createInferRequest()

      var tokens = [1'i64]
      let t = newTensor(I64, @[1'i64, 1'i64], addr tokens[0])
      var raised = false
      try:
        req.setTensor("definitely_not_a_port", t)
      except OpenVinoError:
        raised = true
      check raised

  test "reading a tensor by name after inference works for inputs too":
    # get_tensor works on both directions; a KV-cache loop relies on reading
    # present-state outputs and feeding them back as past-state inputs.
    if not modelUsable:
      skip()
    else:
      let core = newCore()
      let model = core.readModel(testModelXml, testModelBin)
      let compiled = core.compileModelWithProperties(model, "CPU", [])
      let inputName = compiled.inputPort(0).name
      let req = compiled.createInferRequest()

      var tokens = [7'i64, 8]
      let t = newTensor(I64, @[1'i64, 2'i64], addr tokens[0])
      req.setTensor(inputName, t)
      let readBack = req.getTensor(inputName)
      check readBack.getByteSize() == 2 * sizeof(int64)

  test "closed request rejects binding by name":
    if not modelUsable:
      skip()
    else:
      let core = newCore()
      let model = core.readModel(testModelXml, testModelBin)
      let compiled = core.compileModelWithProperties(model, "CPU", [])
      let req = compiled.createInferRequest()
      req.close()

      var tokens = [1'i64]
      let t = newTensor(I64, @[1'i64, 1'i64], addr tokens[0])
      var raised = false
      try:
        req.setTensor("any", t)
      except OpenVinoError:
        raised = true
      check raised

# ---------------------------------------------------------------------------
# STRING tensors and extension registration
# ---------------------------------------------------------------------------
#
# These need a *tokenizer* IR plus the tokenizers extension library, which are
# separate from the plain model above. Enable them with:
#
#   RESONANCE_TEST_TOKENIZER_XML  path to openvino_tokenizer.xml
#   RESONANCE_TEST_TOKENIZER_EXT  path to openvino_tokenizers.dll
#
# The point of this suite is to establish the *signature* of
# `ov_tensor_set_string_data` empirically. There is no matching header on this
# machine, so the declaration cannot be verified by reading it. What can be
# verified is behaviour: if the argument count or order were wrong, the call
# would either return a non-zero status or produce garbage token ids.
#
# The decisive check is that tripling the input text triples the token count.
# That only holds if the element count reached the runtime correctly.

let tokenizerXml = getEnv("RESONANCE_TEST_TOKENIZER_XML")
let tokenizerExt = getEnv("RESONANCE_TEST_TOKENIZER_EXT")

let tokenizerUsable =
  openVinoUsable and tokenizerXml.len > 0 and tokenizerExt.len > 0 and
  fileExists(tokenizerXml) and fileExists(tokenizerExt)

suite "STRING tensors and extensions (requires a tokenizer IR)":

  test "reports probe result (informational, not a verdict)":
    if tokenizerXml.len == 0 or tokenizerExt.len == 0:
      checkpoint("set RESONANCE_TEST_TOKENIZER_XML and " &
                 "RESONANCE_TEST_TOKENIZER_EXT to enable this suite")
    elif not fileExists(tokenizerXml):
      checkpoint("tokenizer xml not found: " & tokenizerXml)
    elif not fileExists(tokenizerExt):
      checkpoint("tokenizer extension not found: " & tokenizerExt)
    else:
      checkpoint("tokenizer available: " & tokenizerXml)
    check true

  test "a STRING tensor reports the requested shape and element type":
    if not openVinoUsable:
      skip()
    else:
      let t = newStringTensor(["abc", "de"])
      check t.getElementType() == STRING
      check t.getShape() == @[2'i64]
      check t.getSize() == 2
      t.close()

  test "an empty STRING tensor is allowed and has zero elements":
    # Verified on the real DLL: `ov_tensor_set_string_data` rejects a null
    # pointer with size 0 (INVALID_C_PARAM) instead of treating it as a no-op.
    # `setStringData` therefore returns early for an empty input, which keeps
    # `getSize() == texts.len` true for every input rather than only for
    # non-empty ones.
    if not openVinoUsable:
      skip()
    else:
      let t = newStringTensor([])
      check t.getShape() == @[0'i64]
      check t.getSize() == 0
      t.close()

  test "reading a tokenizer IR fails without the extension registered":
    # This is why registration cannot be optional. Note the error does not
    # mention extensions at all -- it complains about an unsupported opset.
    if not tokenizerUsable:
      skip()
    else:
      let core = newCore()
      var raised = false
      try:
        let m = core.readModel(tokenizerXml, tokenizerXml.changeFileExt("bin"))
        m.close()
      except OpenVinoError:
        raised = true
      check raised

  test "the same IR reads successfully once the extension is registered":
    if not tokenizerUsable:
      skip()
    else:
      let core = newCore()
      core.addExtension(tokenizerExt)
      let m = core.readModel(tokenizerXml, tokenizerXml.changeFileExt("bin"))
      check not m.isClosed
      m.close()

  test "the tokenizer's only input port has element type STRING":
    if not tokenizerUsable:
      skip()
    else:
      let core = newCore()
      core.addExtension(tokenizerExt)
      let m = core.readModel(tokenizerXml, tokenizerXml.changeFileExt("bin"))
      let compiled = core.compileModelWithProperties(m, "CPU", [])
      check compiled.inputCount == 1
      check compiled.inputPort(0).elementType == STRING
      check compiled.hasInputPort("input_ids") == false
      compiled.close()
      m.close()

  test "writing a STRING input yields deterministic token ids":
    if not tokenizerUsable:
      skip()
    else:
      let core = newCore()
      core.addExtension(tokenizerExt)
      let m = core.readModel(tokenizerXml, tokenizerXml.changeFileExt("bin"))
      let compiled = core.compileModelWithProperties(m, "CPU", [])
      let portName = compiled.inputPort(0).name

      proc tokenize(text: string): seq[int64] =
        let req = compiled.createInferRequest()
        let inT = newStringTensor([text])
        req.setTensor(portName, inT)
        req.infer()
        let outT = req.getTensor("input_ids")
        let n = outT.getSize()
        let d = outT.getData(int64)
        result = newSeq[int64](n)
        for i in 0 ..< n:
          result[i] = d[i]
        outT.close()
        inT.close()
        req.close()

      let a = tokenize("Hello, world!")
      let b = tokenize("Hello, world!")
      check a.len > 0
      check a == b

      # The decisive signature check: three copies of the same text must
      # produce exactly three times as many tokens. A wrong element count
      # reaching the runtime would break this.
      let triple = tokenize("Hello, world!Hello, world!Hello, world!")
      check triple.len == a.len * 3

      # Non-ASCII must survive too; a byte-level mistake would show up here.
      let chinese = tokenize("你好，世界")
      check chinese.len > 0

      compiled.close()
      m.close()

  test "token ids stay within the vocabulary implied by the ids themselves":
    # A wrong signature tends to yield huge or negative garbage values.
    if not tokenizerUsable:
      skip()
    else:
      let core = newCore()
      core.addExtension(tokenizerExt)
      let m = core.readModel(tokenizerXml, tokenizerXml.changeFileExt("bin"))
      let compiled = core.compileModelWithProperties(m, "CPU", [])
      let portName = compiled.inputPort(0).name

      let req = compiled.createInferRequest()
      let inT = newStringTensor(["The quick brown fox jumps over the lazy dog."])
      req.setTensor(portName, inT)
      req.infer()
      let outT = req.getTensor("input_ids")
      let n = outT.getSize()
      let d = outT.getData(int64)
      check n > 0
      for i in 0 ..< n:
        check d[i] >= 0
        check d[i] < 1_000_000
      outT.close()
      inT.close()
      req.close()
      compiled.close()
      m.close()

  test "registering a nonexistent extension raises rather than crashing":
    if not openVinoUsable:
      skip()
    else:
      let core = newCore()
      var raised = false
      try:
        core.addExtension("no_such_extension_library_xyz.dll")
      except OpenVinoError:
        raised = true
      check raised
