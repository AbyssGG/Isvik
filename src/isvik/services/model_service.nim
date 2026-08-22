## 模型应用服务(Master Prompt §20)
##
## ---
##
## ## 它存在的理由
##
## §20.5.10 禁止 GUI / CLI / Server 各自实现一套 Runtime 逻辑。在本服务出现
## 之前,「用户给的这个字符串指哪个模型」这条**产品策略**被复制在三处:
##
## ```text
## cli/cmd_chat.resolveModelDir      目录优先、其次 id、无参数时唯一模型
## cli/workbench.resolveWorkbenchModel  在上面之外再加一层编号映射
## 未来的 server /api/chat            还得再抄一遍
## ```
##
## 复制的后果不是「多写几行」,而是三处会**慢慢分叉**:改了一处忘了另一处,
## 于是 CLI 与 HTTP 对同一个请求给出不同的模型。本服务把策略收成一份。
##
## ---
##
## ## 为什么返回状态而不是直接抛本地化错误
##
## 服务层刻意**不 import i18n**。解析失败有多种成因,每种成因前端要说的话
## 不一样:CLI 要说「用 -ls 查看编号」,HTTP 要回 `MODEL_NOT_FOUND` 的 JSON。
## 如果服务直接抛带界面文案的错误,那句话就会同时出现在终端和 API 响应里,
## 两边都不合适。
##
## 于是解析结果是**数据**(`ModelResolution`),状态是枚举,由前端决定怎么说。
## 这与 `models/manager.Eligibility` 用 `status + reason` 而不是 bool 的
## 取舍一致:调用方需要知道**为什么**,不只是「行不行」。

import std/[os, strutils]

import isvik/core/errors
import isvik/core/backend
import isvik/core/runtime
import isvik/backends/factory
import isvik/config/paths
import isvik/config/settings
import isvik/models/manager
import isvik/models/inspection

export manager

type
  ModelService* = ref object
    ## 模型库的应用层入口。
    ##
    ## 与 `ModelManager` 一样是**无状态**的:每次操作都从磁盘读清单,
    ## 因此不需要 close,也不会与磁盘上的真实内容分叉。
    mgr: ModelManager

  ModelResolutionStatus* = enum
    ## 模型引用的解析结论。
    mrsResolved = "resolved"
      ## 找到了唯一确定的模型。
    mrsNotFound = "not-found"
      ## 给了引用,但它既不是存在的目录,也不是已导入的 id。
    mrsStoreEmpty = "store-empty"
      ## 没给引用,而模型库是空的。
    mrsAmbiguous = "ambiguous"
      ## 没给引用,而库里有多个模型。**不替用户挑** ——
      ## 随便选一个会让「我明明想用另一个」这种困惑极难排查。
    mrsIndexOutOfRange = "index-out-of-range"
      ## 按编号选择,但编号超出当前范围。

  ModelResolution* = object
    ## 解析结果。
    ##
    ## 失败时仍然带上 `ids` / `count` / `rootDirectory`,因为前端要用它们
    ## 组织提示(「当前可选编号 1 到 N」「用 import 导入」)。
    status*: ModelResolutionStatus
    directory*: string
      ## 可直接交给 Runtime 编译的绝对路径。
    label*: string
      ## 面向用户的名称。目录引用时就是用户给的原文。
    id*: string
      ## 已导入模型的 id。直接用目录路径时为空 —— 那种模型不在库里,
      ## 硬编一个 id 会让「它已被导入」这件事看起来成立。
    requested*: string
    ids*: seq[string]
    rootDirectory*: string

proc newModelService*(paths: IsvikPaths, s: Settings): ModelService =
  new(result)
  result.mgr = newModelManager(paths, s)

proc newModelService*(mgr: ModelManager): ModelService =
  ## 直接注入 Manager。主要供测试使用。
  doAssert mgr != nil, "ModelManager 不能为 nil"
  new(result)
  result.mgr = mgr

proc manager*(svc: ModelService): ModelManager = svc.mgr

# ---------------------------------------------------------------------------
# 查询转发
# ---------------------------------------------------------------------------

proc list*(svc: ModelService,
           options: VerifyOptions = initVerifyOptions()): seq[StoredModel] =
  svc.mgr.list(options)

proc ids*(svc: ModelService): seq[string] = svc.mgr.ids()

proc count*(svc: ModelService): int = svc.mgr.count()

proc has*(svc: ModelService, id: string): bool = svc.mgr.has(id)

proc info*(svc: ModelService, id: string,
           options: VerifyOptions = initVerifyOptions()): StoredModel =
  svc.mgr.info(id, options)

proc rootDirectory*(svc: ModelService): string = svc.mgr.rootDirectory

# ---------------------------------------------------------------------------
# 解析策略(本服务存在的主要理由)
# ---------------------------------------------------------------------------

proc initResolution(svc: ModelService, requested: string): ModelResolution =
  ModelResolution(
    status: mrsNotFound,
    directory: "",
    label: "",
    id: "",
    requested: requested,
    ids: svc.mgr.ids(),
    rootDirectory: svc.mgr.rootDirectory
  )

proc resolvedFromId(svc: ModelService, res: var ModelResolution, id: string) =
  let stored = svc.mgr.info(id)
  res.status = mrsResolved
  res.directory = stored.contentDirectory
  res.label = stored.manifest.displayLabel
  # 返回 manifest 中已经与磁盘真实目录严格校验过的规范 id，而不是客户端
  # 可能使用的 Windows 大小写别名。
  res.id = stored.manifest.id

proc resolveReference*(svc: ModelService, requested: string): ModelResolution =
  ## 把用户给的引用解析成模型目录。
  ##
  ## 顺序是**目录优先、其次 id**:用户给的是路径时,不该被一个同名 id
  ## 遮住 —— 路径是明确的意图,id 是需要查表的间接引用。
  ##
  ## 引用为空表示「没指定」:库里恰好一个模型就用它,否则如实报告
  ## 空库或多选,不猜。
  result = svc.initResolution(requested)

  let trimmed = requested.strip()
  if trimmed.len > 0:
    if dirExists(trimmed):
      result.status = mrsResolved
      result.directory = trimmed.absolutePath
      result.label = trimmed
      return
    if svc.mgr.has(trimmed):
      svc.resolvedFromId(result, trimmed)
      return
    result.status = mrsNotFound
    return

  if result.ids.len == 0:
    result.status = mrsStoreEmpty
    return
  if result.ids.len > 1:
    result.status = mrsAmbiguous
    return
  svc.resolvedFromId(result, result.ids[0])

proc resolveIndex*(svc: ModelService, index: int): ModelResolution =
  ## 按**列表编号**解析(1 起)。
  ##
  ## 编号映射到 `ids()` 的顺序,而它是按 id 排序的稳定序列 ——
  ## 不用文件系统遍历顺序:那个顺序不保证稳定,会让 `[1]` 指向的模型漂移。
  ##
  ## 编号本身怎么写(`1` 还是 `[1]`)属于前端输入语法,不在这里解析。
  result = svc.initResolution($index)
  if index < 1 or index > result.ids.len:
    result.status = mrsIndexOutOfRange
    return
  svc.resolvedFromId(result, result.ids[index - 1])

proc requireResolved*(res: ModelResolution) =
  ## 把解析失败转成 IsvikError。
  ##
  ## 供**不需要本地化文案**的调用方使用(服务内部、HTTP 层)。CLI 不该用它,
  ## 而应按 `status` 渲染界面语言的提示。
  ##
  ## message 用固定英文并把可变部分放进 detail:§22 要求 detail 不进
  ## API 响应,因此凡是可能含路径的内容都只能出现在 detail 里。
  case res.status
  of mrsResolved:
    discard
  of mrsNotFound:
    raiseIsvikError(
      ecModelNotFound,
      "Neither an imported model id nor an existing directory",
      "requested=" & res.requested
    )
  of mrsStoreEmpty:
    raiseIsvikError(
      ecModelNotFound,
      "The model store is empty",
      "modelDirectory=" & res.rootDirectory
    )
  of mrsAmbiguous:
    raiseIsvikError(
      ecInvalidParameter,
      "The model store holds multiple models; specify which one to use",
      "count=" & $res.ids.len & " ids=" & res.ids.join(",")
    )
  of mrsIndexOutOfRange:
    raiseIsvikError(
      ecInvalidParameter,
      "The model number does not exist",
      "requested=" & res.requested & " count=" & $res.ids.len
    )

proc resolveRequired*(svc: ModelService, requested: string): ModelResolution =
  ## `resolveReference` + `requireResolved`。
  result = svc.resolveReference(requested)
  result.requireResolved()

# ---------------------------------------------------------------------------
# 增删转发
# ---------------------------------------------------------------------------

proc probeNpuCompatibility(svc: ModelService,
                           imported: ModelManifest): ModelManifest =
  ## 在导入阶段编译所有真正会上 NPU 的 IR 组件。
  ##
  ## tokenizer 含 STRING 端口且固定运行在 CPU；把它纳入探针会把“tokenizer
  ## 不能上 NPU”误报成“主模型不能上 NPU”。编译成功仅证明 compile-compatible，
  ## note 明确标记 smoke inference 尚未执行。
  let stored = svc.mgr.info(imported.id)
  let primaryRole = stored.manifest.primaryRole()
  if primaryRole.len == 0 or stored.manifest.format != mfOpenVinoIr:
    return imported

  let rt = newRuntime(newInferenceBackend())
  var initialized = false
  try:
    try:
      rt.initialize()
      initialized = true
    except IsvikError:
      # 模型库操作必须在未安装推理运行时的机器上仍可用。此时无法验证，
      # 保持无 NPU 条目，而不是伪造“不支持”。
      return imported

    let npuRaw =
      try:
        rt.resolveDevice(DeviceRequestNpu).device.rawName
      except IsvikError:
        # 设备发现或语义解析失败只表示当前无法验证，不能据此判定模型不支持。
        return imported

    let backendName = rt.backendName()
    let backendVersion = rt.backendVersion()
    var staticConstraints: seq[ShapeConstraint] = @[]
    var staticContext = 0
    var acceleratorRoles = @[primaryRole]
    if imported.isComposite():
      for role in [EntrypointTextEmbeddings,
                   EntrypointTextEmbeddingsPerLayer]:
        if imported.hasEntrypoint(role):
          acceleratorRoles.add(role)
    try:
      for role in acceleratorRoles:
        # 路径解析、模型加载、检查与 reshape 都不属于设备编译失败边界。
        let componentPath = safeJoin(
          stored.contentDirectory, imported.entrypoint(role))
        let modelId = rt.loadModel(componentPath)
        if role == primaryRole and
            imported.layout == mlMonolithicTokenCausalLm:
          let inspection = inspectOpenVinoIr(componentPath)
          staticContext = declaredContextLength(stored.contentDirectory)
          let shapes = causalLmNpuStaticShapes(inspection, staticContext)
          if shapes.len > 0:
            rt.reshapeModel(modelId, shapes)
            staticConstraints = manifestShapeConstraints(shapes)
        try:
          discard rt.compileModel(modelId, initCompileOptions(npuRaw))
        except IsvikError as e:
          # 这里只有实际 Backend compile 调用，因而可据此记录 unsupported。
          svc.mgr.recordVerification(
            imported.id, DeviceRequestNpu, false,
            "stage=compile result=unsupported smoke_infer=not-run code=" &
              $e.code & " [backend=" & backendName & "/" & backendVersion & "]",
            staticConstraints.len > 0, staticConstraints)
          return svc.mgr.info(imported.id).manifest
        rt.unloadModel(modelId)
      svc.mgr.recordVerification(
        imported.id, DeviceRequestNpu, true,
        "stage=compile result=supported smoke_infer=not-run components=" &
          acceleratorRoles.join(",") &
          (if staticContext > 0: " static_context=" & $staticContext else: "") &
          " [backend=" & backendName & "/" & backendVersion & "]",
        staticConstraints.len > 0, staticConstraints)
    except IsvikError:
      # 编译边界外的错误只表示探针无法完成，保持模型未验证。
      discard
  finally:
    if initialized:
      rt.shutdown()

  result = svc.mgr.info(imported.id).manifest

proc importFrom*(svc: ModelService, sourceDir: string,
                 options: ImportOptions = initImportOptions()):
    ModelManifest =
  let imported = svc.mgr.importFrom(sourceDir, options)
  if options.probeNpu:
    result = svc.probeNpuCompatibility(imported)
  else:
    result = imported

proc remove*(svc: ModelService, id: string) =
  svc.mgr.remove(id)

proc recordVerification*(svc: ModelService, id, device: string,
                         supported: bool, note: string = "",
                         requiresStaticShape: bool = false,
                         shapeConstraints: seq[ShapeConstraint] = @[]) =
  svc.mgr.recordVerification(
    id, device, supported, note, requiresStaticShape, shapeConstraints)

proc checkEligibility*(svc: ModelService, id, device: string,
                       staticShapeAvailable: bool = false): Eligibility =
  svc.mgr.checkEligibility(id, device, staticShapeAvailable)
