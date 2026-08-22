## Model Manifest 与 Model Storage 测试
##
## 全部用临时目录里构造的假 IR 文件,不依赖真实模型 —— 因此在任何机器上
## 都能跑。真实模型目录的识别由 `tests/models/tmodels_real.nim` 在
## 提供 `ISVIK_TEST_MODEL_DIR` 时验证。

import std/[unittest, os, json, strutils, tables]

import isvik/core/errors
import isvik/config/paths
import isvik/config/settings
import isvik/models/manifest
import isvik/models/inspection
import isvik/models/storage
import isvik/util/checksum

var tmpCounter = 0

proc makeTempDir(): string =
  inc tmpCounter
  result = getTempDir() / ("isvik_test_models_" & $tmpCounter & "_" &
    $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc shapeAttribute(rank: int): string =
  for i in 0 ..< rank:
    if i > 0:
      result.add(',')
    result.add('?')

proc dimElements(rank: int, indentation: string): string =
  for _ in 0 ..< rank:
    result.add(indentation & "<dim>?</dim>\n")

proc dimElements(dims: openArray[string], indentation: string): string =
  for dim in dims:
    result.add(indentation & "<dim>" & dim & "</dim>\n")

proc parameterLayer(id: int, name, elementType, precision: string,
                    rank: int, dims: seq[string] = @[]): string =
  let shape =
    if dims.len > 0: dims.join(",")
    else: shapeAttribute(rank)
  let dimensions =
    if dims.len > 0: dimElements(dims, "        ")
    else: dimElements(rank, "        ")
  "  <layer id=\"" & $id & "\" name=\"" & name &
    "\" type=\"Parameter\" version=\"opset1\">\n" &
    "    <data shape=\"" & shape & "\" element_type=\"" &
    elementType & "\"/>\n" &
    "    <output>\n" &
    "      <port id=\"0\" precision=\"" & precision & "\" names=\"" &
    name & "\">\n" & dimensions &
    "      </port>\n" &
    "    </output>\n" &
    "  </layer>\n"

proc sourceLayer(id, portId: int, layerName, aliases, precision: string,
                 rank: int): string =
  "  <layer id=\"" & $id & "\" name=\"" & layerName &
    "\" type=\"Relu\" version=\"opset1\">\n" &
    "    <output>\n" &
    "      <port id=\"" & $portId & "\" precision=\"" & precision &
    "\" names=\"" & aliases & "\">\n" & dimElements(rank, "        ") &
    "      </port>\n" &
    "    </output>\n" &
    "  </layer>\n"

proc fakeIrXml(composite = false, mainElementType = "",
               mainPrecision = "", mainRank = 0,
               logitsPrecision = "FP32", logitsRank = 3,
               logitsAliases = "logits",
               resultName = "logits/sink_port_0",
               includeBeam = true, beamElementType = "int32",
               beamPrecision = "I32", beamRank = 1,
               includeTokenTypeIds = false,
               tokenTypeElementType = "i64",
               tokenTypePrecision = "I64", tokenTypeRank = 2,
               includePerLayerInputs = false,
               perLayerElementType = "f32",
               perLayerPrecision = "FP32", perLayerRank = 4,
               perLayerDims: seq[string] = @[],
               includePast = false, includePresent = false,
               kvInputType = "f16",
               kvInputPrecision = "FP16", kvInputRank = 4,
               kvOutputPrecision = "FP16", kvOutputRank = 4): string =
  let mainName = if composite: "inputs_embeds" else: "input_ids"
  let actualMainType = if mainElementType.len > 0: mainElementType
                       elif composite: "f32" else: "i64"
  let actualMainPrecision = if mainPrecision.len > 0: mainPrecision
                            elif composite: "FP32" else: "I64"
  let actualMainRank = if mainRank > 0: mainRank
                       elif composite: 3 else: 2

  var layers = parameterLayer(
    0, mainName, actualMainType, actualMainPrecision, actualMainRank)
  layers.add(parameterLayer(1, "attention_mask", "int64", "I64", 2))
  layers.add(parameterLayer(2, "position_ids", "i64", "I64", 2))
  if includeBeam:
    layers.add(parameterLayer(3, "beam_idx", beamElementType,
                              beamPrecision, beamRank))
  if includeTokenTypeIds:
    layers.add(parameterLayer(11, "token_type_ids", tokenTypeElementType,
                              tokenTypePrecision, tokenTypeRank))
  if includePerLayerInputs:
    layers.add(parameterLayer(12, "per_layer_inputs", perLayerElementType,
                              perLayerPrecision, perLayerRank, perLayerDims))
  layers.add("  <layer id=\"4\" name=\"state_read\" type=\"ReadValue\" " &
    "version=\"opset6\"/>\n")
  layers.add("  <layer id=\"5\" name=\"state_assign\" type=\"Assign\" " &
    "version=\"opset6\"/>\n")
  layers.add(sourceLayer(
    6, 1, "logits_source", logitsAliases, logitsPrecision, logitsRank))
  layers.add("  <layer id=\"7\" name=\"" & resultName &
    "\" type=\"Result\" version=\"opset1\"/>\n")
  if includePast:
    layers.add(parameterLayer(8, "past_key_values.0.key", kvInputType,
                              kvInputPrecision, kvInputRank))
  if includePresent:
    layers.add(sourceLayer(9, 0, "present_source", "present.0.key",
                           kvOutputPrecision, kvOutputRank))
    layers.add("  <layer id=\"10\" name=\"present/sink_port_0\" " &
      "type=\"Result\" version=\"opset1\"/>\n")

  var edges =
    "  <edge from-layer=\"6\" from-port=\"1\" to-layer=\"7\" " &
    "to-port=\"0\"/>\n"
  if includePresent:
    edges.add("  <edge from-layer=\"9\" from-port=\"0\" to-layer=\"10\" " &
      "to-port=\"0\"/>\n")

  "<net name=\"fixture\" version=\"11\">\n<layers>\n" & layers &
    "</layers>\n<edges>\n" & edges & "</edges>\n</net>"

proc writeFakeIr(dir: string, stem: string) =
  ## 造一对最小 stateful causal-LM IR / bin。fixture 给每个参与契约的端口
  ## 明确 type 与 <dim> rank；composite 主输入和 logits 都是 rank 3。
  createDir(dir)
  let composite = "language_model" in stem or "language-model" in stem
  writeFile(dir / (stem & ".xml"), fakeIrXml(composite = composite))
  writeFile(dir / (stem & ".bin"), "binary-weights-for-" & stem)

proc inspectFixture(xml: string): ModelInspection =
  let dir = makeTempDir()
  defer: removeDir(dir)
  let path = dir / "model.xml"
  writeFile(path, xml)
  inspectOpenVinoIr(path)

suite "OpenVINO IR 契约检测":

  test "Result 输出完整继承唯一 source port 的 aliases 与 metadata":
    let inspection = inspectFixture(fakeIrXml(logitsAliases = "scores,logits"))
    check inspection.layout == mlMonolithicTokenCausalLm
    var sawScores = false
    var sawLogits = false
    for port in inspection.outputs:
      if port.name == "scores":
        sawScores = port.elementType == "F32" and
          port.dims == @[-1, -1, -1]
      elif port.name == "logits":
        sawLogits = port.elementType == "F32" and
          port.dims == @[-1, -1, -1]
    check sawScores
    check sawLogits

  test "Result friendly name 不能冒充 source port 的 logits":
    let inspection = inspectFixture(fakeIrXml(
      logitsAliases = "hidden_states", resultName = "logits/sink_port_0"))
    check inspection.layout == mlUnknown
    check inspection.outputs.len == 1
    check inspection.outputs[0].name == "hidden_states"

  test "错误 input 或 logits type/rank 都不能匹配":
    check inspectFixture(fakeIrXml(
      mainElementType = "float32", mainPrecision = "FP32")).layout == mlUnknown
    check inspectFixture(fakeIrXml(
      mainElementType = "float", mainPrecision = "float")).layout == mlUnknown
    check inspectFixture(fakeIrXml(mainRank = 1)).layout == mlUnknown
    check inspectFixture(fakeIrXml(logitsPrecision = "I64")).layout == mlUnknown
    check inspectFixture(fakeIrXml(logitsRank = 2)).layout == mlUnknown
    check inspectFixture(fakeIrXml(
      beamElementType = "float32", beamPrecision = "FP32")).layout == mlUnknown

  test "可选 token_type_ids 的合法契约保留分类与 shape metadata":
    let inspection = inspectFixture(fakeIrXml(
      composite = true, includeTokenTypeIds = true))
    check inspection.layout == mlCompositeEmbeddingCausalLm

    var sawMetadata = false
    for port in inspection.inputs:
      if port.name == "token_type_ids":
        sawMetadata = port.elementType == "I64" and
          port.dims == @[-1, -1]
    check sawMetadata

    var sawBounded = false
    for shape in causalLmBoundedShapes(inspection, 128):
      if shape.name == "token_type_ids":
        sawBounded = shape.dims.len == 2 and
          shape.dims[0].minimum == 1 and shape.dims[0].maximum == 1 and
          shape.dims[1].minimum == 1 and shape.dims[1].maximum == 128
    check sawBounded

    var sawNpuStatic = false
    for shape in causalLmNpuStaticShapes(inspection, 128):
      if shape.name == "token_type_ids":
        sawNpuStatic = shape.dims.len == 2 and
          shape.dims[0].minimum == 1 and shape.dims[0].maximum == 1 and
          shape.dims[1].minimum == 1 and shape.dims[1].maximum == 1
    check sawNpuStatic

    check inspectFixture(fakeIrXml(
      includeTokenTypeIds = true)).layout == mlMonolithicTokenCausalLm

  test "错误 token_type_ids type rank 或 metadata 使分类 unknown":
    check inspectFixture(fakeIrXml(
      composite = true, includeTokenTypeIds = true,
      tokenTypeElementType = "i32", tokenTypePrecision = "I32")).layout ==
        mlUnknown
    check inspectFixture(fakeIrXml(
      composite = true, includeTokenTypeIds = true,
      tokenTypeElementType = "f32", tokenTypePrecision = "FP32")).layout ==
        mlUnknown
    check inspectFixture(fakeIrXml(
      composite = true, includeTokenTypeIds = true,
      tokenTypeRank = 1)).layout == mlUnknown
    check inspectFixture(fakeIrXml(
      includeTokenTypeIds = true,
      tokenTypePrecision = "malformed")).layout == mlUnknown

  test "合法 per_layer_inputs 保留零维 shape metadata":
    let inspection = inspectFixture(fakeIrXml(
      composite = true, includePerLayerInputs = true,
      perLayerDims = @["?", "?", "30", "0"]))
    check inspection.layout == mlCompositeEmbeddingCausalLm

    var sawMetadata = false
    for port in inspection.inputs:
      if port.name == "per_layer_inputs":
        sawMetadata = port.elementType == "F32" and
          port.dims == @[-1, -1, 30, 0]
    check sawMetadata

  test "错误 per_layer_inputs type rank 或 metadata 使分类 unknown":
    check inspectFixture(fakeIrXml(
      composite = true, includePerLayerInputs = true,
      perLayerElementType = "f16", perLayerPrecision = "FP16")).layout ==
        mlUnknown
    check inspectFixture(fakeIrXml(
      composite = true, includePerLayerInputs = true,
      perLayerRank = 3)).layout == mlUnknown
    check inspectFixture(fakeIrXml(
      composite = true, includePerLayerInputs = true,
      perLayerPrecision = "malformed")).layout == mlUnknown

  test "external KV 必须双边 suffix/type/rank 完整配对":
    check inspectFixture(fakeIrXml(
      includePast = true, includePresent = true)).layout ==
        mlExternalKvCausalLm
    check inspectFixture(fakeIrXml(includePast = true)).layout == mlUnknown
    check inspectFixture(fakeIrXml(
      includePast = true, kvInputRank = 0)).layout == mlUnknown
    check inspectFixture(fakeIrXml(
      composite = true, includePast = true,
      includePresent = true)).layout == mlUnknown
    check inspectFixture(fakeIrXml(
      includePast = true, includePresent = true,
      kvOutputRank = 3)).layout == mlUnknown
    check inspectFixture(fakeIrXml(
      includePast = true, includePresent = true,
      kvOutputPrecision = "BF16")).layout == mlUnknown

proc completeManifest(id: string): ModelManifest =
  ## 一个通过校验的最小清单。
  result = initModelManifest(id)
  result.files = @[
    ModelFile(path: "openvino_model.xml", bytes: 10, sha256: ""),
    ModelFile(path: "openvino_model.bin", bytes: 20, sha256: "")
  ]
  result.entrypoints[EntrypointModel] = "openvino_model.xml"
  result.sourceDirectory = "D:/models/example"

# ---------------------------------------------------------------------------
# Manifest
# ---------------------------------------------------------------------------

suite "Manifest:构造与默认值":

  test "新清单带当前 schema 版本,任务为 unknown 而不是猜一个":
    let m = initModelManifest("demo")
    check m.schemaVersion == ManifestSchemaVersion
    check m.id == "demo"
    check m.task == mtUnknown
    check m.format == mfOpenVinoIr
    check m.storage == skReferenced
    check m.files.len == 0
    check m.deviceSupport.len == 0
    check m.importedAt.len > 0

  test "displayLabel 在 displayName 为空时回落到 id":
    var m = initModelManifest("gemma-4-e2b")
    check m.displayLabel == "gemma-4-e2b"
    m.displayName = "Gemma 4 E2B"
    check m.displayLabel == "Gemma 4 E2B"

  test "设备支持条目构造出来一律未验证":
    # 构造不等于验证(§13 / §27)。
    let d = initDeviceSupport("NPU", supported = true)
    check d.supported
    check not d.verified
    check d.shapeConstraints.len == 0

  test "没有条目的设备按不支持处理,而不是默认支持":
    # 默认支持会让「清单没写」被当成「可以跑」。
    let m = initModelManifest("demo")
    let npu = m.deviceSupportFor("NPU")
    check not npu.supported
    check not npu.verified
    check npu.note.len > 0

  test "totalBytes 汇总所有文件":
    let m = completeManifest("demo")
    check m.totalBytes == 30

suite "Manifest:设备与静态 shape 约束":

  test "能表达「NPU 要求静态 shape」及具体约束":
    # 这是 Task 13 的硬要求:否则推理编排无法在编译前判断可行性。
    var m = completeManifest("demo")
    var npu = initDeviceSupport("NPU", supported = true,
                                requiresStaticShape = true)
    npu.shapeConstraints = @[
      ShapeConstraint(port: "input_ids", dims: @[1, 128]),
      ShapeConstraint(port: "attention_mask", dims: @[1, 128])
    ]
    m.deviceSupport = @[npu]

    check m.validate() == ""
    check m.requiresStaticShapeOn("NPU")
    check not m.requiresStaticShapeOn("CPU")
    check m.deviceSupportFor("NPU").shapeConstraints.len == 2

  test "isStatic 区分全静态与含动态维":
    check ShapeConstraint(port: "x", dims: @[1, 128]).isStatic
    check not ShapeConstraint(port: "x", dims: @[1, -1]).isStatic
    check not ShapeConstraint(port: "x", dims: @[-1, -1]).isStatic

  test "声称要求静态 shape 却不给约束被拒绝":
    # 那等于没给出可用信息。
    var m = completeManifest("demo")
    m.deviceSupport = @[initDeviceSupport("NPU", true, requiresStaticShape = true)]
    check m.validate().contains("shapeConstraints")

  test "「试过了但不支持」是合法且有价值的记录":
    # supported 与 verified 是两个独立事实。把这种组合判为非法,
    # 会让「在 NPU 上实测失败」这个结论无处记录,下次还得再试一遍。
    var m = completeManifest("demo")
    var d = initDeviceSupport("NPU", supported = false)
    d.verified = true
    d.note = "动态 shape 在该设备上不受支持"
    m.deviceSupport = @[d]
    check m.validate() == ""

    let npu = m.deviceSupportFor("NPU")
    check npu.verified
    check not npu.supported

  test "四种 supported / verified 组合都合法":
    for supported in [false, true]:
      for verified in [false, true]:
        var m = completeManifest("demo")
        var d = initDeviceSupport("CPU", supported = supported)
        d.verified = verified
        m.deviceSupport = @[d]
        check m.validate() == ""

  test "设备名必须是语义值,不接受 GPU.0 这类 rawName":
    # manifest 描述的是模型属性,与具体某张卡无关。
    var m = completeManifest("demo")
    m.deviceSupport = @[initDeviceSupport("GPU.0")]
    check m.validate().contains("deviceSupport.device")

  test "AUTO 不是合法的设备支持取值":
    # 「模型在 AUTO 上是否支持」这句话没有意义。
    check "AUTO" notin SemanticDeviceNames
    var m = completeManifest("demo")
    m.deviceSupport = @[initDeviceSupport("AUTO")]
    check m.validate().len > 0

  test "非法维度被拒绝":
    var m = completeManifest("demo")
    var d = initDeviceSupport("NPU", true, requiresStaticShape = true)
    d.shapeConstraints = @[ShapeConstraint(port: "x", dims: @[1, 0])]
    m.deviceSupport = @[d]
    check m.validate().contains("invalid dimension")

suite "Manifest:校验":

  test "最小合法清单通过校验":
    check completeManifest("demo").validate() == ""

  test "缺少主模型入口被拒绝":
    var m = completeManifest("demo")
    m.entrypoints.clear()
    check m.validate().contains(EntrypointModel)

  test "language_model 也能作为主模型角色":
    # 组合式 LLM 没有单一的 openvino_model.xml。
    var m = completeManifest("demo")
    m.entrypoints.clear()
    m.entrypoints[EntrypointLanguageModel] = "openvino_model.xml"
    check m.validate() == ""
    check m.primaryRole() == EntrypointLanguageModel
    check m.primaryEntrypoint() == "openvino_model.xml"
    check m.isComposite()

  test "单体模型不算组合式":
    let m = completeManifest("demo")
    check m.primaryRole() == EntrypointModel
    check not m.isComposite()

  test "全部七个入口角色都被接受":
    var m = completeManifest("demo")
    m.files = @[]
    m.entrypoints.clear()
    for i, role in KnownEntrypoints:
      let path = "file" & $i & ".xml"
      m.files.add(ModelFile(path: path, bytes: 1, sha256: ""))
      m.entrypoints[role] = path
    check m.validate() == ""
    check m.entrypoints.len == 7

  test "入口指向未登记的文件被拒绝":
    # 否则「清单说有 tokenizer」与「清单里没这个文件」会同时成立。
    var m = completeManifest("demo")
    m.entrypoints[EntrypointTokenizer] = "openvino_tokenizer.xml"
    check m.validate().contains("not listed")

  test "未知入口角色被拒绝":
    var m = completeManifest("demo")
    m.entrypoints["encoder"] = "openvino_model.xml"
    check m.validate().contains("unknown entrypoint role")

  test "非法 model id 被拒绝":
    for badId in ["", "a/b", "a\\b", "..", "CON", "with space ",
                  "trailing.", "C:evil"]:
      var m = completeManifest("demo")
      m.id = badId
      check m.validate().len > 0

  test "合法 model id 被接受":
    for goodId in ["demo", "gemma-4-e2b-it-int4-ov", "model_1", "a.b"]:
      check validateModelId(goodId) == ""

  test "引用模式必须给出来源目录":
    var m = completeManifest("demo")
    m.storage = skReferenced
    m.sourceDirectory = ""
    check m.validate().contains("sourceDirectory")

  test "清单文件路径必须安全":
    var m = completeManifest("demo")
    m.files = @[ModelFile(path: "../outside.xml", bytes: 1, sha256: "")]
    m.entrypoints[EntrypointModel] = "../outside.xml"
    check m.validate().contains("unsafe file path")

  test "比当前 schema 更新的版本被拒绝":
    # 更高版本可能含本程序不认识的必需字段,按旧规则解析会得到
    # 一个看似成功却缺信息的结果。
    var m = completeManifest("demo")
    m.schemaVersion = ManifestSchemaVersion + 1
    check m.validate().contains("newer than supported")

  test "requireValid 对非法清单抛 MODEL_INVALID":
    var m = completeManifest("demo")
    m.entrypoints.clear()
    var code: IsvikErrorCode
    try:
      m.requireValid()
      check false
    except IsvikError as e:
      code = e.code
    check code == ecModelInvalid

suite "Manifest:JSON 往返":

  test "序列化后反序列化得到相同内容":
    var m = completeManifest("demo")
    m.displayName = "Demo 模型"
    m.version = "1.2"
    m.task = mtTextGeneration
    m.notes = "含中文的备注"
    m.entrypoints[EntrypointTokenizer] = "openvino_model.bin"
    var npu = initDeviceSupport("NPU", true, requiresStaticShape = true)
    npu.shapeConstraints = @[ShapeConstraint(port: "input_ids", dims: @[1, 128])]
    npu.note = "需分块"
    m.deviceSupport = @[npu, initDeviceSupport("CPU")]

    let back = parseManifest(m.toJson())
    check back.id == m.id
    check back.displayName == m.displayName
    check back.version == m.version
    check back.task == m.task
    check back.notes == m.notes
    check back.files.len == m.files.len
    check back.entrypoints == m.entrypoints
    check back.deviceSupport.len == 2
    check back.deviceSupport[0].requiresStaticShape
    check back.deviceSupport[0].shapeConstraints[0].dims == @[1, 128]
    check back.deviceSupport[0].note == "需分块"
    check not back.deviceSupport[0].verified

  test "字段名采用 snake_case,与 settings.json 一致":
    let node = completeManifest("demo").toJsonNode()
    check node.hasKey("schema_version")
    check node.hasKey("display_name")
    check node.hasKey("source_directory")
    check node.hasKey("device_support")
    check node.hasKey("imported_at")

  test "入口按固定顺序输出,使序列化结果稳定":
    var m = completeManifest("demo")
    m.entrypoints[EntrypointTokenizer] = "openvino_model.bin"
    check m.toJson() == m.toJson()

  test "缺失字段回落默认值":
    let raw = """{"id": "demo",
                  "files": [{"path": "m.xml", "bytes": 1}],
                  "entrypoints": {"model": "m.xml"},
                  "source_directory": "D:/x"}"""
    let m = parseManifest(raw)
    check m.schemaVersion == ManifestSchemaVersion
    check m.task == mtUnknown
    check m.storage == skReferenced
    check m.displayName == ""

  test "类型错误必须报错,不静默回落":
    let raw = """{"id": "demo", "schema_version": "one",
                  "files": [], "entrypoints": {"model": "m.xml"}}"""
    var code: IsvikErrorCode
    try:
      discard parseManifest(raw)
      check false
    except IsvikError as e:
      code = e.code
    check code == ecModelInvalid

  test "非法 JSON 抛 MODEL_INVALID":
    expect IsvikError:
      discard parseManifest("{ not json")

  test "未知 format / task / storage 取值被拒绝":
    for bad in [
      """{"id":"d","format":"tensorflow","files":[{"path":"m.xml","bytes":1}],"entrypoints":{"model":"m.xml"},"source_directory":"x"}""",
      """{"id":"d","task":"image-generation","files":[{"path":"m.xml","bytes":1}],"entrypoints":{"model":"m.xml"},"source_directory":"x"}""",
      """{"id":"d","storage":"symlinked","files":[{"path":"m.xml","bytes":1}],"entrypoints":{"model":"m.xml"},"source_directory":"x"}"""
    ]:
      expect IsvikError:
        discard parseManifest(bad)

# ---------------------------------------------------------------------------
# 文件校验
# ---------------------------------------------------------------------------

suite "文件完整性校验":

  test "文件齐全时没有问题":
    let dir = makeTempDir()
    writeFakeIr(dir, "openvino_model")
    var m = initModelManifest("demo")
    m.files = @[
      ModelFile(path: "openvino_model.xml",
                bytes: getFileSize(dir / "openvino_model.xml"), sha256: ""),
      ModelFile(path: "openvino_model.bin",
                bytes: getFileSize(dir / "openvino_model.bin"), sha256: "")
    ]
    m.entrypoints[EntrypointModel] = "openvino_model.xml"
    m.sourceDirectory = dir

    check m.verifyFiles(dir).len == 0
    check m.isComplete(dir)
    removeDir(dir)

  test "缺失文件被逐个报告,不是遇到第一个就停":
    let dir = makeTempDir()
    var m = initModelManifest("demo")
    m.files = @[
      ModelFile(path: "a.xml", bytes: 1, sha256: ""),
      ModelFile(path: "b.bin", bytes: 1, sha256: "")
    ]
    m.entrypoints[EntrypointModel] = "a.xml"
    m.sourceDirectory = dir

    let issues = m.verifyFiles(dir)
    check issues.len == 2
    for i in issues:
      check i.kind == fikMissing
    check not m.isComplete(dir)
    removeDir(dir)

  test "大小不符被识别为 size-mismatch":
    let dir = makeTempDir()
    writeFile(dir / "m.xml", "short")
    var m = initModelManifest("demo")
    m.files = @[ModelFile(path: "m.xml", bytes: 99999, sha256: "")]
    m.entrypoints[EntrypointModel] = "m.xml"
    m.sourceDirectory = dir

    let issues = m.verifyFiles(dir)
    check issues.len == 1
    check issues[0].kind == fikSizeMismatch
    check issues[0].detail.contains("expected=99999")
    removeDir(dir)

  test "校验和默认不比对,显式开启后能发现内容改动":
    let dir = makeTempDir()
    let content = "weights-v1"
    writeFile(dir / "m.bin", content)
    writeFile(dir / "m.xml", "<net/>")

    var m = initModelManifest("demo")
    m.files = @[
      ModelFile(path: "m.xml", bytes: getFileSize(dir / "m.xml"), sha256: ""),
      ModelFile(path: "m.bin", bytes: getFileSize(dir / "m.bin"),
                sha256: sha256Hex(content))
    ]
    m.entrypoints[EntrypointModel] = "m.xml"
    m.sourceDirectory = dir

    check m.verifyFiles(dir, initVerifyOptions(checkChecksums = true)).len == 0

    # 改内容但保持长度不变 —— 只有校验和能发现。
    writeFile(dir / "m.bin", "weights-v2")
    check m.verifyFiles(dir).len == 0                     # 默认不查
    let strict = m.verifyFiles(dir, initVerifyOptions(checkChecksums = true))
    check strict.len == 1
    check strict[0].kind == fikChecksumMismatch
    removeDir(dir)

  test "校验和为空表示未计算,不当作不匹配":
    let dir = makeTempDir()
    writeFile(dir / "m.xml", "<net/>")
    var m = initModelManifest("demo")
    m.files = @[ModelFile(path: "m.xml",
                          bytes: getFileSize(dir / "m.xml"), sha256: "")]
    m.entrypoints[EntrypointModel] = "m.xml"
    m.sourceDirectory = dir
    check m.verifyFiles(dir, initVerifyOptions(checkChecksums = true)).len == 0
    removeDir(dir)

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------

suite "模型库:路径与查找":

  test "空库的列举返回空列表而不是报错":
    # 首次运行的正常状态。
    let store = newModelStore(makeTempDir() / "nonexistent")
    check store.listIds().len == 0
    check store.listModels().len == 0

  test "配置里的 model_directory 覆盖默认位置":
    let root = makeTempDir()
    var s = defaultSettings()
    s.modelDirectory = root / "custom-models"
    let store = newModelStore(newIsvikPaths(root), s)
    check store.root == normalizedPath(absolutePath(root / "custom-models"))
    removeDir(root)

  test "model_directory 为空时用 ISVIK_HOME 下的 models":
    let root = makeTempDir()
    let store = newModelStore(newIsvikPaths(root), defaultSettings())
    check store.root == newIsvikPaths(root).models
    removeDir(root)

  test "非法 id 在解析目录时就被拒绝":
    let store = newModelStore(makeTempDir())
    for badId in ["../escape", "a/b", "CON", ""]:
      var code: IsvikErrorCode
      try:
        discard store.modelDirectory(badId)
        check false
      except IsvikError as e:
        code = e.code
      check code == ecInvalidParameter

  test "exists 以 manifest.json 为准,空目录不算模型":
    let root = makeTempDir()
    let store = newModelStore(root)
    createDir(root / "empty-dir")
    check not store.exists("empty-dir")
    check store.listIds().len == 0
    removeDir(root)

  test "读取不存在的模型抛 MODEL_NOT_FOUND":
    let store = newModelStore(makeTempDir())
    var code: IsvikErrorCode
    try:
      discard store.loadManifest("nosuch")
      check false
    except IsvikError as e:
      code = e.code
    check code == ecModelNotFound

suite "模型库:导入":

  test "引用模式导入:库里只有清单,文件留在原处":
    let source = makeTempDir()
    writeFakeIr(source, "openvino_model")
    let root = makeTempDir()
    let store = newModelStore(root)

    let m = store.importModel(source, initImportOptions("demo"))
    check m.id == "demo"
    check m.storage == skReferenced
    check m.sourceDirectory == normalizedPath(absolutePath(source))
    check m.files.len == 2
    check m.entrypoint(EntrypointModel) == "openvino_model.xml"

    # 库里只有 manifest.json,没有模型文件。
    check fileExists(root / "demo" / ManifestFileName)
    check not fileExists(root / "demo" / "openvino_model.bin")
    # 原文件仍在。
    check fileExists(source / "openvino_model.bin")

    let stored = store.load("demo")
    check stored.issues.len == 0
    check stored.contentDirectory == normalizedPath(absolutePath(source))
    removeDir(source)
    removeDir(root)

  test "复制模式导入:文件进库,内容目录就是库目录":
    let source = makeTempDir()
    writeFakeIr(source, "openvino_model")
    let root = makeTempDir()
    let store = newModelStore(root)

    var opts = initImportOptions("copied-demo", copyFiles = true)
    let m = store.importModel(source, opts)
    check m.storage == skCopied
    check fileExists(root / "copied-demo" / "openvino_model.bin")

    let stored = store.load("copied-demo")
    check stored.contentDirectory == stored.directory
    check stored.issues.len == 0
    removeDir(source)
    removeDir(root)

  test "导入不计算校验和,除非显式要求":
    let source = makeTempDir()
    writeFakeIr(source, "openvino_model")
    let store = newModelStore(makeTempDir())

    let lazy = store.importModel(source, initImportOptions("lazy"))
    for f in lazy.files:
      check f.sha256 == ""

    var opts = initImportOptions("strict")
    opts.computeChecksums = true
    let strict = store.importModel(source, opts)
    for f in strict.files:
      check f.sha256.len == 64
    removeDir(source)

  test "导入的模型一律没有已验证的设备":
    # 导入只是登记文件,没有验证任何设备(§13 / §27)。
    let source = makeTempDir()
    writeFakeIr(source, "openvino_model")
    let store = newModelStore(makeTempDir())
    let m = store.importModel(source, initImportOptions("fresh"))
    for d in m.deviceSupport:
      check not d.verified
    check not m.deviceSupportFor("NPU").verified
    removeDir(source)

  test "识别 tokenizer 与 detokenizer":
    let source = makeTempDir()
    writeFakeIr(source, "openvino_model")
    writeFakeIr(source, "openvino_tokenizer")
    writeFakeIr(source, "openvino_detokenizer")
    let store = newModelStore(makeTempDir())

    let m = store.importModel(source, initImportOptions("gemma-like"))
    check m.entrypoint(EntrypointModel) == "openvino_model.xml"
    check m.entrypoint(EntrypointTokenizer) == "openvino_tokenizer.xml"
    check m.entrypoint(EntrypointDetokenizer) == "openvino_detokenizer.xml"
    removeDir(source)

  test "识别本机 Gemma 4 E2B 的六个组件":
    # 文件名照抄本机 D:\Model\gemma-4-E2B-it-int4-ov 的实测清单。
    # 这组用例存在的理由是:最初的实现假设「一个模型一个 IR」,
    # 在这个目录上直接失败了。
    let source = makeTempDir()
    for stem in ["openvino_language_model",
                 "openvino_text_embeddings_model",
                 "openvino_text_embeddings_per_layer_model",
                 "openvino_vision_embeddings_model",
                 "openvino_tokenizer",
                 "openvino_detokenizer"]:
      writeFakeIr(source, stem)
    let store = newModelStore(makeTempDir())

    let m = store.importModel(source, initImportOptions("gemma4"))
    check m.entrypoint(EntrypointLanguageModel) ==
      "openvino_language_model.xml"
    check m.entrypoint(EntrypointTextEmbeddings) ==
      "openvino_text_embeddings_model.xml"
    check m.entrypoint(EntrypointVisionEmbeddings) ==
      "openvino_vision_embeddings_model.xml"
    check m.entrypoint(EntrypointTokenizer) == "openvino_tokenizer.xml"
    check m.entrypoint(EntrypointDetokenizer) == "openvino_detokenizer.xml"

    # 最关键的一条:PLE 不能被误认成普通 text_embeddings。
    # 两者文件名互为子串,判定顺序错了就会张冠李戴,而 PLE 是 2.19 GB、
    # 普通 embedding 是 384 MB —— 错误只会在推理时以形状不符暴露。
    check m.entrypoint(EntrypointTextEmbeddingsPerLayer) ==
      "openvino_text_embeddings_per_layer_model.xml"
    check m.entrypoint(EntrypointTextEmbeddings) !=
      m.entrypoint(EntrypointTextEmbeddingsPerLayer)

    check m.isComposite()
    check m.primaryRole() == EntrypointLanguageModel
    # 组合式结构本身就说明是文本生成,不需要猜。
    check m.task == mtTextGeneration
    removeDir(source)

  test "detokenizer 不被 tokenizer 规则抢走":
    let source = makeTempDir()
    writeFakeIr(source, "openvino_model")
    writeFakeIr(source, "openvino_detokenizer")
    let store = newModelStore(makeTempDir())
    let m = store.importModel(source, initImportOptions("deto"))
    check m.entrypoint(EntrypointDetokenizer) == "openvino_detokenizer.xml"
    check not m.hasEntrypoint(EntrypointTokenizer)
    removeDir(source)

  test "认不出主模型时报错,不猜一个":
    # 猜错会在编译阶段才暴露。
    let source = makeTempDir()
    writeFakeIr(source, "part_a")
    writeFakeIr(source, "part_b")
    let store = newModelStore(makeTempDir())
    var code: IsvikErrorCode
    var detail = ""
    try:
      discard store.importModel(source, initImportOptions("ambiguous"))
      check false
    except IsvikError as e:
      code = e.code
      detail = e.detail
    check code == ecModelInvalid
    # detail 必须列出认不出的具体文件名,而不是只给个数量。
    check detail.contains("part_a.xml")
    check detail.contains("part_b.xml")
    removeDir(source)

  test "唯一的未知 .xml 被当作单体模型":
    # 唯一候选不存在「猜错哪一个」的问题,是确定性规则。
    let source = makeTempDir()
    writeFakeIr(source, "my_custom_net")
    let store = newModelStore(makeTempDir())
    let m = store.importModel(source, initImportOptions("single"))
    check m.entrypoint(EntrypointModel) == "my_custom_net.xml"
    check not m.isComposite()
    removeDir(source)

  test "detectEntrypoints 单独可用,并报告认不出的文件":
    let files = @[
      ModelFile(path: "openvino_language_model.xml", bytes: 1, sha256: ""),
      ModelFile(path: "mystery_a.xml", bytes: 1, sha256: ""),
      ModelFile(path: "mystery_b.xml", bytes: 1, sha256: ""),
      ModelFile(path: "weights.bin", bytes: 1, sha256: "")
    ]
    let detected = detectEntrypoints(files)
    check detected.entrypoints.hasKey(EntrypointLanguageModel)
    check detected.unrecognized.len == 2
    # .bin 不参与入口判定。
    check "weights.bin" notin detected.unrecognized

  test "来源目录没有可识别文件时报错":
    let source = makeTempDir()
    writeFile(source / "README.md", "not a model")
    let store = newModelStore(makeTempDir())
    expect IsvikError:
      discard store.importModel(source, initImportOptions("empty"))
    removeDir(source)

  test "来源目录不存在时报 MODEL_NOT_FOUND":
    let store = newModelStore(makeTempDir())
    var code: IsvikErrorCode
    try:
      discard store.importModel(getTempDir() / "isvik_no_such_source_xyz",
                                initImportOptions("x"))
      check false
    except IsvikError as e:
      code = e.code
    check code == ecModelNotFound

  test "id 冲突时默认报错,overwrite 才允许覆盖":
    let source = makeTempDir()
    writeFakeIr(source, "openvino_model")
    let store = newModelStore(makeTempDir())
    discard store.importModel(source, initImportOptions("dup"))

    expect IsvikError:
      discard store.importModel(source, initImportOptions("dup"))

    var opts = initImportOptions("dup")
    opts.overwrite = true
    discard store.importModel(source, opts)   # 不应抛出
    removeDir(source)

  test "id 从目录名推导,并规范化为安全形式":
    check deriveModelId("D:/Model/gemma-4-E2B-it-int4-ov") ==
      "gemma-4-e2b-it-int4-ov"
    check deriveModelId("/models/My Model!!") == "my-model"
    check deriveModelId("C:/x/Qwen2.5_7B") == "qwen2.5_7b"

  test "推导出的 id 通过校验":
    for src in ["D:/Model/gemma-4-E2B-it-int4-ov", "/a/My Model", "/a/x__y"]:
      check validateModelId(deriveModelId(src)) == ""

  test "不带 id 导入时用推导结果":
    let base = makeTempDir()
    let source = base / "Gemma Test Model"
    writeFakeIr(source, "openvino_model")
    let store = newModelStore(makeTempDir())
    let m = store.importModel(source, initImportOptions())
    check m.id == "gemma-test-model"
    removeDir(base)

  test "非模型扩展名不进清单":
    let source = makeTempDir()
    writeFakeIr(source, "openvino_model")
    writeFile(source / "README.md", "docs")
    writeFile(source / "preview.png", "image")
    let store = newModelStore(makeTempDir())
    let m = store.importModel(source, initImportOptions("filtered"))
    var paths: seq[string] = @[]
    for f in m.files:
      paths.add(f.path)
    check "README.md" notin paths
    check "preview.png" notin paths
    check "openvino_model.xml" in paths
    removeDir(source)

suite "模型库:列举与状态":

  test "列举按 id 排序":
    let source = makeTempDir()
    writeFakeIr(source, "openvino_model")
    let store = newModelStore(makeTempDir())
    for id in ["zebra", "alpha", "middle"]:
      discard store.importModel(source, initImportOptions(id))
    check store.listIds() == @["alpha", "middle", "zebra"]
    removeDir(source)

  test "引用目录消失后被报告为不完整,而不是崩溃":
    let source = makeTempDir()
    writeFakeIr(source, "openvino_model")
    let store = newModelStore(makeTempDir())
    discard store.importModel(source, initImportOptions("orphan"))

    removeDir(source)          # 用户把模型目录删了 / 移走了
    let stored = store.load("orphan")
    check stored.issues.len == 1
    check stored.issues[0].kind == fikMissing
    check stored.issues[0].detail.contains("content directory")

  test "单个清单损坏不中断整个列举":
    # 否则一个坏清单会让 isvik list 完全不可用,而用户正需要它定位问题。
    let source = makeTempDir()
    writeFakeIr(source, "openvino_model")
    let root = makeTempDir()
    let store = newModelStore(root)
    discard store.importModel(source, initImportOptions("good"))

    createDir(root / "broken")
    writeFile(root / "broken" / ManifestFileName, "{ not valid json")

    let models = store.listModels()
    check models.len == 2
    var brokenSeen = false
    var goodSeen = false
    for m in models:
      if m.manifest.id == "broken":
        brokenSeen = true
        check m.issues.len > 0
        check m.manifest.notes.contains("manifest could not be loaded")
      if m.manifest.id == "good":
        goodSeen = true
        check m.issues.len == 0
    check brokenSeen
    check goodSeen
    removeDir(source)
    removeDir(root)

  test "目录名与清单 id 不一致时报错":
    # 目录被手工改名后,「用哪个 id」是歧义的。
    let root = makeTempDir()
    let store = newModelStore(root)
    var m = completeManifest("declared-id")
    createDir(root / "actual-dir")
    writeFile(root / "actual-dir" / ManifestFileName, m.toJson())

    var code: IsvikErrorCode
    try:
      discard store.loadManifest("actual-dir")
      check false
    except IsvikError as e:
      code = e.code
    check code == ecModelInvalid
    removeDir(root)

suite "模型库:删除":

  test "删除只移除库内目录,不触碰被引用的外部文件":
    # 删掉用户放在 D:\Model 的 4 GB 模型是不可接受的。
    let source = makeTempDir()
    writeFakeIr(source, "openvino_model")
    let root = makeTempDir()
    let store = newModelStore(root)
    discard store.importModel(source, initImportOptions("keepfiles"))

    store.removeModel("keepfiles")
    check not store.exists("keepfiles")
    check not dirExists(root / "keepfiles")
    # 外部文件必须还在。
    check fileExists(source / "openvino_model.bin")
    removeDir(source)
    removeDir(root)

  test "删除不存在的模型抛 MODEL_NOT_FOUND":
    let store = newModelStore(makeTempDir())
    var code: IsvikErrorCode
    try:
      store.removeModel("nosuch")
      check false
    except IsvikError as e:
      code = e.code
    check code == ecModelNotFound

  test "删除时拒绝穿越出模型库的 id":
    let store = newModelStore(makeTempDir())
    for badId in ["../..", "..", "a/../../b"]:
      expect IsvikError:
        store.removeModel(badId)

suite "设备验证结果回写":

  test "记录验证结果后 verified 为真,且能反复更新":
    # 这是唯一可以把 verified 置真的入口。
    let source = makeTempDir()
    writeFakeIr(source, "openvino_model")
    let store = newModelStore(makeTempDir())
    discard store.importModel(source, initImportOptions("verify-me"))

    check not store.loadManifest("verify-me").deviceSupportFor("CPU").verified

    store.recordDeviceVerification("verify-me", "CPU", supported = true,
                                   note = "端到端推理已通过")
    let after = store.loadManifest("verify-me")
    let cpu = after.deviceSupportFor("CPU")
    check cpu.verified
    check cpu.supported
    check cpu.note == "端到端推理已通过"

    # 记录一次失败的验证:supported 为 false 但 verified 仍为真 ——
    # 「试过了,不行」与「没试过」必须能区分。
    store.recordDeviceVerification("verify-me", "NPU", supported = false,
                                   note = "动态 shape 不受支持")
    let npu = store.loadManifest("verify-me").deviceSupportFor("NPU")
    check npu.verified
    check not npu.supported
    check npu.note.contains("动态 shape")
    removeDir(source)

  test "回写后的清单仍然合法":
    let source = makeTempDir()
    writeFakeIr(source, "openvino_model")
    let store = newModelStore(makeTempDir())
    discard store.importModel(source, initImportOptions("still-valid"))
    store.recordDeviceVerification("still-valid", "GPU", true)
    check store.loadManifest("still-valid").validate() == ""
    removeDir(source)

suite "清单写入":

  test "写入后能原样读回":
    let store = newModelStore(makeTempDir())
    var m = completeManifest("roundtrip")
    m.displayName = "往返测试"
    store.saveManifest(m)
    let back = store.loadManifest("roundtrip")
    check back.displayName == "往返测试"
    check back.files.len == 2

  test "写回旧 schema 时显式迁移到当前版本":
    let store = newModelStore(makeTempDir())
    var m = completeManifest("legacy")
    m.schemaVersion = 1
    store.saveManifest(m)
    let back = store.loadManifest("legacy")
    check back.schemaVersion == ManifestSchemaVersion
    check back.layout == mlUnknown

  test "拒绝写入非法清单":
    let store = newModelStore(makeTempDir())
    var m = completeManifest("bad")
    m.entrypoints.clear()
    expect IsvikError:
      store.saveManifest(m)

  test "覆盖写入不残留临时文件":
    let root = makeTempDir()
    let store = newModelStore(root)
    var m = completeManifest("overwrite")
    store.saveManifest(m)
    m.displayName = "第二版"
    store.saveManifest(m)
    check store.loadManifest("overwrite").displayName == "第二版"
    check not fileExists(root / "overwrite" / (ManifestFileName & ".tmp"))
    removeDir(root)
