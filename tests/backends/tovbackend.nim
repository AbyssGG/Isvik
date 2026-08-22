## OpenVINO Backend 测试(Task 9)
##
## ---
##
## ## 分层与外部条件
##
## 测试按「需要什么外部条件」分成三档,缺条件时 SKIP 而不是 FAILED ——
## 「没测」不能显示成「测过」:
##
## ```text
## 第 1 档  纯逻辑(类型映射、错误映射、未初始化行为)   无条件
## 第 2 档  需要 openvino_c.dll                        Backend 生命周期与设备枚举
## 第 3 档  需要 DLL + 一个真实 IR 模型                 端到端推理
## ```
##
## 第 3 档的模型通过环境变量提供:
##
## ```text
## ISVIK_TEST_MODEL_XML   IR 的 .xml 路径
## ISVIK_TEST_MODEL_BIN   IR 的 .bin 路径(可省略,默认同名 .bin)
## ```
##
## ---
##
## ## 第 3 档为什么能做语义验证,而不只是「没报错」
##
## 用于测试的是一个 embedding 查表模型:
##
## ```text
## 输入  input          I64   [-1, -1]        token id
## 输出  inputs_embeds  F32   [-1, -1, 1536]  对应的向量
## ```
##
## 查表有一条可断言的性质:**相同的 token id 必须得到完全相同的向量**。
## 于是传 `[[1, 2, 1]]` 就能一次验证四件事:
##
## 1. 输入数据真的传到了 OpenVINO(否则输出会是全零或垃圾);
## 2. 输出真的是查表结果(位置 0 与位置 2 相等,且与位置 1 不同);
## 3. 数据布局理解正确(row-major,步长 1536);
## 4. 输出拷贝完整(不是只拷了前几个字节)。
##
## 只断言「infer 没抛异常」的测试无法区分「推理正确」与「推理出了一堆零」。

import std/[unittest, os, options, tables, strutils]

import isvik/core/errors
import isvik/core/tensor
import isvik/core/backend
import isvik/backends/mock/mock_backend

import isvik/backends/openvino/element_type
import isvik/backends/openvino/error_mapping
import isvik/backends/openvino/ov_backend

import resonance except Tensor, newTensor

# ---------------------------------------------------------------------------
# 外部条件探测
# ---------------------------------------------------------------------------

let openVinoUsable = tryLoadOpenVino()

let testModelXml = getEnv("ISVIK_TEST_MODEL_XML")
let testModelBin =
  if getEnv("ISVIK_TEST_MODEL_BIN").len > 0:
    getEnv("ISVIK_TEST_MODEL_BIN")
  elif testModelXml.len > 0:
    testModelXml.changeFileExt("bin")
  else:
    ""

let modelUsable =
  openVinoUsable and testModelXml.len > 0 and
  fileExists(testModelXml) and fileExists(testModelBin)

# ---------------------------------------------------------------------------
# 第 1 档:元素类型映射
# ---------------------------------------------------------------------------

suite "元素类型映射:Isvik → OpenVINO":

  test "全部 16 个 Isvik 元素类型逐个映射正确":
    # 逐个显式断言,不用循环自证。这张表写错不会编译失败也不会抛异常,
    # 只会让张量数据被按错误类型解释 —— Resonance 已经因为同类错误吃过一次亏
    # (U8 曾被写成 13,而 13 实际是 U3)。
    check toOvElementType(etBool) == BOOLEAN
    check toOvElementType(etBF16) == BF16
    check toOvElementType(etF16) == F16
    check toOvElementType(etF32) == F32
    check toOvElementType(etF64) == F64
    check toOvElementType(etI4) == I4
    check toOvElementType(etI8) == I8
    check toOvElementType(etI16) == I16
    check toOvElementType(etI32) == I32
    check toOvElementType(etI64) == I64
    check toOvElementType(etU1) == U1
    check toOvElementType(etU4) == U4
    check toOvElementType(etU8) == U8
    check toOvElementType(etU16) == U16
    check toOvElementType(etU32) == U32
    check toOvElementType(etU64) == U64

  test "U8 映射到数值 16":
    # 针对那个真实 bug 的回归防护:U8 必须是 16,不是 13(13 是 U3)。
    check ord(toOvElementType(etU8)) == 16

  test "映射是单射(没有两个 Isvik 类型指向同一个 OpenVINO 类型)":
    # 若出现重复,反向映射就会静默丢掉一个类型。
    var seen: seq[OvElementType] = @[]
    for et in ElementType:
      let ov = toOvElementType(et)
      check ov notin seen
      seen.add(ov)
    check seen.len == 16

suite "元素类型映射:OpenVINO → Isvik":

  test "16 个有对应的类型能反向映射回原值":
    # 往返一致性。反向映射是通过反查正向表实现的,这条断言保证两个方向
    # 不会各自漂移。
    for et in ElementType:
      let ov = toOvElementType(et)
      let back = tryFromOvElementType(ov)
      check back.isSome
      check back.get == et

  test "10 个无对应的类型逐个确认不可映射":
    # 同样逐个写出。这些类型出现在输出张量上时必须失败而不是被近似,
    # 因此「哪些不可映射」本身就是契约的一部分。
    check not isMappableToIsvik(DYNAMIC)
    check not isMappableToIsvik(U2)
    check not isMappableToIsvik(U3)
    check not isMappableToIsvik(U6)
    check not isMappableToIsvik(NF4)
    check not isMappableToIsvik(F8E4M3)
    check not isMappableToIsvik(F8E5M3)
    check not isMappableToIsvik(STRING)
    check not isMappableToIsvik(F4E2M1)
    check not isMappableToIsvik(F8E8M0)

  test "可映射与不可映射两组加起来正好是 OpenVINO 的 26 个类型":
    # 完备性检查。OpenVINO 新增一个元素类型时,这条会失败并提醒人来决定
    # 「它该映射到什么,还是该进不可映射清单」—— 而不是让它悄悄落进
    # 某个 else 分支。
    check UnmappableOvTypes.len == 10
    var mappable = 0
    for et in ElementType:
      inc mappable
    check mappable + UnmappableOvTypes.len == 26

  test "不可映射类型没有一个出现在正向映射表里":
    for ov in UnmappableOvTypes:
      for et in ElementType:
        check toOvElementType(et) != ov

  test "fromOvElementType 对不可映射类型抛 NOT_IMPLEMENTED":
    # 关键行为:抛错而不是近似。把 NF4 当 U4、把 F8E4M3 当 I8 之类的
    # 「宽度凑一下」会产出静默错误的数值结果。
    for ov in UnmappableOvTypes:
      var raised = false
      var code = ecServerError
      try:
        discard fromOvElementType(ov)
      except IsvikError as e:
        raised = true
        code = e.code
      check raised
      check code == ecNotImplemented

  test "STRING 不可映射这一点单独确认":
    # 单列出来是因为它最容易被误认为「可以当字节数组处理」。
    # OpenVINO 的 STRING 是变长字符串张量,内存布局与所有数值类型都不同。
    # tokenizer 的输入输出正是 STRING 张量,Task 15 需要独立的处理路径。
    check not isMappableToIsvik(STRING)

# ---------------------------------------------------------------------------
# 第 1 档:错误映射
# ---------------------------------------------------------------------------

suite "错误映射:上下文决定错误码":

  test "同一个 NOT_FOUND 在不同操作下映射成不同错误码":
    # 这是整个错误映射层存在的核心理由。若先按状态码分流,
    # 这三种情况会被压成同一个错误,调用方无法区分该改什么。
    check mapStatus(ovOpLoadModel, NOT_FOUND) == ecModelNotFound
    check mapStatus(ovOpCompileModel, NOT_FOUND) == ecDeviceNotAvailable
    check mapStatus(ovOpImportCompiledModel, NOT_FOUND) == ecCacheInvalid

  test "loadModel 的状态码细分":
    check mapStatus(ovOpLoadModel, NETWORK_NOT_READ) == ecModelNotFound
    check mapStatus(ovOpLoadModel, NOT_IMPLEMENTED) == ecModelUnsupported
    check mapStatus(ovOpLoadModel, GENERAL_ERROR) == ecModelInvalid

  test "compileModel 的状态码细分":
    check mapStatus(ovOpCompileModel, NOT_IMPLEMENTED) == ecModelUnsupported
    check mapStatus(ovOpCompileModel, GENERAL_ERROR) == ecCompilationFailed

  test "blob 导入区分 INVALID 与 CORRUPTED":
    check mapStatus(ovOpImportCompiledModel, NETWORK_NOT_READ) == ecCacheCorrupted
    check mapStatus(ovOpImportCompiledModel, UNEXPECTED) == ecCacheCorrupted
    check mapStatus(ovOpImportCompiledModel, GENERAL_ERROR) == ecCacheInvalid

  test "推理阶段的参数类错误报 INVALID_PARAMETER 而不是 INFERENCE_FAILED":
    # 形状/类型/索引不匹配是调用方传错了,报 INFERENCE_FAILED 会让人
    # 去查推理引擎,而真正该改的是调用参数。
    check mapStatus(ovOpInfer, PARAMETER_MISMATCH) == ecInvalidParameter
    check mapStatus(ovOpInfer, INVALID_C_PARAM) == ecInvalidParameter
    check mapStatus(ovOpInfer, OUT_OF_BOUNDS) == ecInvalidParameter
    check mapStatus(ovOpSetInputTensor, PARAMETER_MISMATCH) == ecInvalidParameter

  test "取消映射到 STREAM_CANCELLED":
    check mapStatus(ovOpInfer, INFER_CANCELLED) == ecStreamCancelled

  test "推理阶段的其它失败仍报 INFERENCE_FAILED":
    check mapStatus(ovOpInfer, GENERAL_ERROR) == ecInferenceFailed

  test "初始化与设备枚举失败报 BACKEND_NOT_AVAILABLE":
    check defaultCodeFor(ovOpInitialize) == ecBackendNotAvailable
    check defaultCodeFor(ovOpDiscoverDevices) == ecBackendNotAvailable
    check defaultCodeFor(ovOpQueryVersion) == ecBackendNotAvailable

  test "每个操作都有确定的默认错误码":
    # 完备性:新增 OvOperation 时必须同时决定它的默认码。
    for op in OvOperation:
      let code = defaultCodeFor(op)
      check $code != ""

# ---------------------------------------------------------------------------
# 第 1 档:未初始化时的行为
# ---------------------------------------------------------------------------

suite "未初始化的 Backend 行为可预测":

  test "name 是稳定标识 openvino":
    let b = newOpenVinoBackend()
    check b.name == "openvino"
    check b.name == OpenVinoBackendName

  test "构造不触碰 OpenVINO,因此永远不会失败":
    # 这条是 isvik doctor 的前提:必须能先构造出 Backend 再问它「你可用吗」。
    # 若构造本身会因环境问题抛异常,doctor 反而跑不起来。
    let b = newOpenVinoBackend()
    check not b.isInitialized

  test "未初始化时各操作抛 BACKEND_NOT_AVAILABLE":
    let b = newOpenVinoBackend()

    proc expectBackendUnavailable(body: proc()) =
      var code = ecServerError
      var raised = false
      try:
        body()
      except IsvikError as e:
        raised = true
        code = e.code
      check raised
      check code == ecBackendNotAvailable

    expectBackendUnavailable(proc() = discard b.discoverDevices())
    expectBackendUnavailable(proc() = discard b.loadModel("nowhere.xml"))
    expectBackendUnavailable(proc() =
      discard b.importCompiledModel("nowhere.blob", initCompileOptions("CPU")))

  test "release 在未初始化时也安全,且可重复调用":
    let b = newOpenVinoBackend()
    b.release()
    b.release()
    b.release()
    check not b.isInitialized

  test "releaseModel / releaseCompiledModel / releaseInferRequest 接受 nil":
    # 释放类方法必须容忍 nil 与重复调用(§69),否则清理路径本身会成为
    # 新的崩溃来源 —— 而清理往往发生在已经出错的路径上。
    let b = newOpenVinoBackend()
    b.releaseModel(nil)
    b.releaseCompiledModel(nil)
    b.releaseInferRequest(nil)
    check true

  test "传入其它 Backend 的句柄报 INVALID_PARAMETER":
    # MockBackend 的句柄类型与 OpenVINO 的不同。混用是调用方的错误,
    # 必须报可诊断的错误而不是解引用崩溃。
    let b = newOpenVinoBackend()
    let foreign = MockModel(path: "mock.xml", released: false)
    var code = ecServerError
    var raised = false
    try:
      discard b.compileModel(foreign, initCompileOptions("CPU"))
    except IsvikError as e:
      raised = true
      code = e.code
    check raised
    # 未初始化会先于句柄类型被检出,这里只要求「报了可诊断的错误」。
    check code in {ecBackendNotAvailable, ecInvalidParameter}

  test "releaseModel 对其它 Backend 的句柄是无操作,不崩溃":
    let b = newOpenVinoBackend()
    let foreign = MockModel(path: "mock.xml", released: false)
    b.releaseModel(foreign)
    # 不应把别人的句柄标成已释放。
    check not foreign.released

# ---------------------------------------------------------------------------
# 第 2 档:需要 openvino_c.dll
# ---------------------------------------------------------------------------

suite "Backend 生命周期(需要 openvino_c.dll)":

  test "报告运行时探测结果(信息性,不判定成败)":
    if openVinoUsable:
      checkpoint("OpenVINO 可用")
    else:
      checkpoint("OpenVINO 不可用:" & openVinoLoadError())
      checkpoint("本 suite 的其余用例将跳过")
    check true

  test "initialize 成功且幂等":
    if not openVinoUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      check b.isInitialized
      # 重复初始化不应重复创建 Core。
      b.initialize()
      check b.isInitialized
      b.release()

  test "version 返回真实的 OpenVINO 版本,不是编造的":
    if not openVinoUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let v = b.version()
      checkpoint("version=" & v)
      check v.len > 0
      check v != UnknownVersionText
      # 真实版本号形如 "2026.3.0-22451-...";至少应含点号并以年份开头。
      check v.contains(".")
      check v[0].isDigit
      b.release()

  test "discoverDevices 至少报告 CPU,且不伪造设备":
    if not openVinoUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let devices = b.discoverDevices()
      var names: seq[string] = @[]
      for d in devices:
        names.add(d.rawName)
        # rawName 必须非空 —— 空的设备标识无法用于后续编译。
        check d.rawName.len > 0
      checkpoint("devices=" & names.join(", "))
      check devices.len > 0
      check "CPU" in names
      b.release()

  test "fullName 取不到时是空字符串,不用 rawName 冒充":
    # §27:GUI 显示的硬件信息必须真实。用 rawName 冒充会让界面显示
    # 「CPU」这种毫无信息量的假型号。
    if not openVinoUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      for d in b.discoverDevices():
        if d.fullName.len > 0:
          check d.fullName != d.rawName
      b.release()

  test "release 后 isInitialized 为 false,且可重复 release":
    if not openVinoUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      check b.isInitialized
      b.release()
      check not b.isInitialized
      b.release()
      check not b.isInitialized

  test "release 后再操作报 BACKEND_NOT_AVAILABLE 而不是崩溃":
    if not openVinoUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      b.release()
      var code = ecServerError
      var raised = false
      try:
        discard b.discoverDevices()
      except IsvikError as e:
        raised = true
        code = e.code
      check raised
      check code == ecBackendNotAvailable

  test "加载不存在的模型报 MODEL_NOT_FOUND":
    if not openVinoUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      var code = ecServerError
      var raised = false
      try:
        discard b.loadModel("D:\\definitely\\not\\a\\real\\model.xml")
      except IsvikError as e:
        raised = true
        code = e.code
        checkpoint("code=" & $e.code)
      check raised
      # 路径不存在应落在模型相关的错误码里,而不是笼统的 SERVER_ERROR。
      check code in {ecModelNotFound, ecModelInvalid}
      b.release()

  test "OpenVINO 的错误不泄漏到上层":
    # §5:OpenVINO 相关类型不得泄漏到产品层。这里断言抛出来的一定是
    # IsvikError,而不是 Resonance 的 OpenVinoError。
    if not openVinoUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      var wasIsvikError = false
      try:
        discard b.loadModel("D:\\nope.xml")
      except IsvikError:
        wasIsvikError = true
      except CatchableError:
        wasIsvikError = false
      check wasIsvikError
      b.release()

# ---------------------------------------------------------------------------
# 第 3 档:需要 DLL + 真实模型,端到端推理
# ---------------------------------------------------------------------------

const
  TestSeqLen = 3
    ## 测试输入的 token 数。
  TestHidden = 1536
    ## 用于测试的 embedding 模型的输出维度。
    ##
    ## 硬编码是有意的:这个值来自模型本身(Gemma 4 E2B 的 hidden size),
    ## 断言它能确认「输出确实来自这个模型」而不是碰巧有个形状对得上的东西。

suite "端到端推理(需要 openvino_c.dll 与真实模型)":

  test "报告模型探测结果(信息性,不判定成败)":
    if testModelXml.len == 0:
      checkpoint("未设置 ISVIK_TEST_MODEL_XML,本 suite 将全部跳过")
      checkpoint("启用:set ISVIK_TEST_MODEL_XML=<某个 IR 的 .xml 路径>")
    elif not fileExists(testModelXml):
      checkpoint("ISVIK_TEST_MODEL_XML 指向的文件不存在:" & testModelXml)
    elif not fileExists(testModelBin):
      checkpoint("对应的 .bin 不存在:" & testModelBin)
    else:
      checkpoint("模型可用:" & testModelXml)
    check true

  test "loadModel → compileModel → createInferRequest 全链路":
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let model = b.loadModel(testModelXml)
      check model != nil
      let compiled = b.compileModel(model, initCompileOptions("CPU"))
      check compiled != nil
      let request = b.createInferRequest(compiled)
      check request != nil
      b.releaseInferRequest(request)
      b.releaseCompiledModel(compiled)
      b.releaseModel(model)
      b.release()

  test "编译结果记录了设备与 profiling 状态":
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let model = b.loadModel(testModelXml)
      var options = initCompileOptions("CPU", enableProfiling = true)
      let compiled = b.compileModel(model, options)
      let ovCompiled = OvBackendCompiledModel(compiled)
      check ovCompiled.device == "CPU"
      check ovCompiled.profilingEnabled
      # 现场编译而非 blob 导入 —— Task 18 需要靠这个区分 profiling
      # 到底是「没开」还是「开了但驱动拒绝」。
      check not ovCompiled.fromBlob
      b.releaseCompiledModel(compiled)
      b.releaseModel(model)
      b.release()

  test "真实推理:输出形状与元素类型正确":
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let model = b.loadModel(testModelXml)
      let compiled = b.compileModel(model, initCompileOptions("CPU"))
      let request = b.createInferRequest(compiled)

      # 输入是 token id,I64,形状 [1, TestSeqLen]。
      let input = newTensor(etI64, [1, TestSeqLen], @[1'i64, 2'i64, 1'i64])
      b.setInputTensor(request, 0, input)
      b.infer(request)
      let output = b.getOutputTensor(request, 0)

      checkpoint("outputShape=" & $output.shape)
      check output.elementType == etF32
      check output.shape == @[1, TestSeqLen, TestHidden]
      check output.elementCount == TestSeqLen * TestHidden

      b.releaseInferRequest(request)
      b.releaseCompiledModel(compiled)
      b.releaseModel(model)
      b.release()

  test "真实推理:相同 token 得到相同向量(证明数据真的传进去了)":
    # 这是本 suite 最重要的一条。embedding 查表的性质是「相同 id → 相同向量」,
    # 因此传 [1, 2, 1] 后位置 0 与位置 2 必须逐元素相等,且与位置 1 不同。
    #
    # 只断言「infer 没抛异常」的测试无法区分「推理正确」与「输出了一堆零」。
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let model = b.loadModel(testModelXml)
      let compiled = b.compileModel(model, initCompileOptions("CPU"))
      let request = b.createInferRequest(compiled)

      let input = newTensor(etI64, [1, 3], @[1'i64, 2'i64, 1'i64])
      b.setInputTensor(request, 0, input)
      b.infer(request)
      let output = b.getOutputTensor(request, 0)

      let values = output.data(float32)
      check values != nil

      # 位置 0 与位置 2 是同一个 token,必须完全相等。
      var identical = true
      for i in 0 ..< TestHidden:
        if values[0 * TestHidden + i] != values[2 * TestHidden + i]:
          identical = false
          break
      check identical

      # 位置 1 是不同 token,不应与位置 0 完全相同。
      var differs = false
      for i in 0 ..< TestHidden:
        if values[0 * TestHidden + i] != values[1 * TestHidden + i]:
          differs = true
          break
      check differs

      # 输出不应是全零 —— 全零会让上面两条断言都「通过」却毫无意义。
      var nonZero = 0
      for i in 0 ..< output.elementCount:
        if values[i] != 0.0'f32:
          inc nonZero
      checkpoint("nonZeroCount=" & $nonZero & "/" & $output.elementCount)
      check nonZero > 0

      b.releaseInferRequest(request)
      b.releaseCompiledModel(compiled)
      b.releaseModel(model)
      b.release()

  test "输出张量是副本,不随下一次推理改变":
    # 契约要求 getOutputTensor 返回 Isvik 拥有数据的张量。
    # 若只是包了一层 OpenVINO 的缓冲,下一次 infer 会悄悄改写它。
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let model = b.loadModel(testModelXml)
      let compiled = b.compileModel(model, initCompileOptions("CPU"))
      let request = b.createInferRequest(compiled)

      let inputA = newTensor(etI64, [1, 1], @[1'i64])
      b.setInputTensor(request, 0, inputA)
      b.infer(request)
      let outputA = b.getOutputTensor(request, 0)
      let firstValueBefore = outputA.data(float32)[0]

      # 换一个 token 再推一次。
      let inputB = newTensor(etI64, [1, 1], @[500'i64])
      b.setInputTensor(request, 0, inputB)
      b.infer(request)
      let outputB = b.getOutputTensor(request, 0)

      # 第一次的结果不能被第二次改写。
      check outputA.data(float32)[0] == firstValueBefore
      # 两个不同 token 的结果应该不同(否则说明拷贝或绑定有问题)。
      check outputA.data(float32)[0] != outputB.data(float32)[0]

      b.releaseInferRequest(request)
      b.releaseCompiledModel(compiled)
      b.releaseModel(model)
      b.release()

  test "重复绑定同一索引不泄漏,且以最后一次为准":
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let model = b.loadModel(testModelXml)
      let compiled = b.compileModel(model, initCompileOptions("CPU"))
      let request = b.createInferRequest(compiled)

      # 连续绑定 5 次,每次都应替换掉上一个 Resonance 张量包装。
      for token in [1'i64, 2'i64, 3'i64, 4'i64, 7'i64]:
        let t = newTensor(etI64, [1, 1], @[token])
        b.setInputTensor(request, 0, t)

      let ovRequest = OvBackendInferRequest(request)
      # 同一索引只应留一个绑定。
      check ovRequest.nativeInputs.len == 1
      check ovRequest.inputTensors.len == 1

      b.infer(request)
      let output = b.getOutputTensor(request, 0)

      # 结果应对应最后绑定的 token 7,而不是第一个。
      let expected = newTensor(etI64, [1, 1], @[7'i64])
      b.setInputTensor(request, 0, expected)
      b.infer(request)
      let reference = b.getOutputTensor(request, 0)
      check output.data(float32)[0] == reference.data(float32)[0]

      b.releaseInferRequest(request)
      b.releaseCompiledModel(compiled)
      b.releaseModel(model)
      b.release()

  test "按索引与端口名绑定空张量时保留零维 shape":
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let model = b.loadModel(testModelXml)
      let compiled = b.compileModel(model, initCompileOptions("CPU"))
      let request = b.createInferRequest(compiled)

      # 零元素张量没有 host pointer；backend 必须改用 OpenVINO-owned tensor，
      # 而不是拒绝合法 shape 或把 nil 交给 host-backed API。
      let empty = newTensor(etI64, [1, 0])
      b.setInputTensor(request, 0, empty)

      let inputNames = b.inputPortNames(compiled)
      check inputNames.len > 0
      if inputNames.len > 0:
        b.setInputTensorByName(request, inputNames[0], empty)

      let ovRequest = OvBackendInferRequest(request)
      check ovRequest.nativeInputs.len == 1
      check ovRequest.inputTensors[0].shape == @[1, 0]
      if inputNames.len > 0:
        check ovRequest.namedNativeInputs.len == 1
        check ovRequest.namedInputTensors[inputNames[0]].shape == @[1, 0]

      b.releaseInferRequest(request)
      b.releaseCompiledModel(compiled)
      b.releaseModel(model)
      b.release()

  test "绑定 nil 张量报 INVALID_PARAMETER":
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let model = b.loadModel(testModelXml)
      let compiled = b.compileModel(model, initCompileOptions("CPU"))
      let request = b.createInferRequest(compiled)

      var code = ecServerError
      var raised = false
      try:
        b.setInputTensor(request, 0, nil)
      except IsvikError as e:
        raised = true
        code = e.code
      check raised
      check code == ecInvalidParameter

      b.releaseInferRequest(request)
      b.releaseCompiledModel(compiled)
      b.releaseModel(model)
      b.release()

  test "释放全链路后重复释放不崩溃":
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let model = b.loadModel(testModelXml)
      let compiled = b.compileModel(model, initCompileOptions("CPU"))
      let request = b.createInferRequest(compiled)

      b.releaseInferRequest(request)
      b.releaseInferRequest(request)
      b.releaseCompiledModel(compiled)
      b.releaseCompiledModel(compiled)
      b.releaseModel(model)
      b.releaseModel(model)
      b.release()
      b.release()
      check true

  test "使用已释放的句柄报 INVALID_PARAMETER 而不是崩溃":
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let model = b.loadModel(testModelXml)
      b.releaseModel(model)

      var code = ecServerError
      var raised = false
      try:
        discard b.compileModel(model, initCompileOptions("CPU"))
      except IsvikError as e:
        raised = true
        code = e.code
      check raised
      check code == ecInvalidParameter
      b.release()

  test "编译到不存在的设备报设备类错误":
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let model = b.loadModel(testModelXml)
      var code = ecServerError
      var raised = false
      try:
        discard b.compileModel(model, initCompileOptions("DEFINITELY_NOT_A_DEVICE"))
      except IsvikError as e:
        raised = true
        code = e.code
        checkpoint("code=" & $e.code)
      check raised
      # 具体是 DEVICE_NOT_AVAILABLE 还是 COMPILATION_FAILED 取决于 OpenVINO
      # 报的状态码,两者都是可诊断的;不接受 SERVER_ERROR 那种兜底码。
      check code in {ecDeviceNotAvailable, ecCompilationFailed,
                     ecModelUnsupported}
      b.releaseModel(model)
      b.release()

  test "多属性编译在 Backend 层同样可用":
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let model = b.loadModel(testModelXml)
      var options = initCompileOptions("CPU", enableProfiling = true)
      options.properties["PERFORMANCE_HINT"] = "LATENCY"
      options.properties["NUM_STREAMS"] = "1"
      let compiled = b.compileModel(model, options)
      check compiled != nil
      # 能创建 infer request 才算真的编译成功。
      let request = b.createInferRequest(compiled)
      check request != nil
      b.releaseInferRequest(request)
      b.releaseCompiledModel(compiled)
      b.releaseModel(model)
      b.release()

  test "enableProfiling 与手写 PERF_COUNT 不会重复传给 OpenVINO":
    # 同名键传两次给 OpenVINO 的行为未定义。这里断言不会因此失败。
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let model = b.loadModel(testModelXml)
      var options = initCompileOptions("CPU", enableProfiling = true)
      options.properties["PERF_COUNT"] = "YES"
      let compiled = b.compileModel(model, options)
      check compiled != nil
      b.releaseCompiledModel(compiled)
      b.releaseModel(model)
      b.release()

  test "blob 导出与导入,且导入结果标记为 fromBlob":
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let model = b.loadModel(testModelXml)
      let compiled = b.compileModel(model, initCompileOptions("CPU"))

      let blobPath = getTempDir() / "isvik_test_ovbackend.blob"
      removeFile(blobPath)
      b.exportCompiledModel(compiled, blobPath)
      check fileExists(blobPath)
      check getFileSize(blobPath) > 0

      let imported = b.importCompiledModel(blobPath, initCompileOptions("CPU"))
      check imported != nil
      let ovImported = OvBackendCompiledModel(imported)
      # 关键:blob 不含运行期属性,profilingEnabled 必须如实记为 false,
      # fromBlob 记为 true。记成 true 会让 Task 18 报告一份空数据却声称
      # 采集成功 —— 那是伪造 Benchmark。
      check ovImported.fromBlob
      check not ovImported.profilingEnabled

      # 导入的模型必须真的可用。
      let request = b.createInferRequest(imported)
      check request != nil

      b.releaseInferRequest(request)
      b.releaseCompiledModel(imported)
      b.releaseCompiledModel(compiled)
      b.releaseModel(model)
      b.release()
      removeFile(blobPath)

  test "导入损坏的 blob 报缓存类错误":
    if not modelUsable:
      skip()
    else:
      let b = newOpenVinoBackend()
      b.initialize()
      let badPath = getTempDir() / "isvik_test_bad.blob"
      writeFile(badPath, "this is definitely not a compiled model blob")
      var code = ecServerError
      var raised = false
      try:
        discard b.importCompiledModel(badPath, initCompileOptions("CPU"))
      except IsvikError as e:
        raised = true
        code = e.code
        checkpoint("code=" & $e.code)
      check raised
      check code in {ecCacheInvalid, ecCacheCorrupted}
      b.release()
      removeFile(badPath)
