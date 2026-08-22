## Model Storage(Master Prompt §54 / §16 / §38)
##
## ---
##
## ## 布局
##
## ```text
## <models>/
##   <model-id>/
##     manifest.json
##     (copied 模式下还有模型文件本身)
## ```
##
## 一个目录一个模型,目录名就是 model id。这样「列举模型」是一次目录扫描,
## 不需要额外的索引文件 —— 索引文件会与真实内容分叉,而且要处理并发写。
##
## `<models>` 默认是 `<ISVIK_HOME>/models`,可由 `settings.json` 的
## `model_directory` 覆盖(Task 4 已实现该字段)。
##
## ---
##
## ## 引用模式:模型不进仓库,也不进模型库
##
## 本机的 Gemma 4 E2B 是 4.06 GB,放在 `D:\Model\gemma-4-E2B-it-int4-ov`。
## 复制进 `~/.isvik/models` 只是让同一份数据占两倍磁盘,毫无收益。
##
## 因此**默认是引用模式**:模型库里只放一个 `manifest.json`,记录外部目录的
## 绝对路径。代价是那个目录可能被移动或删除,所以:
##
## - `manifest.verifyFiles` 能报告文件缺失
## - `isvik list` 会显示每个模型是否完整
## - 引用目录消失时报 `MODEL_NOT_FOUND`,而不是在编译阶段以晦涩的方式失败
##
## ---
##
## ## 路径安全(§38)
##
## model id 来自用户输入(命令行参数),因此:
##
## - 必须通过 `validateModelId`(单段、无穿越、非 Windows 保留名)
## - 拼接一律走 `safeJoin`,绝不用 `/` 直接接
## - 删除前用 `isInsideDirectory` 再确认一次目标真的在模型库内
##
## 最后一条是有意的重复检查:`rm` 是不可逆操作,多一道确认的成本远低于
## 误删用户目录的代价。

import std/[os, tables, algorithm, strutils, options]

import isvik/core/errors
import isvik/config/paths
import isvik/config/settings
import isvik/models/manifest
import isvik/models/inspection

type
  ModelStore* = object
    ## 模型库。只持有根目录路径,不缓存内容 ——
    ## 缓存会与磁盘上的真实状态分叉,而列举的开销本来就很小。
    root*: string

  StoredModel* = object
    ## 模型库中的一个条目。
    manifest*: ModelManifest
    directory*: string
      ## 该模型在库中的目录(含 manifest.json)。
    contentDirectory*: string
      ## 模型**文件**实际所在的目录。
      ##
      ## copied 模式下与 `directory` 相同;referenced 模式下是外部目录。
      ## 这个区分让调用方不必自己判断存储方式。
    issues*: seq[FileIssue]
      ## 文件校验问题。空表示完整。

  ImportOptions* = object
    ## 导入选项。
    id*: string
      ## 目标 model id。为空时由来源目录名推导。
    displayName*: string
    copyFiles*: bool
      ## true 复制文件进库,false 只记引用。默认 false(见模块顶部说明)。
    computeChecksums*: bool
      ## 是否计算并记录每个文件的 SHA-256。
      ##
      ## 默认 false:对 4 GB 模型算一遍要好几分钟,而导入时用户在等。
      ## 需要严格完整性记录时显式开启。
    overwrite*: bool
      ## 目标 id 已存在时是否覆盖。默认 false,冲突就报错。
    probeNpu*: bool
      ## 导入后是否在本机 NPU 上真实编译主 IR。应用服务默认执行；storage
      ## 本身不接触 Backend，因此该字段由上层消费。

const
  ModelFileExtensions* = [".xml", ".bin", ".onnx", ".json", ".txt", ".model"]
    ## 导入时会登记的文件扩展名。
    ##
    ## 白名单而非黑名单:模型目录里常有 `.md`、`.gitattributes`、图片等
    ## 与推理无关的文件,把它们登记进 manifest 只会让校验产生噪声。
    ## 不在白名单里的文件不影响使用,只是不被登记。

proc initImportOptions*(id: string = "", copyFiles: bool = false):
    ImportOptions =
  ImportOptions(
    id: id,
    displayName: "",
    copyFiles: copyFiles,
    computeChecksums: false,
    overwrite: false,
    probeNpu: true
  )

# ---------------------------------------------------------------------------
# 构造
# ---------------------------------------------------------------------------

proc newModelStore*(paths: IsvikPaths, s: Settings): ModelStore =
  ## 依据配置决定模型库根目录。
  ##
  ## `settings.model_directory` 非空时优先(允许把模型库放到大容量磁盘),
  ## 否则用 `<ISVIK_HOME>/models`。
  let override = s.modelDirectory.strip()
  if override.len > 0:
    ModelStore(root: normalizedPath(absolutePath(expandTilde(override))))
  else:
    ModelStore(root: paths.models)

proc newModelStore*(root: string): ModelStore =
  ## 直接指定根目录。主要供测试使用。
  ModelStore(root: normalizedPath(absolutePath(root)))

proc ensureRoot*(store: ModelStore) =
  ## 确保模型库根目录存在。
  if dirExists(store.root):
    return
  try:
    createDir(store.root)
  except OSError as e:
    raiseIsvikError(
      ecServerError,
      "Failed to create model store directory",
      "path=" & store.root & " os=" & e.msg
    )

# ---------------------------------------------------------------------------
# 路径
# ---------------------------------------------------------------------------

proc modelDirectory*(store: ModelStore, id: string): string =
  ## 某个 model id 在库中的目录。id 非法时抛 INVALID_PARAMETER。
  let problem = validateModelId(id)
  if problem.len > 0:
    raiseIsvikError(
      ecInvalidParameter,
      "Invalid model id",
      "id=" & id & " reason=" & problem
    )
  result = safeJoin(store.root, id)

proc manifestPath*(store: ModelStore, id: string): string =
  store.modelDirectory(id) / ManifestFileName

proc listIds*(store: ModelStore): seq[string]
  ## 前置声明供 canonicalStoredId 使用；实现在读取区末尾。

proc canonicalStoredId(store: ModelStore, requested: string): string =
  ## 把调用方拼写映射为磁盘上的真实目录 id。
  ##
  ## Windows 文件系统不区分大小写：`Foo` 会命中目录 `foo`，但若继续拿
  ## 请求拼写与 manifest.id 严格比较，就会把一个完全一致的模型库误报成
  ## “目录名不一致”。这里只规范**查找**；loadManifest 仍会用磁盘真实目录名
  ## 严格校验 manifest，真正的手工改名或错放清单仍然被拒绝。
  if validateModelId(requested).len > 0:
    return ""

  when defined(windows):
    for storedId in store.listIds():
      if cmpIgnoreCase(storedId, requested) == 0:
        return storedId
  else:
    if fileExists(store.manifestPath(requested)):
      return requested

  ""

proc exists*(store: ModelStore, id: string): bool =
  ## 该 id 是否已在库中(以 manifest.json 存在为准)。
  ##
  ## 以清单为准而不是以目录为准:一个空目录不是模型,
  ## 把它算作已存在会让导入无从下手。
  store.canonicalStoredId(id).len > 0

# ---------------------------------------------------------------------------
# 读取
# ---------------------------------------------------------------------------

proc contentDirectoryOf*(store: ModelStore, m: ModelManifest): string =
  ## 模型文件实际所在目录。
  case m.storage
  of skCopied:
    store.modelDirectory(m.id)
  of skReferenced:
    normalizedPath(absolutePath(m.sourceDirectory))

proc loadManifest*(store: ModelStore, id: string): ModelManifest =
  ## 读取并校验某个模型的清单。
  let canonicalId = store.canonicalStoredId(id)
  if canonicalId.len == 0:
    raiseIsvikError(
      ecModelNotFound,
      "Model is not present in the model store",
      "id=" & id & " expected=" & store.manifestPath(id)
    )

  let path = store.manifestPath(canonicalId)
  let raw =
    try:
      readFile(path)
    except IOError as e:
      raiseIsvikError(
        ecModelInvalid,
        "Failed to read model manifest",
        "path=" & path & " io=" & e.msg
      )

  result = parseManifest(raw)

  # 严格比较 manifest 与**磁盘真实目录名**。Windows 请求大小写别名已在
  # canonicalStoredId 中消除，但真正被手工改名或错放的清单仍然必须报错。
  if result.id != canonicalId:
    raiseIsvikError(
      ecModelInvalid,
      "Model manifest id does not match its directory name",
      "directory=" & canonicalId & " manifestId=" & result.id
    )

proc load*(store: ModelStore, id: string,
           options: VerifyOptions = initVerifyOptions()): StoredModel =
  ## 读取清单并校验文件。
  let m = store.loadManifest(id)
  let content = store.contentDirectoryOf(m)

  var issues: seq[FileIssue] = @[]
  if dirExists(content):
    issues = m.verifyFiles(content, options)
  else:
    # 引用目录整个不见了。逐个文件报缺失没有意义,报一条更清楚。
    issues.add(FileIssue(
      path: ".",
      kind: fikMissing,
      detail: "content directory does not exist: " & content
    ))

  result = StoredModel(
    manifest: m,
    directory: store.modelDirectory(m.id),
    contentDirectory: content,
    issues: issues
  )

proc listIds*(store: ModelStore): seq[string] =
  ## 列出库中所有 model id,已排序。
  ##
  ## 库目录不存在时返回空列表而不是报错:那是首次运行的正常状态。
  result = @[]
  if not dirExists(store.root):
    return
  for kind, path in walkDir(store.root):
    if kind != pcDir:
      continue
    let id = path.extractFilename
    # 只把「含 manifest.json 的目录」当模型。用户在模型库里放了别的目录
    # 不该让 list 报错。
    if fileExists(path / ManifestFileName):
      result.add(id)
  sort(result)

proc listModels*(store: ModelStore,
                 options: VerifyOptions = initVerifyOptions()):
    seq[StoredModel] =
  ## 列出库中所有模型。
  ##
  ## 单个模型的清单损坏**不中断整个列举** —— 否则一个坏清单会让
  ## `isvik list` 完全不可用,而用户正需要它来找出是哪个模型坏了。
  ## 坏掉的条目以「清单无法读取」的形式出现在结果里。
  result = @[]
  for id in store.listIds():
    try:
      result.add(store.load(id, options))
    except IsvikError as e:
      var broken = initModelManifest(id)
      broken.notes = "manifest could not be loaded: " & $e.code & ": " & e.msg
      result.add(StoredModel(
        manifest: broken,
        directory: store.modelDirectory(id),
        contentDirectory: "",
        issues: @[FileIssue(
          path: ManifestFileName,
          kind: fikMissing,
          detail: $e.code & ": " & e.msg
        )]
      ))

# ---------------------------------------------------------------------------
# 写入
# ---------------------------------------------------------------------------

proc saveManifest*(store: ModelStore, m: ModelManifest) =
  ## 写入清单。会先校验,拒绝写入非法内容。
  ##
  ## 任何写回都会把旧 schema 显式迁移到当前版本；否则 v1 清单会带着 v2
  ## layout 字段却继续声明 schema 1，版本与结构会分叉。
  var normalized = m
  if normalized.schemaVersion < ManifestSchemaVersion:
    normalized.schemaVersion = ManifestSchemaVersion
  normalized.requireValid()

  let dir = store.modelDirectory(normalized.id)
  if not dirExists(dir):
    try:
      createDir(dir)
    except OSError as e:
      raiseIsvikError(
        ecServerError,
        "Failed to create model directory",
        "path=" & dir & " os=" & e.msg
      )

  let target = dir / ManifestFileName
  let tmp = target & ".tmp"
  try:
    writeFile(tmp, normalized.toJson() & "\n")
    if fileExists(target):
      removeFile(target)
    moveFile(tmp, target)
  except CatchableError as e:
    if fileExists(tmp):
      try: removeFile(tmp)
      except CatchableError: discard
    raiseIsvikError(
      ecServerError,
      "Failed to write model manifest",
      "path=" & target & " reason=" & e.msg
    )

# ---------------------------------------------------------------------------
# 导入
# ---------------------------------------------------------------------------

proc isModelFile(name: string): bool =
  let lower = name.toLowerAscii
  for ext in ModelFileExtensions:
    if lower.endsWith(ext):
      return true
  result = false

proc deriveModelId*(sourceDir: string): string =
  ## 从来源目录名推导 model id。
  ##
  ## 只做「小写 + 把不安全字符换成连字符」这类最小规范化,不做花哨的音译。
  ## 结果仍需通过 `validateModelId`,推导不出合法 id 时由调用方显式指定。
  let base = sourceDir.strip(chars = {'/', '\\', ' '}).extractFilename
  result = ""
  for c in base.toLowerAscii:
    if c in {'a' .. 'z', '0' .. '9', '.', '-', '_'}:
      result.add(c)
    else:
      result.add('-')
  # 折叠连续连字符,去掉首尾连字符,避免产生 `--foo--` 这种难看的 id。
  while result.contains("--"):
    result = result.replace("--", "-")
  result = result.strip(chars = {'-', '.'})

proc collectModelFiles(sourceDir: string, computeChecksums: bool):
    seq[ModelFile] =
  ## 扫描来源目录,登记符合白名单的文件。
  ##
  ## 递归扫描:OpenVINO 的模型目录通常是平的,但 tokenizer 相关文件有时在
  ## 子目录里。相对路径统一用 `/`,使 manifest 跨平台可读。
  result = @[]
  for path in walkDirRec(sourceDir, relative = true):
    let full = sourceDir / path
    if not fileExists(full):
      continue
    if not isModelFile(path.extractFilename):
      continue
    let rel = path.replace('\\', '/')
    # 来源目录里出现不安全的相对路径(极少见,但可能是符号链接构造的),
    # 直接跳过而不是让它进 manifest。
    if checkRelativePath(rel).isSome:
      continue
    var entry = ModelFile(
      path: rel,
      bytes: getFileSize(full),
      sha256: ""
    )
    if computeChecksums:
      entry.sha256 = fileChecksum(full)
    result.add(entry)
  result.sort(proc (a, b: ModelFile): int = cmp(a.path, b.path))

proc detectEntrypoints*(files: seq[ModelFile]):
    tuple[entrypoints: Table[string, string], unrecognized: seq[string]] =
  ## 从文件列表识别各组件入口。
  ##
  ## ---
  ##
  ## ## 命名约定来自本机 Gemma 4 E2B 的实测目录
  ##
  ## ```text
  ## openvino_language_model.xml                    → language_model
  ## openvino_text_embeddings_model.xml             → text_embeddings
  ## openvino_text_embeddings_per_layer_model.xml   → text_embeddings_per_layer
  ## openvino_vision_embeddings_model.xml           → vision_embeddings
  ## openvino_tokenizer.xml                         → tokenizer
  ## openvino_detokenizer.xml                       → detokenizer
  ## openvino_model.xml / model.xml                 → model(单体模型)
  ## ```
  ##
  ## **判定顺序有讲究**:`per_layer` 必须在 `text_embeddings` 之前判,
  ## 因为 `openvino_text_embeddings_per_layer_model.xml` 同时含两个子串。
  ## 反过来会把 2.19 GB 的 PLE 误认成普通 embedding,而后者才 384 MB ——
  ## 这种错误在推理阶段才会以形状不匹配的方式暴露。
  ##
  ## 同理 `detokenizer` 必须在 `tokenizer` 之前判。
  ##
  ## 认不出的 .xml 单独返回,由调用方决定是报错还是提示用户显式指定 ——
  ## 猜一个当主模型会在编译时才暴露猜错了。
  var entrypoints = initTable[string, string]()
  var unrecognized: seq[string] = @[]

  for f in files:
    let name = f.path.extractFilename.toLowerAscii
    if not name.endsWith(".xml"):
      continue

    if name.contains("detokenizer"):
      entrypoints[EntrypointDetokenizer] = f.path
    elif name.contains("tokenizer"):
      entrypoints[EntrypointTokenizer] = f.path
    elif name.contains("per_layer") or name.contains("per-layer"):
      entrypoints[EntrypointTextEmbeddingsPerLayer] = f.path
    elif name.contains("text_embeddings") or name.contains("text-embeddings"):
      entrypoints[EntrypointTextEmbeddings] = f.path
    elif name.contains("vision_embeddings") or name.contains("vision-embeddings"):
      entrypoints[EntrypointVisionEmbeddings] = f.path
    elif name.contains("language_model") or name.contains("language-model"):
      entrypoints[EntrypointLanguageModel] = f.path
    elif name == "openvino_model.xml" or name == "model.xml":
      entrypoints[EntrypointModel] = f.path
    else:
      unrecognized.add(f.path)

  # 只有一个认不出的 .xml、且没识别出任何主模型时,把它当单体模型。
  # 这是确定性规则:唯一候选不存在「猜错哪一个」的问题。
  if unrecognized.len == 1 and
     not entrypoints.hasKey(EntrypointModel) and
     not entrypoints.hasKey(EntrypointLanguageModel):
    entrypoints[EntrypointModel] = unrecognized[0]
    unrecognized = @[]

  result = (entrypoints: entrypoints, unrecognized: unrecognized)

proc importModel*(store: ModelStore, sourceDir: string,
                  options: ImportOptions = initImportOptions()):
    ModelManifest =
  ## 从一个目录导入模型。
  ##
  ## 返回写入的清单。**不验证任何设备可用性** —— 导入只是登记文件,
  ## 因此所有 `DeviceSupport.verified` 都是 false(§13 / §27)。
  let source = normalizedPath(absolutePath(expandTilde(sourceDir.strip())))
  if not dirExists(source):
    raiseIsvikError(
      ecModelNotFound,
      "Source directory does not exist",
      "path=" & source
    )

  let id =
    if options.id.strip().len > 0: options.id.strip()
    else: deriveModelId(source)

  let idProblem = validateModelId(id)
  if idProblem.len > 0:
    raiseIsvikError(
      ecInvalidParameter,
      "Could not determine a valid model id; specify one explicitly",
      "derivedId=" & id & " source=" & source & " reason=" & idProblem
    )

  if store.exists(id) and not options.overwrite:
    raiseIsvikError(
      ecInvalidParameter,
      "A model with this id already exists",
      "id=" & id & " directory=" & store.modelDirectory(id)
    )

  let files = collectModelFiles(source, options.computeChecksums)
  if files.len == 0:
    raiseIsvikError(
      ecModelInvalid,
      "No recognizable model files were found in the source directory",
      "path=" & source & " extensions=" & ModelFileExtensions.join(",")
    )

  let detected = detectEntrypoints(files)

  var m = initModelManifest(id, mfOpenVinoIr)
  m.displayName = options.displayName
  m.files = files
  m.entrypoints = detected.entrypoints
  m.storage = if options.copyFiles: skCopied else: skReferenced
  m.sourceDirectory = source

  if m.primaryRole().len == 0:
    # detail 里给出实际认不出的文件名,而不是文件总数 —— 用户要能看出
    # 是哪些文件没被识别,才知道该怎么办。
    raiseIsvikError(
      ecModelInvalid,
      "Could not identify the main model file",
      "path=" & source &
        " unrecognized=" & (if detected.unrecognized.len > 0:
                              detected.unrecognized.join(",")
                            else: "<none>") &
        " recognized=" & $detected.entrypoints.len
    )

  # ONNX 单文件模型:格式按实际扩展名记,不一律记成 IR。
  if m.primaryEntrypoint().toLowerAscii.endsWith(".onnx"):
    m.format = mfOnnx

  # 依据主 IR 的真实端口与状态节点检测任务和执行布局。config.json 中的
  # architecture/model_type 只适合展示，不能决定应该绑定哪些张量。
  if m.format == mfOpenVinoIr:
    let inspection = inspectOpenVinoIr(safeJoin(source, m.primaryEntrypoint()))
    m.layout = inspection.layout
    m.task = inspection.task
    m.notes = inspection.inspectionNote()
    if m.layout == mlUnknown:
      raiseIsvikError(
        ecModelUnsupported,
        "The main OpenVINO IR contract is not a supported model layout",
        "entrypoint=" & m.primaryEntrypoint() & " reason=" & inspection.reason
      )

    # 文件名识别与契约识别必须一致。这样即使目录中的文件碰巧采用 composite
    # 命名，也不能把 input_ids 单体模型静默套进 inputs_embeds 管线。
    if m.isComposite() and m.layout != mlCompositeEmbeddingCausalLm:
      raiseIsvikError(
        ecModelInvalid,
        "Composite entrypoints do not match the language model IR contract",
        "layout=" & $m.layout & " entrypoint=" & m.primaryEntrypoint()
      )

  store.ensureRoot()

  if options.copyFiles:
    let target = store.modelDirectory(id)
    for f in files:
      let dest = safeJoin(target, f.path)
      createDir(dest.parentDir)
      copyFile(source / f.path, dest)
    # 复制模式下文件已在库内,来源目录只作追溯信息。

  store.saveManifest(m)
  result = m

# ---------------------------------------------------------------------------
# 删除
# ---------------------------------------------------------------------------

proc removeModel*(store: ModelStore, id: string) =
  ## 从库中删除一个模型。
  ##
  ## **引用模式下不会删除外部文件** —— 那些文件不属于 Isvik,删掉用户放在
  ## `D:\Model\` 的 4 GB 模型是不可接受的。只删除库内的模型目录。
  let dir = store.modelDirectory(id)

  if not store.exists(id):
    raiseIsvikError(
      ecModelNotFound,
      "Model is not present in the model store",
      "id=" & id & " directory=" & dir
    )

  # 有意的重复确认:删除不可逆,而 `dir` 来自用户输入的 id。
  # safeJoin 已经查过一次,这里再确认目标确实在库内。
  if not isInsideDirectory(store.root, dir):
    raiseIsvikError(
      ecInvalidParameter,
      "Refused to remove a directory outside of the model store",
      "id=" & id & " resolved=" & dir & " store=" & store.root
    )

  try:
    removeDir(dir)
  except OSError as e:
    raiseIsvikError(
      ecServerError,
      "Failed to remove model directory",
      "path=" & dir & " os=" & e.msg
    )

# ---------------------------------------------------------------------------
# 设备验证结果的回写
# ---------------------------------------------------------------------------

proc recordDeviceVerification*(store: ModelStore, id: string,
                               device: string, supported: bool,
                               note: string = "",
                               requiresStaticShape: bool = false,
                               shapeConstraints: seq[ShapeConstraint] = @[]) =
  ## 记录一次**真实的**设备验证结果。
  ##
  ## 这是唯一可以把 `verified` 置为 true 的入口,且只应在真的完成了
  ## 编译 / 推理之后调用。放在这里而不是散落各处,是为了让「谁有权声称
  ## 已验证」这件事只有一个位置(§13 / §27)。
  var m = store.loadManifest(id)

  var found = false
  for i in 0 ..< m.deviceSupport.len:
    if m.deviceSupport[i].device == device:
      m.deviceSupport[i].supported = supported
      m.deviceSupport[i].verified = true
      m.deviceSupport[i].requiresStaticShape = requiresStaticShape
      m.deviceSupport[i].shapeConstraints = shapeConstraints
      if note.len > 0:
        m.deviceSupport[i].note = note
      found = true
      break

  if not found:
    var entry = initDeviceSupport(device, supported, requiresStaticShape)
    entry.shapeConstraints = shapeConstraints
    entry.verified = true
    entry.note = note
    m.deviceSupport.add(entry)

  store.saveManifest(m)
