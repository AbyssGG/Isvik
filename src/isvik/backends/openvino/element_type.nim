## Isvik ElementType ↔ OpenVINO OvElementType 的双向映射
##
## 对应 Master Prompt §9(Backend Implementation)。
##
## ---
##
## ## 为什么这层必须存在,而且必须逐个显式写
##
## 两侧的枚举**都不是**对方的子集,而且数值都不稳定:
##
## - Isvik 的 `ElementType` 有 16 个值,刻意不含 DYNAMIC(见 core/tensor.nim:
##   已分配的张量必然有确定类型,动态性属于模型端口而非张量)。
## - OpenVINO 的 `ov_element_type_e` 有 26 个值,且**数值跨版本变动**
##   (`U8` 在 2023.3 是 14、在 2025.4/2026.3 是 16)。
##
## 因此这里既不能用 `ord()` 直接转,也不能靠名字拼接反射。**必须逐个显式写,
## 并有逐个断言的测试守护。** 这类映射写错不会编译失败、不会抛异常,只会让
## 张量数据被按错误的类型解释 —— 而 Resonance 已经因为同一类错误吃过一次亏
## (`U8` 曾被写成 13,实际那是 `U3`)。
##
## ---
##
## ## 方向不对称,而且是有意的
##
## ```text
## Isvik → OpenVINO    全映射,不会失败(16 个都有对应)
## OpenVINO → Isvik    部分映射,10 个值没有对应
## ```
##
## 没有对应的 10 个:`DYNAMIC`、`U2`、`U3`、`U6`、`NF4`、`F8E4M3`、`F8E5M3`、
## `STRING`、`F4E2M1`、`F8E8M0`。
##
## 遇到它们时**抛 NOT_IMPLEMENTED,不做近似**。把 `NF4` 当成 `U4`、把
## `F8E4M3` 当成 `I8` 之类的「宽度相同就凑一下」会产出静默错误的数值结果,
## 比直接失败糟糕得多(§20.5.13、§66:不得伪装支持)。
##
## `STRING` 尤其不能凑:它在 OpenVINO 里是变长字符串张量,内存布局与所有
## 数值类型都不同。tokenizer 的输入输出就是 STRING 张量,Task 15 引入
## tokenizer 时需要单独的处理路径,而不是套用数值张量的那套。

import std/options

import isvik/core/errors
import isvik/core/tensor

import resonance

const
  IsvikToOv*: array[ElementType, OvElementType] = [
    etBool: BOOLEAN,
    etBF16: BF16,
    etF16: F16,
    etF32: F32,
    etF64: F64,
    etI4: I4,
    etI8: I8,
    etI16: I16,
    etI32: I32,
    etI64: I64,
    etU1: U1,
    etU4: U4,
    etU8: U8,
    etU16: U16,
    etU32: U32,
    etU64: U64
  ]
    ## Isvik → OpenVINO 的全映射。
    ##
    ## 用 `array[ElementType, ...]` 而不是 `case`:数组下标是编译期完备的,
    ## 往 `ElementType` 里加一个值而忘了在这里加映射会**编译失败**,
    ## 而 `case` 只会在运行时才暴露(或者被一个 `else` 分支悄悄吞掉)。

  UnmappableOvTypes* = [
    DYNAMIC, U2, U3, U6, NF4, F8E4M3, F8E5M3, STRING, F4E2M1, F8E8M0
  ]
    ## OpenVINO 有、Isvik 没有对应的元素类型。
    ##
    ## 导出这个列表是为了让测试能断言「映射表与这份清单互补、无遗漏、无重叠」——
    ## 两边加起来必须正好是 OpenVINO 的全部 26 个值。

proc toOvElementType*(et: ElementType): OvElementType =
  ## Isvik → OpenVINO。全映射,不会失败。
  IsvikToOv[et]

proc tryFromOvElementType*(ov: OvElementType): Option[ElementType] =
  ## OpenVINO → Isvik。无对应时返回 `none`。
  ##
  ## 供需要「探测而不失败」的场景使用(例如 `isvik doctor` 报告某个模型端口
  ## 的类型是否受支持),这类场景不应该因为遇到一个不支持的类型就抛异常。
  ##
  ## 实现上反查 `IsvikToOv` 而不是另写一张表:两张手写的表会各自漂移,
  ## 而反查保证两个方向永远一致。表只有 16 项,线性扫描的代价可以忽略。
  for et in ElementType:
    if IsvikToOv[et] == ov:
      return some(et)
  none(ElementType)

proc fromOvElementType*(ov: OvElementType): ElementType =
  ## OpenVINO → Isvik。无对应时抛 IsvikError(NOT_IMPLEMENTED)。
  ##
  ## 错误信息里带上 OpenVINO 的类型名与数值 —— 数值是排查跨版本枚举漂移的
  ## 唯一线索,只给名字不够。
  let mapped = tryFromOvElementType(ov)
  if mapped.isNone:
    raiseIsvikError(
      ecNotImplemented,
      "OpenVINO element type has no Isvik equivalent",
      "ovElementType=" & $ov & " ovValue=" & $ord(ov)
    )
  mapped.get

proc isMappableToIsvik*(ov: OvElementType): bool =
  ## 该 OpenVINO 元素类型是否有 Isvik 对应。
  tryFromOvElementType(ov).isSome
