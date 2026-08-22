## OpenVINO IR 模型契约检测。
##
## 检测只依据图的公开契约：Parameter / Result 端口、元素类型、rank，
## 以及 ReadValue / Assign 状态节点。目录名、模型名和 config.json 中的
## architecture/model_type 都不参与管线选择。

import std/[json, os, strutils, tables, xmlparser, xmltree]

import isvik/core/errors
import isvik/core/backend
import isvik/models/manifest

type
  IrPort* = object
    name*: string
    elementType*: string
    dims*: seq[int]

  ModelInspection* = object
    layout*: ModelLayout
    task*: ModelTask
    inputs*: seq[IrPort]
    outputs*: seq[IrPort]
    stateful*: bool
    readValueCount*: int
    assignCount*: int
    reason*: string

  ParsedShape = object
    present: bool
    valid: bool
    dims: seq[int]

  ParsedType = object
    present: bool
    valid: bool
    value: string

  IrOutputPort = object
    aliases: seq[string]
    elementType: string
    dims: seq[int]
    valid: bool

  IrLayer = object
    name: string
    kind: string
    outputPorts: Table[int, IrOutputPort]

  IrEdge = object
    fromLayer: int
    fromPort: int
    toLayer: int
    toPort: int

proc normalizeElementType(raw: string): string =
  ## IR 的 element_type 与 precision 使用过多种拼法。内部只保留稳定的
  ## OpenVINO 风格名称；未知类型返回空串，绝不参与契约匹配。
  case raw.strip().toLowerAscii()
  of "i64", "int64": "I64"
  of "i32", "int32": "I32"
  of "fp32", "f32", "float32": "F32"
  of "fp16", "f16", "float16": "F16"
  of "bf16", "bfloat16": "BF16"
  else: ""

proc parseInteger(raw: string, value: var int): bool =
  try:
    value = parseInt(raw)
    true
  except ValueError:
    false

proc parseDimension(raw: string, value: var int): bool =
  let text = raw.strip()
  if text == "?" or text == "-1":
    value = -1
    return true

  let rangeAt = text.find("..")
  if rangeAt >= 0:
    if text.find("..", rangeAt + 2) >= 0:
      return false
    let lower = text[0 ..< rangeAt].strip()
    let upper = text[rangeAt + 2 .. ^1].strip()
    if lower.len == 0 and upper.len == 0:
      return false
    for bound in [lower, upper]:
      if bound.len == 0 or bound == "?" or bound == "-1":
        continue
      var parsed = 0
      if not parseInteger(bound, parsed) or parsed < 0:
        return false
    value = -1
    return true

  if not parseInteger(text, value) or value < 0:
    return false
  true

proc parseShapeText(raw: string): ParsedShape =
  var text = raw.strip()
  if text.len == 0:
    return ParsedShape(present: false, valid: false, dims: @[])
  result.present = true
  if text.startsWith("[") or text.endsWith("]"):
    if not (text.startsWith("[") and text.endsWith("]")) or text.len < 2:
      return
    text = text[1 ..< text.high].strip()
  if text.len == 0:
    return
  for part in text.split(','):
    var dim = 0
    if not parseDimension(part, dim):
      result.dims.setLen(0)
      return
    result.dims.add(dim)
  result.valid = result.dims.len > 0

proc parseNodeShape(node: XmlNode): ParsedShape =
  if node.isNil or node.kind != xnElement:
    return
  var sawDim = false
  var dims: seq[int] = @[]
  for child in node:
    if child.kind == xnElement and child.tag == "dim":
      sawDim = true
      var dim = 0
      if not parseDimension(child.innerText, dim):
        return ParsedShape(present: true, valid: false, dims: @[])
      dims.add(dim)
  if sawDim:
    return ParsedShape(present: true, valid: dims.len > 0, dims: dims)
  parseShapeText(node.attr("shape"))

proc parseNodeType(node: XmlNode): ParsedType =
  if node.isNil or node.kind != xnElement:
    return
  var raw = node.attr("element_type")
  if raw.len == 0:
    raw = node.attr("precision")
  if raw.len == 0:
    return
  result.present = true
  result.value = normalizeElementType(raw)
  result.valid = result.value.len > 0

proc addAliases(aliases: var seq[string], raw: string) =
  for item in raw.split(','):
    let alias = item.strip()
    if alias.len > 0 and alias notin aliases:
      aliases.add(alias)

proc parsePortId(node: XmlNode, value: var int): bool =
  node != nil and parseInteger(node.attr("id"), value) and value >= 0

proc parseOutputPort(node: XmlNode): IrOutputPort =
  addAliases(result.aliases, node.attr("names"))
  let parsedType = parseNodeType(node)
  let parsedShape = parseNodeShape(node)
  result.valid = parsedType.present and parsedType.valid and
    parsedShape.present and parsedShape.valid
  if result.valid:
    result.elementType = parsedType.value
    result.dims = parsedShape.dims

proc mergeParameterMetadata(dataNode, portNode: XmlNode): IrOutputPort =
  ## Parameter 的 data 与 output/port 都可能携带 metadata。任一处明确给出
  ## malformed/unknown 值或两处冲突，都使该公开端口不可用于分类。
  result = parseOutputPort(portNode)
  let dataType = parseNodeType(dataNode)
  let portType = parseNodeType(portNode)
  let dataShape = parseNodeShape(dataNode)
  let portShape = parseNodeShape(portNode)

  result.valid = true
  if dataType.present and not dataType.valid:
    result.valid = false
  if portType.present and not portType.valid:
    result.valid = false
  if dataType.present and portType.present and dataType.valid and
      portType.valid and dataType.value != portType.value:
    result.valid = false
  if portType.present and portType.valid:
    result.elementType = portType.value
  elif dataType.present and dataType.valid:
    result.elementType = dataType.value
  else:
    result.valid = false

  if dataShape.present and not dataShape.valid:
    result.valid = false
  if portShape.present and not portShape.valid:
    result.valid = false
  if dataShape.present and portShape.present and dataShape.valid and
      portShape.valid and dataShape.dims != portShape.dims:
    result.valid = false
  if portShape.present and portShape.valid:
    result.dims = portShape.dims
  elif dataShape.present and dataShape.valid:
    result.dims = dataShape.dims
  else:
    result.valid = false

proc addIrPort(ports: var seq[IrPort], name, elementType: string,
               dims: seq[int]) =
  if name.len == 0:
    return
  for port in ports:
    if port.name == name and port.elementType == elementType and
        port.dims == dims:
      return
  ports.add(IrPort(name: name, elementType: elementType, dims: dims))

proc hasTypedRank(ports: openArray[IrPort], name: string,
                  allowedTypes: openArray[string], rank: int): bool =
  for port in ports:
    if port.name == name and port.dims.len == rank and
        port.elementType in allowedTypes:
      return true
  false

proc optionalBeamIsValid(inputs: openArray[IrPort]): bool =
  result = true
  for port in inputs:
    if port.name == "beam_idx" and
        (port.elementType != "I32" or port.dims.len != 1):
      return false

proc optionalTokenTypeIdsIsValid(inputs: openArray[IrPort]): bool =
  result = true
  for port in inputs:
    if port.name == "token_type_ids" and
        (port.elementType != "I64" or port.dims.len != 2):
      return false

proc optionalPerLayerInputsIsValid(inputs: openArray[IrPort]): bool =
  ## 该端口由独立 per-layer embeddings IR 产生。静态 0 维是合法的空
  ## tensor 契约，不能误判为 malformed；这里只验证可证明的 type/rank。
  result = true
  for port in inputs:
    if port.name == "per_layer_inputs" and
        (port.elementType != "F32" or port.dims.len != 4):
      return false

proc isFloat(elementType: string): bool =
  elementType in ["F32", "F16", "BF16"]

proc kvSuffix(name, prefix: string): string =
  name[prefix.len .. ^1]

proc externalKvContract(inputs, outputs: openArray[IrPort],
                        invalidInputAliases: openArray[string],
                        hasAnyKv: var bool): bool =
  var past = initTable[string, IrPort]()
  var present = initTable[string, IrPort]()
  var valid = true

  for alias in invalidInputAliases:
    if alias.startsWith("past_key_values."):
      hasAnyKv = true
      valid = false

  for port in inputs:
    if port.name.startsWith("past_key_values."):
      hasAnyKv = true
      let suffix = kvSuffix(port.name, "past_key_values")
      if not port.elementType.isFloat or port.dims.len < 3:
        valid = false
      elif past.hasKey(suffix):
        if past[suffix].elementType != port.elementType or
            past[suffix].dims.len != port.dims.len:
          valid = false
      else:
        past[suffix] = port

  for port in outputs:
    if port.name.startsWith("present."):
      hasAnyKv = true
      let suffix = kvSuffix(port.name, "present")
      if not port.elementType.isFloat or port.dims.len < 3:
        valid = false
      elif present.hasKey(suffix):
        if present[suffix].elementType != port.elementType or
            present[suffix].dims.len != port.dims.len:
          valid = false
      else:
        present[suffix] = port

  if not valid or past.len == 0 or present.len == 0 or
      past.len != present.len:
    return false
  for suffix, pastPort in past:
    if not present.hasKey(suffix):
      return false
    let presentPort = present[suffix]
    if presentPort.elementType != pastPort.elementType or
        presentPort.dims.len != pastPort.dims.len:
      return false
  true

proc inspectOpenVinoIr*(path: string): ModelInspection =
  ## 从 XML 树读取公开 IR 契约。Result 只接受唯一 incoming edge 指定的
  ## source output port；friendly name 和全图中的其它 logits 都不是输出。
  if not fileExists(path):
    raiseIsvikError(ecModelNotFound, "Model IR file was not found",
                    "path=" & path)

  let raw =
    try:
      readFile(path)
    except IOError as e:
      raiseIsvikError(ecModelInvalid, "Failed to read model IR",
                      "path=" & path & " io=" & e.msg)

  let root =
    try:
      parseXml(raw)
    except XmlError as e:
      raiseIsvikError(ecModelInvalid, "Failed to parse model IR XML",
                      "path=" & path & " xml=" & e.msg)

  result = ModelInspection(
    layout: mlUnknown, task: mtUnknown, inputs: @[], outputs: @[],
    stateful: false, readValueCount: 0, assignCount: 0, reason: "")

  if root.isNil or root.kind != xnElement or root.tag != "net":
    result.reason = "malformed OpenVINO IR: root element is not <net>"
    return
  let layersNode = root.child("layers")
  let edgesNode = root.child("edges")
  if layersNode.isNil or edgesNode.isNil:
    result.reason = "malformed OpenVINO IR: missing layers or edges"
    return

  var layers = initTable[int, IrLayer]()
  var resultLayerIds: seq[int] = @[]
  var invalidParameterAliases: seq[string] = @[]
  var edges: seq[IrEdge] = @[]
  var structuralIssue = false

  for layerNode in layersNode:
    if layerNode.kind != xnElement or layerNode.tag != "layer":
      continue
    var layerId = 0
    if not parseInteger(layerNode.attr("id"), layerId) or layerId < 0 or
        layers.hasKey(layerId):
      structuralIssue = true
      continue

    let layerType = layerNode.attr("type")
    var layer = IrLayer(
      name: layerNode.attr("name"), kind: layerType,
      outputPorts: initTable[int, IrOutputPort]())
    let outputNode = layerNode.child("output")
    if not outputNode.isNil:
      for portNode in outputNode:
        if portNode.kind != xnElement or portNode.tag != "port":
          continue
        var portId = 0
        if not parsePortId(portNode, portId) or layer.outputPorts.hasKey(portId):
          structuralIssue = true
          continue
        layer.outputPorts[portId] = parseOutputPort(portNode)

    layers[layerId] = layer
    case layerType
    of "Parameter":
      let dataNode = layerNode.child("data")
      if outputNode.isNil:
        structuralIssue = true
        continue
      for portNode in outputNode:
        if portNode.kind != xnElement or portNode.tag != "port":
          continue
        var portId = 0
        if not parsePortId(portNode, portId):
          continue
        var parameter = mergeParameterMetadata(dataNode, portNode)
        addAliases(parameter.aliases, layer.name)
        if parameter.valid:
          for alias in parameter.aliases:
            result.inputs.addIrPort(alias, parameter.elementType, parameter.dims)
        else:
          for alias in parameter.aliases:
            if alias notin invalidParameterAliases:
              invalidParameterAliases.add(alias)
    of "Result":
      resultLayerIds.add(layerId)
    of "ReadValue":
      inc result.readValueCount
    of "Assign":
      inc result.assignCount
    else:
      discard

  for edgeNode in edgesNode:
    if edgeNode.kind != xnElement or edgeNode.tag != "edge":
      continue
    var edge: IrEdge
    if not parseInteger(edgeNode.attr("from-layer"), edge.fromLayer) or
        not parseInteger(edgeNode.attr("from-port"), edge.fromPort) or
        not parseInteger(edgeNode.attr("to-layer"), edge.toLayer) or
        not parseInteger(edgeNode.attr("to-port"), edge.toPort) or
        edge.fromLayer < 0 or edge.fromPort < 0 or edge.toLayer < 0 or
        edge.toPort < 0:
      structuralIssue = true
      continue
    edges.add(edge)

  for resultId in resultLayerIds:
    var incoming: seq[IrEdge] = @[]
    for edge in edges:
      if edge.toLayer == resultId:
        incoming.add(edge)
    if incoming.len != 1:
      structuralIssue = true
      continue
    let edge = incoming[0]
    if not layers.hasKey(edge.fromLayer) or
        not layers[edge.fromLayer].outputPorts.hasKey(edge.fromPort):
      structuralIssue = true
      continue
    let sourcePort = layers[edge.fromLayer].outputPorts[edge.fromPort]
    if not sourcePort.valid or sourcePort.aliases.len == 0:
      structuralIssue = true
      continue
    for alias in sourcePort.aliases:
      result.outputs.addIrPort(alias, sourcePort.elementType, sourcePort.dims)

  result.stateful = result.readValueCount > 0 and result.assignCount > 0

  const IntegerTypes = ["I64", "I32"]
  const FloatTypes = ["F32", "F16", "BF16"]
  let beamContractValid = result.inputs.optionalBeamIsValid() and
    "beam_idx" notin invalidParameterAliases
  let tokenTypeIdsContractValid =
    result.inputs.optionalTokenTypeIdsIsValid() and
    "token_type_ids" notin invalidParameterAliases
  let perLayerInputsContractValid =
    result.inputs.optionalPerLayerInputsIsValid() and
    "per_layer_inputs" notin invalidParameterAliases
  let controlsAndLogits =
    result.inputs.hasTypedRank("attention_mask", IntegerTypes, 2) and
    result.inputs.hasTypedRank("position_ids", IntegerTypes, 2) and
    result.outputs.hasTypedRank("logits", FloatTypes, 3) and
    beamContractValid and tokenTypeIdsContractValid and
    perLayerInputsContractValid
  let monolithicCore =
    result.inputs.hasTypedRank("input_ids", IntegerTypes, 2) and
    controlsAndLogits
  let compositeCore =
    result.inputs.hasTypedRank("inputs_embeds", FloatTypes, 3) and
    controlsAndLogits

  var hasAnyKv = false
  let hasPairedExternalKv = result.inputs.externalKvContract(
    result.outputs, invalidParameterAliases, hasAnyKv)

  if not structuralIssue and hasAnyKv and monolithicCore and
      hasPairedExternalKv:
    result.layout = mlExternalKvCausalLm
    result.task = mtTextGeneration
    result.reason = "causal LM with type/rank-matched external KV-cache pairs"
  elif not structuralIssue and not hasAnyKv and result.stateful and compositeCore:
    result.layout = mlCompositeEmbeddingCausalLm
    result.task = mtTextGeneration
    result.reason =
      "stateful float rank-3 inputs_embeds + integer rank-2 controls -> float rank-3 logits"
  elif not structuralIssue and not hasAnyKv and result.stateful and monolithicCore:
    result.layout = mlMonolithicTokenCausalLm
    result.task = mtTextGeneration
    result.reason =
      "stateful integer rank-2 input_ids and controls -> float rank-3 logits"
  else:
    var inputContracts: seq[string] = @[]
    var outputContracts: seq[string] = @[]
    for port in result.inputs:
      inputContracts.add(port.name & ":" & port.elementType &
        "/rank" & $port.dims.len)
    for port in result.outputs:
      outputContracts.add(port.name & ":" & port.elementType &
        "/rank" & $port.dims.len)
    result.reason = "unrecognized IR contract: inputs=" &
      inputContracts.join(",") & " outputs=" & outputContracts.join(",")
    if structuralIssue:
      result.reason.add(" structural_metadata=incomplete")
    elif hasAnyKv and not hasPairedExternalKv:
      result.reason.add(" external_kv=unpaired_or_mismatched")

proc inspectionNote*(inspection: ModelInspection): string =
  ## 适合写入 manifest 的稳定摘要，不包含绝对路径或模型架构猜测。
  "layout=" & $inspection.layout &
    " stateful=" & $inspection.stateful &
    " read_values=" & $inspection.readValueCount &
    " assigns=" & $inspection.assignCount &
    " contract=" & inspection.reason

proc declaredContextLength*(modelDir: string): int =
  ## 读取模型随附配置中明确声明的上下文长度。只把正整数当作约束；缺失或
  ## 非法时返回 0，调用方不得据此猜测 NPU shape。
  for candidate in [
      (modelDir / "tokenizer_config.json", @["model_max_length"]),
      (modelDir / "config.json", @["max_position_embeddings", "n_positions"])
    ]:
    if not fileExists(candidate[0]):
      continue
    try:
      let node = parseJson(readFile(candidate[0]))
      if node.kind != JObject:
        continue
      for key in candidate[1]:
        if node.hasKey(key) and node[key].kind == JInt:
          let value = node[key].getInt
          if value > 0 and value < 1_000_000:
            return value
    except CatchableError:
      discard
  0

proc causalLmBoundedShapes*(inspection: ModelInspection,
                            contextLength: int): seq[ModelInputShape] =
  ## 由 IR 端口与明确 context 声明组成 bounded partial shapes。
  ## contextLength <= 0 时返回空，拒绝从 ShapeOf 或架构名猜上界。
  if contextLength <= 0:
    return @[]
  let batch = ModelDimension(minimum: 1, maximum: 1)
  let sequence = ModelDimension(minimum: 1, maximum: contextLength)
  for port in inspection.inputs:
    case port.name
    of "input_ids", "attention_mask", "position_ids", "token_type_ids":
      result.add(ModelInputShape(name: port.name, dims: @[batch, sequence]))
    of "beam_idx":
      result.add(ModelInputShape(name: port.name, dims: @[batch]))
    else:
      discard

proc causalLmNpuStaticShapes*(inspection: ModelInspection,
                              contextLength: int): seq[ModelInputShape] =
  ## Stateful token LM 的 NPU 静态执行契约：每次推进一个 token，固定长度
  ## attention_mask 用 1 标记已消费前缀、其余位置为 0。
  if contextLength <= 0:
    return @[]
  let one = ModelDimension(minimum: 1, maximum: 1)
  let context = ModelDimension(minimum: contextLength, maximum: contextLength)
  for port in inspection.inputs:
    case port.name
    of "input_ids", "position_ids", "token_type_ids":
      result.add(ModelInputShape(name: port.name, dims: @[one, one]))
    of "attention_mask":
      result.add(ModelInputShape(name: port.name, dims: @[one, context]))
    of "beam_idx":
      result.add(ModelInputShape(name: port.name, dims: @[one]))
    else:
      discard

proc manifestShapeConstraints*(shapes: openArray[ModelInputShape]):
    seq[ShapeConstraint] =
  ## 只转换完全静态的真实 reshape 契约；动态区间不会被伪装成精确维度。
  for shape in shapes:
    var dims: seq[int] = @[]
    var isStatic = true
    for dim in shape.dims:
      if dim.minimum != dim.maximum:
        isStatic = false
        break
      dims.add(dim.minimum)
    if isStatic:
      result.add(ShapeConstraint(port: shape.name, dims: dims))
