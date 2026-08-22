## Model Manager(Master Prompt §54)
##
## ---
##
## ## 它做什么、不做什么
##
## ```text
## 做:   list / info / import / remove   模型库的增删查
##       resolve                         id → 可用于编译的绝对路径
##       载入前的可行性判断              设备 × 静态 shape 约束
##
## 不做: 编译、推理、缓存               那是 Runtime 与 Cache 的职责
##       设备枚举                       那是 Device Manager 的职责
## ```
##
## Manager 是**无状态的**:每次操作都从磁盘读清单。理由与 storage 相同 ——
## 缓存会与磁盘上的真实内容分叉,而模型库的规模(几十个条目)让重复读取
## 的开销可以忽略。
##
## ---
##
## ## 为什么可行性判断放在这里
##
## DEVLOG 的硬约束:**模型能否上 NPU 是模型属性,不是运行时偏好。**
## 于是「这个模型能不能在这个设备上跑」需要同时看两边:
##
## ```text
## Device Manager  →  这个设备存在吗、符合策略吗
## Model Manifest  →  这个模型在该设备上有什么要求
##          ↓
##      Model Manager 合并两者,给出可解释的结论
## ```
##
## 放在 Manager 而不是 Device Manager,是因为设备侧不该知道模型的事;
## 也不放在 Runtime,因为 Runtime 不读模型库。

import std/[os, tables]

import isvik/core/errors
import isvik/config/paths
import isvik/config/settings
import isvik/models/manifest
import isvik/models/storage

export manifest, storage

type
  ModelManager* = ref object
    ## 模型库的操作入口。
    store: ModelStore

  EligibilityStatus* = enum
    ## 模型在某设备上的可用性结论。
    esEligible = "eligible"
      ## 可以尝试编译。**不等于一定成功** —— 只是没有已知的阻碍。
    esUnsupported = "unsupported"
      ## 清单明确说该设备不支持。
    esRequiresStaticShape = "requires-static-shape"
      ## 该设备要求静态 shape,而调用方未提供或模型是动态的。
    esFilesMissing = "files-missing"
      ## 模型文件缺失,谈不上编译。
    esUnknown = "unknown"
      ## 清单没有该设备的信息。既不能说行,也不能说不行。

  Eligibility* = object
    ## 可行性判断结果。
    ##
    ## 带 `reason` 而不只是布尔:用户需要知道**为什么**不能在 NPU 上跑。
    status*: EligibilityStatus
    device*: string
    reason*: string
    requiresStaticShape*: bool
    shapeConstraints*: seq[ShapeConstraint]

proc newModelManager*(paths: IsvikPaths, s: Settings): ModelManager =
  ## 依据配置构造 Manager。
  new(result)
  result.store = newModelStore(paths, s)

proc newModelManager*(store: ModelStore): ModelManager =
  ## 直接注入模型库。主要供测试使用。
  new(result)
  result.store = store

proc store*(mgr: ModelManager): ModelStore = mgr.store
proc rootDirectory*(mgr: ModelManager): string = mgr.store.root

# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

proc list*(mgr: ModelManager,
           options: VerifyOptions = initVerifyOptions()): seq[StoredModel] =
  ## 列出全部模型,含完整性状态。
  mgr.store.listModels(options)

proc ids*(mgr: ModelManager): seq[string] =
  mgr.store.listIds()

proc has*(mgr: ModelManager, id: string): bool =
  mgr.store.exists(id)

proc info*(mgr: ModelManager, id: string,
           options: VerifyOptions = initVerifyOptions()): StoredModel =
  ## 单个模型的详情。不存在时抛 MODEL_NOT_FOUND。
  mgr.store.load(id, options)

proc count*(mgr: ModelManager): int =
  mgr.store.listIds().len

# ---------------------------------------------------------------------------
# 路径解析
# ---------------------------------------------------------------------------

proc resolveEntrypoint*(mgr: ModelManager, id: string,
                        role: string = EntrypointModel): string =
  ## 把「模型 id + 角色」解析为可直接交给 Backend 的绝对路径。
  ##
  ## 这是 Model System 与 Runtime 的接缝:Runtime 只认路径,不认 model id。
  ##
  ## 文件不存在时抛 MODEL_NOT_FOUND 并指出期望位置 —— 让 OpenVINO 在
  ## `readModel` 阶段以晦涩的状态码失败,排查成本高得多。
  let stored = mgr.store.load(id)

  if not stored.manifest.hasEntrypoint(role):
    raiseIsvikError(
      ecModelInvalid,
      "Model does not declare the requested entrypoint",
      "id=" & id & " role=" & role &
        " declared=" & stored.manifest.entrypoints.len.`$`
    )

  let rel = stored.manifest.entrypoint(role)
  let full = safeJoin(stored.contentDirectory, rel)

  if not fileExists(full):
    raiseIsvikError(
      ecModelNotFound,
      "Model file declared in the manifest does not exist",
      "id=" & id & " role=" & role & " expected=" & full
    )

  result = full

proc hasEntrypoint*(mgr: ModelManager, id: string, role: string): bool =
  ## 该模型是否声明了某个角色的入口(不检查文件是否存在)。
  mgr.store.loadManifest(id).hasEntrypoint(role)

# ---------------------------------------------------------------------------
# 可行性判断
# ---------------------------------------------------------------------------

proc checkEligibility*(mgr: ModelManager, id: string,
                       device: string,
                       staticShapeAvailable: bool = false): Eligibility =
  ## 判断模型能否在指定**语义设备**上尝试编译。
  ##
  ## `staticShapeAvailable` 表示调用方能否提供固定 shape(例如已决定
  ## 按固定长度分块)。这个参数存在是因为「模型是动态的」与「本次调用
  ## 用不用固定 shape」是两件事。
  ##
  ## **结论只表达「有没有已知阻碍」,不承诺编译一定成功。** 真正能不能跑
  ## 只有编译过才知道,这一点在 `esEligible` 的文档里写明了。
  let stored = mgr.store.load(id)
  result = Eligibility(
    status: esUnknown,
    device: device,
    reason: "",
    requiresStaticShape: false,
    shapeConstraints: @[]
  )

  if stored.issues.len > 0:
    result.status = esFilesMissing
    result.reason = "model files are incomplete: " & $stored.issues.len &
      " issue(s), first=" & stored.issues[0].path
    return

  let support = stored.manifest.deviceSupportFor(device)
  result.requiresStaticShape = support.requiresStaticShape
  result.shapeConstraints = support.shapeConstraints

  # 清单没写该设备:如实返回 unknown。既不放行也不拦住 ——
  # 由调用方决定是要试一把还是先要求用户补清单。
  var hasEntry = false
  for d in stored.manifest.deviceSupport:
    if d.device == device:
      hasEntry = true
      break
  if not hasEntry:
    result.status = esUnknown
    result.reason = "manifest has no device_support entry for " & device
    return

  if not support.supported:
    result.status = esUnsupported
    result.reason =
      if support.note.len > 0: support.note
      else: "manifest marks " & device & " as unsupported"
    if support.verified:
      result.reason.add(" (verified on this kind of device)")
    return

  if support.requiresStaticShape and not staticShapeAvailable:
    result.status = esRequiresStaticShape
    result.reason = device &
      " requires a static shape; caller did not provide one"
    return

  result.status = esEligible
  result.reason =
    if support.verified: "verified on " & device
    else: "declared supported on " & device & ", not verified on this machine"

proc isEligible*(e: Eligibility): bool =
  ## 是否没有已知阻碍。`unknown` 不算 —— 未知不是许可。
  e.status == esEligible

# ---------------------------------------------------------------------------
# 增删
# ---------------------------------------------------------------------------

proc importFrom*(mgr: ModelManager, sourceDir: string,
                 options: ImportOptions = initImportOptions()):
    ModelManifest =
  ## 从目录导入模型。
  mgr.store.importModel(sourceDir, options)

proc remove*(mgr: ModelManager, id: string) =
  ## 从库中删除模型。引用模式下不会删除外部文件。
  mgr.store.removeModel(id)

proc recordVerification*(mgr: ModelManager, id, device: string,
                         supported: bool, note: string = "",
                         requiresStaticShape: bool = false,
                         shapeConstraints: seq[ShapeConstraint] = @[]) =
  ## 记录一次真实的设备验证结果。
  ##
  ## 转发到 storage,使「谁有权声称已验证」只有一个位置(§13 / §27)。
  mgr.store.recordDeviceVerification(
    id, device, supported, note, requiresStaticShape, shapeConstraints)
