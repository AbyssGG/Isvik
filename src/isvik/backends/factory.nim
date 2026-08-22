## Backend 工厂
##
## ---
##
## ## 这个模块解决什么问题
##
## `isvik devices` / `isvik doctor` / HTTP Server 都需要一个**真实的** Backend,
## 但 §23 禁止 CLI / Server / GUI 直接 import OpenVINO —— 那条约束由
## `tests/architecture/tarchitecture.nim` 机械强制,`cli/` 下出现
## `import ... openvino ...` 会直接让构建失败。
##
## 于是需要一个「知道具体 Backend 是谁」的地方,而它必须位于
## `src/isvik/backends/` 之下 —— 那是唯一被允许 import resonance / openvino
## 的目录。本模块就是那个位置。
##
## ```text
## cli / server / services        ← 只看到 core/backend.Backend 抽象
##        │  import isvik/backends/factory
##        ▼
## backends/factory               ← 本模块,唯一知道「默认是 OpenVINO」的地方
##        │
##        ▼
## backends/openvino/ov_backend   ← 允许 import resonance
## ```
##
## 这不是绕过约束,而是约束本来就需要的接缝:上层拿到的是抽象类型,
## **没有任何 OpenVINO 类型泄漏出去**。
##
## ---
##
## ## 为什么不把 MockBackend 也放进来
##
## `mock_backend.nim` 明确写了「不得被编译进产品的默认执行路径」。
## 若工厂按名字返回 Mock,产品二进制里就永远链接着一个假 Backend,
## 还多出一个「用户能不能误用它」的问题。测试需要 Mock 时直接构造并注入,
## 不必经过工厂。
##
## ---
##
## ## 可用性查询只做探测
##
## `inferenceRuntimeAvailable()` 不初始化、不抛异常。`isvik doctor` 的全部
## 意义就是在环境有问题时还能运行,因此这里绝不能因为运行时缺失而失败。

import isvik/core/backend
import isvik/backends/openvino/ov_backend

const
  DefaultBackendName* = OpenVinoBackendName
    ## 默认 Backend 的稳定标识。上层用它做展示与日志,不用它做类型判断。

  InferenceRuntimeName* = "OpenVINO"
    ## 底层推理运行时的展示名称(用于 doctor 输出)。

  UnknownRuntimeVersion* = UnknownVersionText
    ## 取不到真实版本时的标记。转发 Backend 的定义,避免两处各写一个字面量。

proc newInferenceBackend*(): Backend =
  ## 创建默认 Backend 实例。
  ##
  ## **不触碰 OpenVINO** —— 真正的加载发生在 `initialize()`。因此即使运行时
  ## 缺失,构造也一定成功,`doctor` 能先拿到实例再询问它是否可用。
  newOpenVinoBackend()

proc inferenceRuntimeAvailable*(): bool =
  ## 底层推理运行时能否加载。纯探测,可重复调用,不抛异常。
  openVinoRuntimeAvailable()

proc inferenceRuntimeError*(): string =
  ## 加载失败的原因。可用时返回空字符串。
  openVinoRuntimeLoadError()

proc inferenceRuntimeVersion*(): string =
  ## 真实的运行时版本。
  ##
  ## 取不到时返回 `UnknownRuntimeVersion`,**不编造版本号**(§13 / §66)。
  if not openVinoRuntimeAvailable():
    return UnknownRuntimeVersion
  let b = newOpenVinoBackend()
  result = b.version()
