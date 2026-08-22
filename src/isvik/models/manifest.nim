## Model Manifest(Master Prompt §54 / §15)
##
## ---
##
## ## 它必须能表达什么
##
## DEVLOG 第六节记录了一条硬约束:**模型能否上 NPU 是模型属性,不是运行时偏好。**
## NPU 对动态 shape 的支持有限,而 LLM 的自回归解码天然是动态的。如果 manifest
## 无法表达「该模型在 NPU 上要求静态 shape、具体约束是什么」,那么推理编排就只能
## 先编译再失败,而不能在编译前判断可行性。
##
## 因此 `DeviceSupport` 是 manifest 的一等字段,而不是备注里的一句话。
##
## ---
##
## ## verified 默认为 false,且不由代码自动置真
##
## `DeviceSupport.verified` 表示「**真的在该设备上跑过**」。它:
##
## - 导入模型时一律为 false —— 导入只是登记文件,没有验证任何设备
## - 只有真实跑通编译 / 推理后才可以由调用方显式置真
##
## 这条是 §13 / §27「不得伪造硬件状态」在 manifest 层的落实。一个
## `supported: true, verified: false` 的条目含义是「声称支持,但本机没验证过」,
## 与「已验证可用」必须能区分开。
##
## ---
##
## ## 存储方式:引用 vs 复制
##
## ```text
## referenced   文件留在原处,manifest 记绝对路径
## copied       文件已复制进模型库
## ```
##
## 引用模式不是省事,而是必需:本机的 Gemma 4 E2B 有 4.06 GB,把它复制进
## `~/.isvik/models` 只是让同一份数据占两倍磁盘。用户已明确把模型放在
## `D:\Model\` 之外的位置,引用模式尊重这个选择。
##
## 代价是引用的目录可能被移动或删除,因此 `verifyFiles` 必须能报告缺失。
##
## ---
##
## ## 校验和的用途边界
##
## 用 `util/checksum` 的 SHA-256(自实现,已用 FIPS 180-4 官方向量验证)。
## 它的目的是**检测损坏**(下载截断、磁盘坏块、复制中断、位翻转),
## **不是防篡改** —— 攻击者若能改文件,同样能改清单里的哈希。
##
## 防篡改需要签名(哈希 + 可信公钥),换算法解决不了信任问题。

import std/[json, tables, strutils, times, os, options, sequtils]

import isvik/core/errors
import isvik/config/paths
import isvik/util/checksum

type
  ModelFormat* = enum
    ## 模型格式。字符串值是稳定契约,出现在 manifest 与 API 中。
    mfOpenVinoIr = "openvino-ir"
    mfOnnx = "onnx"

  ModelTask* = enum
    ## 模型任务类型。
    ##
    ## 有意保持很小:只列当前真正能处理的任务。声明了却不支持比不声明更糟
    ## (§20.5.13 第 12 条的同一原则)。`unknown` 用于导入时无法判定的情况,
    ## 不猜。
    mtTextGeneration = "text-generation"
    mtTextEmbedding = "text-embedding"
    mtUnknown = "unknown"

  ModelLayout* = enum
    ## 主模型的执行契约。由 IR 端口和状态节点检测，不按架构名猜测。
    mlUnknown = "unknown"
    mlMonolithicTokenCausalLm = "monolithic-token-causal-lm"
      ## input_ids 直接进入单体 causal LM，KV-cache 通常是内部状态。
    mlCompositeEmbeddingCausalLm = "composite-embedding-causal-lm"
      ## token 先经过外部 embeddings，再送入 inputs_embeds。
    mlExternalKvCausalLm = "external-kv-causal-lm"
      ## past_key_values / present 是公开端口；当前尚未实现执行器。

  StorageKind* = enum
    ## 模型文件的存放方式。见模块顶部说明。
    skReferenced = "referenced"
    skCopied = "copied"

  ShapeConstraint* = object
    ## 某个输入端口在某设备上的形状约束。
    ##
    ## `dims` 中 `-1` 表示该维动态。全部为正数即完全静态。
    port*: string
    dims*: seq[int]

  DeviceSupport* = object
    ## 该模型在某个**语义设备**(CPU / GPU / NPU)上的支持情况。
    device*: string
    supported*: bool
      ## 声称支持。不等于已验证 —— 见 `verified`。
    requiresStaticShape*: bool
      ## 该设备上是否必须使用静态 shape。
      ##
      ## NPU 通常为 true。这个字段的存在使推理编排能在**编译前**判断
      ## 「这个模型能不能上这个设备」,而不是编译失败后才知道。
    shapeConstraints*: seq[ShapeConstraint]
      ## 具体的形状约束。`requiresStaticShape` 为 true 时应给出。
    verified*: bool
      ## **是否真的在该设备上跑通过。** 导入时一律 false(§13 / §27)。
    note*: string
      ## 补充说明,例如「NPU 上需分块处理」。

  ModelFile* = object
    ## 模型的一个组成文件。
    path*: string
      ## 相对模型根目录的路径。始终用 `/` 分隔,跨平台一致。
    bytes*: int64
    sha256*: string
      ## 内容校验和(SHA-256,十六进制小写)。
      ##
      ## 空字符串表示**未计算**,不是「计算结果为空」—— 两者必须能区分,
      ## 否则校验时会把「没算过」误报成「不匹配」。

  ModelManifest* = object
    ## 模型清单。
    schemaVersion*: int
    id*: string
      ## 稳定标识,同时用作模型库中的目录名,因此必须是文件系统安全的单段名。
    displayName*: string
    version*: string
    format*: ModelFormat
    task*: ModelTask
    layout*: ModelLayout
      ## 主 IR 的执行布局。旧清单缺失时为 unknown，由加载器重新检测。
    storage*: StorageKind
    sourceDirectory*: string
      ## `referenced` 模式下模型文件所在的绝对目录。
      ## `copied` 模式下记录导入来源,仅供追溯。
    entrypoints*: Table[string, string]
      ## 关键文件的角色到相对路径的映射。
      ## 约定键见 `EntrypointModel` 等常量。
    files*: seq[ModelFile]
    deviceSupport*: seq[DeviceSupport]
    importedAt*: string
      ## ISO-8601 UTC 时间戳。
    notes*: string

const
  ManifestSchemaVersion* = 2
    ## 当前 manifest 结构版本。
    ##
    ## 读取时只接受 `<=` 这个值:更高版本可能含本程序不认识的必需字段,
    ## 按旧规则解析会得到一个看似成功却缺信息的结果。

  ManifestFileName* = "manifest.json"
    ## 模型目录下清单文件的固定名称。

  ## ## 入口角色:为什么不是「一个模型文件」
  ##
  ## 最初的设计假设一个模型就是一个 IR 文件。**本机的 Gemma 4 E2B 直接证伪了
  ## 这个假设** —— 它的目录里有六个独立 IR:
  ##
  ## ```text
  ## openvino_language_model.xml                    1315.7 MB   自回归解码主体
  ## openvino_text_embeddings_model.xml              384.5 MB   token → 向量
  ## openvino_text_embeddings_per_layer_model.xml   2240.5 MB   PLE
  ## openvino_vision_embeddings_model.xml            161.2 MB   图像编码
  ## openvino_tokenizer.xml                           16.5 MB
  ## openvino_detokenizer.xml                          4.2 MB
  ## ```
  ##
  ## 注意 PLE 那个 2.19 GB,**比语言模型主体还大**,占整个模型一半以上 ——
  ## 它不是可忽略的旁路,推理编排必须正确用上它。
  ##
  ## 因此入口是「角色 → 相对路径」的映射,而不是单个字段。单体模型用
  ## `model`,组合式模型用 `language_model` 等具体角色。
  EntrypointModel* = "model"
    ## 单体模型的主 IR / ONNX。非组合式模型用这个角色。
  EntrypointLanguageModel* = "language_model"
    ## 组合式 LLM 的语言模型主体(自回归解码在这里发生)。
  EntrypointTextEmbeddings* = "text_embeddings"
    ## token id → 向量的查表子模型。
  EntrypointTextEmbeddingsPerLayer* = "text_embeddings_per_layer"
    ## Per-Layer Embeddings(Gemma 系列特有)。
  EntrypointVisionEmbeddings* = "vision_embeddings"
    ## 图像编码子模型(多模态模型才有)。
  EntrypointTokenizer* = "tokenizer"
    ## tokenizer IR(OpenVINO tokenizer 转换产物,输入输出是 STRING 张量)。
  EntrypointDetokenizer* = "detokenizer"
    ## detokenizer IR。

  KnownEntrypoints*: array[7, string] = [
    ## 输出顺序刻意从「主体」到「附属」,使 manifest 与 `isvik info` 的
    ## 展示都先看到最重要的那个。
    EntrypointModel,
    EntrypointLanguageModel,
    EntrypointTextEmbeddings,
    EntrypointTextEmbeddingsPerLayer,
    EntrypointVisionEmbeddings,
    EntrypointTokenizer,
    EntrypointDetokenizer
  ]

  PrimaryEntrypoints*: array[2, string] = [
    ## 可作为「主模型」的角色。清单必须至少声明其中之一。
    EntrypointModel, EntrypointLanguageModel
  ]

  SemanticDeviceNames*: array[3, string] = ["CPU", "GPU", "NPU"]
    ## `DeviceSupport.device` 的合法取值。
    ##
    ## 刻意**不含 AUTO**:AUTO 是选择策略,不是设备,「模型在 AUTO 上是否
    ## 支持」这句话没有意义。

# ---------------------------------------------------------------------------
# 构造
# ---------------------------------------------------------------------------

proc nowIso8601*(): string =
  ## 当前 UTC 时间的 ISO-8601 表示,秒精度。
  ##
  ## 与事件时间戳保持同一形状,便于交叉比对日志与 manifest。
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc initModelManifest*(id: string, format: ModelFormat = mfOpenVinoIr):
    ModelManifest =
  ## 构造一个最小可用的 manifest。
  ##
  ## `task` 默认 `unknown` 而不是猜一个 —— 导入时并不知道模型是做什么的。
  ModelManifest(
    schemaVersion: ManifestSchemaVersion,
    id: id,
    displayName: "",
    version: "",
    format: format,
    task: mtUnknown,
    layout: mlUnknown,
    storage: skReferenced,
    sourceDirectory: "",
    entrypoints: initTable[string, string](),
    files: @[],
    deviceSupport: @[],
    importedAt: nowIso8601(),
    notes: ""
  )

proc initDeviceSupport*(device: string, supported: bool = true,
                        requiresStaticShape: bool = false): DeviceSupport =
  ## 构造设备支持条目。`verified` 恒为 false —— 构造不等于验证。
  DeviceSupport(
    device: device,
    supported: supported,
    requiresStaticShape: requiresStaticShape,
    shapeConstraints: @[],
    verified: false,
    note: ""
  )

proc isStatic*(c: ShapeConstraint): bool =
  ## 该约束是否完全静态(没有任何 -1 维)。
  for d in c.dims:
    if d < 0:
      return false
  result = true

# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

proc displayLabel*(m: ModelManifest): string =
  ## 面向用户的名称。`displayName` 为空时回落到 id。
  ##
  ## 这不是伪造:id 是真实存在的标识,而不是编造的型号名。
  if m.displayName.len > 0: m.displayName else: m.id

proc totalBytes*(m: ModelManifest): int64 =
  for f in m.files:
    result += f.bytes

proc entrypoint*(m: ModelManifest, role: string): string =
  ## 取某个角色的相对路径。不存在时返回空字符串。
  if m.entrypoints.hasKey(role): m.entrypoints[role] else: ""

proc hasEntrypoint*(m: ModelManifest, role: string): bool =
  m.entrypoints.hasKey(role) and m.entrypoints[role].len > 0

proc primaryRole*(m: ModelManifest): string =
  ## 该模型的主模型角色。没有时返回空字符串。
  ##
  ## 单体模型是 `model`,组合式 LLM 是 `language_model`。调用方不必自己
  ## 判断模型是哪种形态。
  for role in PrimaryEntrypoints:
    if m.hasEntrypoint(role):
      return role
  result = ""

proc primaryEntrypoint*(m: ModelManifest): string =
  ## 主模型的相对路径。没有时返回空字符串。
  let role = m.primaryRole()
  if role.len == 0: "" else: m.entrypoint(role)

proc isComposite*(m: ModelManifest): bool =
  ## 是否为组合式模型(由多个 IR 协同工作)。
  ##
  ## 判据是「声明了 language_model」而不是「文件数 > 1」——
  ## 单体模型也有 .xml + .bin 两个文件。
  m.hasEntrypoint(EntrypointLanguageModel)

proc deviceSupportFor*(m: ModelManifest, device: string): DeviceSupport =
  ## 查某设备的支持条目。
  ##
  ## **没有条目时返回 `supported: false`**,而不是默认支持。
  ## 默认支持会让「manifest 没写」被当成「可以跑」,而后者需要证据。
  for d in m.deviceSupport:
    if d.device == device:
      return d
  result = DeviceSupport(
    device: device,
    supported: false,
    requiresStaticShape: false,
    shapeConstraints: @[],
    verified: false,
    note: "no device support entry in manifest"
  )

proc requiresStaticShapeOn*(m: ModelManifest, device: string): bool =
  ## 该模型在指定设备上是否要求静态 shape。
  m.deviceSupportFor(device).requiresStaticShape

# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------

proc validateModelId*(id: string): string =
  ## 校验模型 id。返回空字符串表示合法,否则返回原因。
  ##
  ## id 同时用作目录名,因此必须通过 §38 的路径安全校验,且必须是**单段** ——
  ## `a/b` 会在模型库里造出嵌套目录,破坏「一个目录一个模型」的假设。
  if id.len == 0:
    return "model id must not be empty"
  if '/' in id or '\\' in id:
    return "model id must be a single path segment"
  let problem = checkRelativePath(id)
  if problem.isSome:
    return "model id is not a safe path segment: " & problem.get
  result = ""

proc validate*(m: ModelManifest): string =
  ## 校验 manifest。返回空字符串表示合法,否则返回第一个问题的描述。
  ##
  ## 返回原因字符串而不是布尔:调用方要能告诉用户**哪里**不对。
  let idProblem = validateModelId(m.id)
  if idProblem.len > 0:
    return idProblem

  if m.schemaVersion <= 0:
    return "schemaVersion must be positive, got: " & $m.schemaVersion
  if m.schemaVersion > ManifestSchemaVersion:
    return "manifest schemaVersion " & $m.schemaVersion &
      " is newer than supported version " & $ManifestSchemaVersion

  if m.storage == skReferenced and m.sourceDirectory.strip().len == 0:
    return "referenced storage requires a non-empty sourceDirectory"

  # 必须有一个主模型角色。组合式模型用 language_model,单体模型用 model。
  if m.primaryRole().len == 0:
    return "manifest must declare one of these entrypoints: " &
      PrimaryEntrypoints.join(", ")

  for role in m.entrypoints.keys:
    if role notin KnownEntrypoints:
      return "unknown entrypoint role: " & role

  # entrypoint 必须指向 files 中登记过的文件。否则「清单说有 tokenizer」
  # 与「清单里没这个文件」会同时成立,而使用时才发现。
  var declared: seq[string] = @[]
  for f in m.files:
    declared.add(f.path)
  for role, rel in m.entrypoints:
    if rel.len == 0:
      return "entrypoint '" & role & "' has an empty path"
    if rel notin declared:
      return "entrypoint '" & role & "' points to a file that is not listed: " & rel

  for f in m.files:
    if f.path.len == 0:
      return "file entry has an empty path"
    let fileProblem = checkRelativePath(f.path)
    if fileProblem.isSome:
      return "unsafe file path in manifest: " & f.path & " (" & fileProblem.get & ")"
    if f.bytes < 0:
      return "file size must not be negative: " & f.path

  for d in m.deviceSupport:
    if d.device notin SemanticDeviceNames:
      return "deviceSupport.device must be one of " &
        SemanticDeviceNames.join(", ") & ", got: " & d.device
    # 声明「要求静态 shape」却不给约束,等于没给出可用信息。
    if d.requiresStaticShape and d.shapeConstraints.len == 0:
      return "device " & d.device &
        " requires static shape but declares no shapeConstraints"
    for c in d.shapeConstraints:
      if c.port.len == 0:
        return "shapeConstraint on device " & d.device & " has an empty port name"
      if c.dims.len == 0:
        return "shapeConstraint for port " & c.port & " has no dimensions"
      for dim in c.dims:
        if dim == 0 or dim < -1:
          return "invalid dimension " & $dim & " for port " & c.port &
            " (use -1 for dynamic, positive for fixed)"
    # 刻意**不**拒绝 `verified && not supported`。
    #
    # `supported` 与 `verified` 是两个独立的事实,四种组合都有意义:
    #
    # ```text
    # supported=false verified=false   没试过,也不声称支持
    # supported=false verified=true    试过了,确实不行     ← 最有价值的一种
    # supported=true  verified=false   声称支持,本机未验证
    # supported=true  verified=true    已验证可用
    # ```
    #
    # 第二种如果被当成非法,那么「在 NPU 上实测失败」这个结论就无处记录,
    # 下一次还得再试一遍。区分「没试过」与「试过不行」正是 §13 的要求。

  result = ""

proc requireValid*(m: ModelManifest) =
  ## 校验失败时抛 IsvikError(MODEL_INVALID)。
  let problem = m.validate()
  if problem.len > 0:
    raiseIsvikError(
      ecModelInvalid,
      "Model manifest failed validation",
      "id=" & m.id & " reason=" & problem
    )

# ---------------------------------------------------------------------------
# JSON 序列化
# ---------------------------------------------------------------------------

proc toJsonNode*(c: ShapeConstraint): JsonNode =
  %*{"port": c.port, "dims": c.dims}

proc toJsonNode*(d: DeviceSupport): JsonNode =
  var constraints = newJArray()
  for c in d.shapeConstraints:
    constraints.add(c.toJsonNode())
  result = %*{
    "device": d.device,
    "supported": d.supported,
    "requires_static_shape": d.requiresStaticShape,
    "shape_constraints": constraints,
    "verified": d.verified,
    "note": d.note
  }

proc toJsonNode*(f: ModelFile): JsonNode =
  %*{"path": f.path, "bytes": f.bytes, "sha256": f.sha256}

proc toJsonNode*(m: ModelManifest): JsonNode =
  ## 序列化为 manifest.json 的内容。
  ##
  ## 字段名用 snake_case,与 `settings.json` 保持一致 —— 两个文件都是
  ## 用户可能手工编辑的,风格不一致会让人困惑。
  var filesArray = newJArray()
  for f in m.files:
    filesArray.add(f.toJsonNode())

  var supportArray = newJArray()
  for d in m.deviceSupport:
    supportArray.add(d.toJsonNode())

  var entrypointsNode = newJObject()
  # 按固定顺序输出,使同一 manifest 的序列化结果稳定(便于 diff)。
  for role in KnownEntrypoints:
    if m.entrypoints.hasKey(role):
      entrypointsNode[role] = %m.entrypoints[role]

  result = %*{
    "schema_version": m.schemaVersion,
    "id": m.id,
    "display_name": m.displayName,
    "version": m.version,
    "format": $m.format,
    "task": $m.task,
    "layout": $m.layout,
    "storage": $m.storage,
    "source_directory": m.sourceDirectory,
    "entrypoints": entrypointsNode,
    "files": filesArray,
    "device_support": supportArray,
    "imported_at": m.importedAt,
    "notes": m.notes
  }

proc toJson*(m: ModelManifest): string =
  ## 便于人工阅读与 diff 的缩进形式。
  m.toJsonNode().pretty(2)

# ---------------------------------------------------------------------------
# JSON 反序列化
# ---------------------------------------------------------------------------

proc rejectType(field, expected: string, got: JsonNodeKind) {.noreturn.} =
  raiseIsvikError(
    ecModelInvalid,
    "Invalid type in model manifest",
    "field=" & field & " expected=" & expected & " got=" & $got
  )

proc readStr(node: JsonNode, key, field, fallback: string): string =
  if node == nil or not node.hasKey(key):
    return fallback
  if node[key].kind != JString:
    rejectType(field, "string", node[key].kind)
  result = node[key].getStr

proc readBoolField(node: JsonNode, key, field: string, fallback: bool): bool =
  if node == nil or not node.hasKey(key):
    return fallback
  if node[key].kind != JBool:
    rejectType(field, "boolean", node[key].kind)
  result = node[key].getBool

proc readIntField(node: JsonNode, key, field: string, fallback: int): int =
  if node == nil or not node.hasKey(key):
    return fallback
  if node[key].kind != JInt:
    rejectType(field, "integer", node[key].kind)
  result = node[key].getInt

proc parseFormat(s: string): ModelFormat =
  for f in ModelFormat:
    if $f == s:
      return f
  raiseIsvikError(
    ecModelInvalid,
    "Unknown model format in manifest",
    "format=" & s & " supported=" & ModelFormat.toSeq.mapIt($it).join(",")
  )

proc parseTask(s: string): ModelTask =
  for t in ModelTask:
    if $t == s:
      return t
  raiseIsvikError(
    ecModelInvalid,
    "Unknown model task in manifest",
    "task=" & s & " supported=" & ModelTask.toSeq.mapIt($it).join(",")
  )

proc parseLayout(s: string): ModelLayout =
  for layout in ModelLayout:
    if $layout == s:
      return layout
  raiseIsvikError(
    ecModelInvalid,
    "Unknown model layout in manifest",
    "layout=" & s & " supported=" & ModelLayout.toSeq.mapIt($it).join(",")
  )

proc parseStorage(s: string): StorageKind =
  for k in StorageKind:
    if $k == s:
      return k
  raiseIsvikError(
    ecModelInvalid,
    "Unknown storage kind in manifest",
    "storage=" & s & " supported=" & StorageKind.toSeq.mapIt($it).join(",")
  )

proc shapeConstraintFromJson(node: JsonNode): ShapeConstraint =
  if node.kind != JObject:
    rejectType("device_support[].shape_constraints[]", "object", node.kind)
  result.port = readStr(node, "port", "shape_constraints[].port", "")
  result.dims = @[]
  if node.hasKey("dims"):
    if node["dims"].kind != JArray:
      rejectType("shape_constraints[].dims", "array", node["dims"].kind)
    for d in node["dims"]:
      if d.kind != JInt:
        rejectType("shape_constraints[].dims[]", "integer", d.kind)
      result.dims.add(d.getInt)

proc deviceSupportFromJson(node: JsonNode): DeviceSupport =
  if node.kind != JObject:
    rejectType("device_support[]", "object", node.kind)
  result.device = readStr(node, "device", "device_support[].device", "")
  result.supported = readBoolField(node, "supported",
                                   "device_support[].supported", false)
  result.requiresStaticShape = readBoolField(
    node, "requires_static_shape",
    "device_support[].requires_static_shape", false)
  result.verified = readBoolField(node, "verified",
                                  "device_support[].verified", false)
  result.note = readStr(node, "note", "device_support[].note", "")
  result.shapeConstraints = @[]
  if node.hasKey("shape_constraints"):
    if node["shape_constraints"].kind != JArray:
      rejectType("device_support[].shape_constraints", "array",
                 node["shape_constraints"].kind)
    for c in node["shape_constraints"]:
      result.shapeConstraints.add(shapeConstraintFromJson(c))

proc modelFileFromJson(node: JsonNode): ModelFile =
  if node.kind != JObject:
    rejectType("files[]", "object", node.kind)
  result.path = readStr(node, "path", "files[].path", "")
  result.sha256 = readStr(node, "sha256", "files[].sha256", "")
  result.bytes = 0
  if node.hasKey("bytes"):
    if node["bytes"].kind != JInt:
      rejectType("files[].bytes", "integer", node["bytes"].kind)
    result.bytes = node["bytes"].getBiggestInt

proc fromJsonNode*(node: JsonNode): ModelManifest =
  ## 从 JSON 构造 manifest。缺失字段回落默认值,类型或取值错误抛 MODEL_INVALID。
  ##
  ## 与 `settings.nim` 采用同一策略:向前兼容靠「缺失回落」,
  ## 但**类型错误必须报错** —— 静默回落会把用户的笔误变成看不见的行为差异。
  if node == nil or node.kind != JObject:
    raiseIsvikError(
      ecModelInvalid,
      "Model manifest must contain a JSON object",
      "got=" & (if node == nil: "nothing" else: $node.kind)
    )

  result = initModelManifest("")
  result.schemaVersion = readIntField(node, "schema_version", "schema_version",
                                      ManifestSchemaVersion)
  result.id = readStr(node, "id", "id", "")
  result.displayName = readStr(node, "display_name", "display_name", "")
  result.version = readStr(node, "version", "version", "")
  result.format = parseFormat(readStr(node, "format", "format",
                                      $mfOpenVinoIr))
  result.task = parseTask(readStr(node, "task", "task", $mtUnknown))
  result.layout = parseLayout(readStr(node, "layout", "layout", $mlUnknown))
  result.storage = parseStorage(readStr(node, "storage", "storage",
                                        $skReferenced))
  result.sourceDirectory = readStr(node, "source_directory",
                                   "source_directory", "")
  result.importedAt = readStr(node, "imported_at", "imported_at", "")
  result.notes = readStr(node, "notes", "notes", "")

  result.entrypoints = initTable[string, string]()
  if node.hasKey("entrypoints"):
    if node["entrypoints"].kind != JObject:
      rejectType("entrypoints", "object", node["entrypoints"].kind)
    for role, value in node["entrypoints"]:
      if value.kind != JString:
        rejectType("entrypoints." & role, "string", value.kind)
      result.entrypoints[role] = value.getStr

  result.files = @[]
  if node.hasKey("files"):
    if node["files"].kind != JArray:
      rejectType("files", "array", node["files"].kind)
    for f in node["files"]:
      result.files.add(modelFileFromJson(f))

  result.deviceSupport = @[]
  if node.hasKey("device_support"):
    if node["device_support"].kind != JArray:
      rejectType("device_support", "array", node["device_support"].kind)
    for d in node["device_support"]:
      result.deviceSupport.add(deviceSupportFromJson(d))

proc parseManifest*(raw: string): ModelManifest =
  ## 从 JSON 文本解析并校验。
  let node =
    try:
      parseJson(raw)
    except JsonParsingError as e:
      raiseIsvikError(
        ecModelInvalid,
        "Model manifest is not valid JSON",
        "parse=" & e.msg
      )
  result = fromJsonNode(node)
  result.requireValid()

# ---------------------------------------------------------------------------
# 文件校验
# ---------------------------------------------------------------------------

proc fileChecksum*(path: string): string =
  ## 计算文件的 SHA-256(十六进制小写)。
  ##
  ## 用途是**检测损坏**,不是防篡改 —— 见模块顶部说明。
  ## 把工具层的 IOError 翻译成 IsvikError,使上层只需处理一种异常类型。
  try:
    result = sha256FileHex(path)
  except IOError as e:
    raiseIsvikError(
      ecModelInvalid,
      "Failed to read model file for checksum",
      "path=" & path & " io=" & e.msg
    )

type
  FileIssueKind* = enum
    ## 单个文件的校验问题。
    fikMissing = "missing"
      ## 文件不存在。
    fikSizeMismatch = "size-mismatch"
      ## 大小与清单不符。通常是下载截断或复制中断。
    fikChecksumMismatch = "checksum-mismatch"
      ## 内容与清单不符。

  FileIssue* = object
    path*: string
    kind*: FileIssueKind
    detail*: string

  VerifyOptions* = object
    ## 校验选项。
    checkChecksums*: bool
      ## 是否比对校验和。
      ##
      ## 默认关闭:对 4 GB 模型算一遍 SHA-256 需要可观的时间,而多数场景
      ## (`isvik list`)只需要知道文件在不在。需要严格校验时显式开启。

proc initVerifyOptions*(checkChecksums: bool = false): VerifyOptions =
  VerifyOptions(checkChecksums: checkChecksums)

proc verifyFiles*(m: ModelManifest, rootDir: string,
                  options: VerifyOptions = initVerifyOptions()):
    seq[FileIssue] =
  ## 校验清单登记的文件是否都在、大小与内容是否一致。
  ##
  ## 返回全部问题而不是遇到第一个就停:用户需要一次看到所有缺失的文件,
  ## 而不是修一个再跑一次才发现下一个。
  ##
  ## 清单里 `sha256` 为空的文件**跳过校验和比对**,不当作失败 ——
  ## 空表示「没算过」,把它当成不匹配是把缺失信息误报成损坏。
  result = @[]
  for f in m.files:
    let full = safeJoin(rootDir, f.path)

    if not fileExists(full):
      result.add(FileIssue(path: f.path, kind: fikMissing, detail: full))
      continue

    let actualSize = getFileSize(full)
    if f.bytes > 0 and actualSize != f.bytes:
      result.add(FileIssue(
        path: f.path,
        kind: fikSizeMismatch,
        detail: "expected=" & $f.bytes & " actual=" & $actualSize
      ))
      continue

    if options.checkChecksums and f.sha256.len > 0:
      let actual = fileChecksum(full)
      if actual != f.sha256.toLowerAscii:
        result.add(FileIssue(
          path: f.path,
          kind: fikChecksumMismatch,
          detail: "expected=" & f.sha256 & " actual=" & actual
        ))

proc isComplete*(m: ModelManifest, rootDir: string): bool =
  ## 清单登记的文件是否都存在且大小一致(不比对校验和)。
  m.verifyFiles(rootDir).len == 0
