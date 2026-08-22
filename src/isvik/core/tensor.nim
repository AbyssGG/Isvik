## Isvik Core 的 Tensor
##
## 对应 Master Prompt §7(Core 包含 Tensor)与 §71(不暴露 Backend 实现细节)。
##
## ---
##
## ## 为什么 Core 需要自己的 Tensor 类型
##
## 上层(Services / API / CLI / GUI)不得接触 OpenVINO 的 `ov_tensor_t`
## 或 Resonance 的 `Tensor`(§5、§71)。因此 Core 定义自己的张量表示,
## 由 Backend 负责在边界上做双向映射。
##
## ---
##
## ## 数据所有权(§69)
##
## ```text
## Isvik Tensor 拥有 storage(seq[byte])
##        │
##        │ dataPtr() 出借裸指针
##        ▼
##   Backend 借用,不拥有,不释放
## ```
##
## 这个方向是有意选择的,而且与 Resonance 的 API 正好契合:
## `resonance.newTensor(typ, dims, data)` 从宿主指针创建张量而不接管所有权,
## 因此 Isvik 侧持有缓冲、Backend 侧借用,双方对所有权的理解一致,
## 不存在「谁该释放」的歧义。
##
## **生命周期契约**:`dataPtr()` 返回的指针只在该 Tensor 存活期间有效。
## Backend 不得在 Tensor 被回收后继续使用它。

import std/[strutils, sequtils]

import isvik/core/errors

type
  ElementType* = enum
    ## 张量元素类型。
    ##
    ## 取值集合对齐 OpenVINO 支持的元素类型,但**有意不包含 DYNAMIC** ——
    ## 一个已分配的张量必然有确定的元素类型,动态性属于模型端口的描述,
    ## 不属于张量本身。
    ##
    ## 字符串值是稳定契约(会出现在 API、日志与模型清单中)。
    etBool = "BOOL"
    etBF16 = "BF16"
    etF16 = "F16"
    etF32 = "F32"
    etF64 = "F64"
    etI4 = "I4"
    etI8 = "I8"
    etI16 = "I16"
    etI32 = "I32"
    etI64 = "I64"
    etU1 = "U1"
    etU4 = "U4"
    etU8 = "U8"
    etU16 = "U16"
    etU32 = "U32"
    etU64 = "U64"

  TensorObj = object
    elementType: ElementType
    shape: seq[int]
    storage: seq[byte]

  Tensor* = ref TensorObj
    ## 拥有自身数据缓冲的张量。

proc bitsPerElement*(et: ElementType): int =
  ## 单个元素占用的**位**数。
  ##
  ## 返回位而不是字节,因为 I4 / U4 / U1 是亚字节类型,用字节无法表示。
  case et
  of etU1: 1
  of etI4, etU4: 4
  of etBool, etI8, etU8: 8
  of etBF16, etF16, etI16, etU16: 16
  of etF32, etI32, etU32: 32
  of etF64, etI64, etU64: 64

proc isByteAligned*(et: ElementType): bool =
  ## 该类型是否按字节对齐。
  ##
  ## 亚字节类型(U1 / I4 / U4)需要位打包,当前阶段尚未实现,
  ## `newTensor` 会明确拒绝它们而不是给出错误的内存布局。
  bitsPerElement(et) >= 8

proc bytesPerElement*(et: ElementType): int =
  ## 单个元素占用的字节数。仅对按字节对齐的类型有意义。
  ##
  ## 对亚字节类型抛 IsvikError(NOT_IMPLEMENTED),而不是返回 0 或 1 ——
  ## 返回一个看似合理的数字会让上层算出错误的缓冲大小。
  if not et.isByteAligned:
    raiseIsvikError(
      ecNotImplemented,
      "Sub-byte element types require bit packing, which is not implemented yet",
      "elementType=" & $et & " bits=" & $bitsPerElement(et)
    )
  result = bitsPerElement(et) div 8

proc elementCountOf*(shape: openArray[int]): int =
  ## 形状对应的元素总数。
  ##
  ## 空形状表示标量,元素数为 1(与 OpenVINO 的 rank-0 张量一致)。
  ## 任一维度为 0 时总数为 0。
  result = 1
  for dim in shape:
    result *= dim

proc validateShape(shape: openArray[int]) =
  ## 形状必须非负。0 是合法的(空张量),负数不是。
  for i, dim in shape:
    if dim < 0:
      raiseIsvikError(
        ecInvalidParameter,
        "Tensor shape dimensions must not be negative",
        "index=" & $i & " value=" & $dim & " shape=" & $shape.toSeq
      )

# ---------------------------------------------------------------------------
# 构造
# ---------------------------------------------------------------------------

proc newTensor*(elementType: ElementType, shape: openArray[int]): Tensor =
  ## 分配一个零初始化的张量。
  ##
  ## 亚字节元素类型会被拒绝(见 `bytesPerElement`)。
  validateShape(shape)
  let perElement = bytesPerElement(elementType)  # 亚字节类型在此抛错
  let count = elementCountOf(shape)

  new(result)
  result.elementType = elementType
  result.shape = shape.toSeq
  result.storage = newSeq[byte](count * perElement)

proc expectedElementSize(elementType: ElementType, actualSize: int,
                         typeName: string) =
  ## 校验 Nim 侧类型宽度与张量元素类型一致。
  let expected = bytesPerElement(elementType)
  if actualSize != expected:
    raiseIsvikError(
      ecInvalidParameter,
      "Nim type width does not match tensor element type",
      "elementType=" & $elementType & " expectedBytes=" & $expected &
        " nimType=" & typeName & " nimTypeBytes=" & $actualSize
    )

proc newTensor*[T](elementType: ElementType, shape: openArray[int],
                   values: openArray[T]): Tensor =
  ## 从已有数据构造张量,数据被**复制**进张量自己的缓冲。
  ##
  ## 复制而非引用是有意的:张量的生命周期不应依赖调用方的临时变量,
  ## 否则出借给 Backend 的指针可能指向已失效的内存。
  expectedElementSize(elementType, sizeof(T), $T)
  validateShape(shape)

  let count = elementCountOf(shape)
  if values.len != count:
    raiseIsvikError(
      ecInvalidParameter,
      "Number of values does not match tensor shape",
      "shape=" & $shape.toSeq & " expectedCount=" & $count &
        " gotCount=" & $values.len
    )

  result = newTensor(elementType, shape)
  if count > 0:
    copyMem(addr result.storage[0], unsafeAddr values[0], count * sizeof(T))

# ---------------------------------------------------------------------------
# 访问
# ---------------------------------------------------------------------------

proc elementType*(t: Tensor): ElementType = t.elementType
proc shape*(t: Tensor): seq[int] = t.shape
proc rank*(t: Tensor): int = t.shape.len
proc elementCount*(t: Tensor): int = elementCountOf(t.shape)
proc byteLen*(t: Tensor): int = t.storage.len

proc isEmpty*(t: Tensor): bool =
  ## 是否不含任何元素(某个维度为 0)。
  t.elementCount == 0

proc dataPtr*(t: Tensor): pointer =
  ## 出借数据缓冲的裸指针,供 Backend 传给原生 API。
  ##
  ## 空张量返回 nil。返回的指针只在该 Tensor 存活期间有效(见模块顶部契约)。
  if t.storage.len == 0:
    return nil
  result = addr t.storage[0]

proc data*[T](t: Tensor, _: typedesc[T]): ptr UncheckedArray[T] =
  ## 以指定 Nim 类型访问数据。类型宽度必须与元素类型匹配。
  expectedElementSize(t.elementType, sizeof(T), $T)
  if t.storage.len == 0:
    return nil
  result = cast[ptr UncheckedArray[T]](addr t.storage[0])

proc toSeq*[T](t: Tensor, _: typedesc[T]): seq[T] =
  ## 将张量内容复制为 Nim seq。
  expectedElementSize(t.elementType, sizeof(T), $T)
  let count = t.elementCount
  result = newSeq[T](count)
  if count > 0:
    copyMem(addr result[0], unsafeAddr t.storage[0], count * sizeof(T))

proc setFrom*[T](t: Tensor, values: openArray[T]) =
  ## 用给定数据覆盖张量内容。元素数量必须完全一致。
  expectedElementSize(t.elementType, sizeof(T), $T)
  let count = t.elementCount
  if values.len != count:
    raiseIsvikError(
      ecInvalidParameter,
      "Number of values does not match tensor element count",
      "expectedCount=" & $count & " gotCount=" & $values.len
    )
  if count > 0:
    copyMem(addr t.storage[0], unsafeAddr values[0], count * sizeof(T))

proc fillZero*(t: Tensor) =
  ## 将缓冲清零。
  if t.storage.len > 0:
    zeroMem(addr t.storage[0], t.storage.len)

# ---------------------------------------------------------------------------
# 展示
# ---------------------------------------------------------------------------

proc shapeText*(shape: openArray[int]): string =
  ## 形状的可读文本,如 `[1, 3, 224, 224]`。
  "[" & shape.toSeq.mapIt($it).join(", ") & "]"

proc `$`*(t: Tensor): string =
  if t == nil:
    return "Tensor(nil)"
  "Tensor(" & $t.elementType & ", " & shapeText(t.shape) &
    ", " & $t.byteLen & " bytes)"
