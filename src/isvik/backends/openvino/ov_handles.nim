## Resonance 句柄类型的改名层
##
## ---
##
## ## 这个模块为什么必须存在
##
## Isvik 的 `src/isvik/core/tensor.nim` 与 Resonance 的
## `src/resonance/tensor.nim` **文件名相同**,且各自定义了一个叫 `Tensor` 的
## 类型。同时 import 两者时,Nim 报:
##
## ```text
## ambiguous identifier: 'Tensor' -- use one of the following:
##   tensor.Tensor: Tensor
##   tensor.Tensor: Tensor
## ```
##
## 注意两个候选**显示为同一个限定名**。这不是提示信息写得差,而是 Nim 的
## 模块限定只用文件名(不含路径),所以 `tensor.Tensor` 对两者都成立 ——
## 用限定名无法消除这个歧义,`import ... as` 也不行(别名只改模块的引用名,
## 被 import 的符号仍然直接进入作用域)。
##
## 唯一干净的出路是:在一个**只看得到 Resonance** 的模块里给它的类型换个名字。
## 本模块就是那个模块 —— 它刻意不 import `isvik/core/tensor`,因此这里的
## `Tensor` 无歧义地指 Resonance 的那个。
##
## 调用方(`ov_backend.nim`)于是可以这样写:
##
## ```nim
## import isvik/core/tensor                        # Tensor / newTensor = Isvik 的
## import resonance except Tensor, newTensor        # 其余 Resonance 符号
## import isvik/backends/openvino/ov_handles        # OvTensorHandle / newOvTensor
## ```
##
## ---
##
## ## 只改名,不加抽象
##
## 这里刻意**不**包装方法、不加校验、不做转换 —— 那些属于 `ov_backend.nim`。
## 本模块的职责单一到只有「换个名字」,多做一点都会让人误以为这是一层
## 适配器,进而把逻辑往这里堆。

import resonance

type
  OvTensorHandle* = Tensor
    ## Resonance 的 `Tensor`(OpenVINO 张量句柄)。
    ##
    ## 与 Isvik 的 `Tensor` 是完全不同的东西:
    ##
    ## | | 数据所有权 | 生命周期 |
    ## | --- | --- | --- |
    ## | Isvik `Tensor` | 自己持有 `seq[byte]` | 由 Nim GC 管理 |
    ## | `OvTensorHandle` | 不持有,只是视图 | 需显式 `close()` |

proc newOvTensor*(typ: OvElementType, dims: seq[int64],
                  data: pointer): OvTensorHandle =
  ## 创建 OpenVINO 输入张量。
  ##
  ## 非空输入继续使用 host-backed 视图，调用方必须保证缓冲在张量使用期间
  ## 一直存活。零元素张量没有可出借的 host pointer，此时让 OpenVINO 创建
  ## owned tensor；shape 仍被完整保留，也不需要复制 payload。
  if data == nil:
    newOwnedTensor(typ, dims)
  else:
    newTensor(typ, dims, data)
