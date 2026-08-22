# Isvik 开发日志(Development Log)

**最后更新**:2026-08-20
**当前进度**:Task 18 / 19 已完成(Application Services、采样、四个 Protocol Adapter、HTTP Server、Benchmark、Tool Calling 接入解码,均 CPU 实测)
**剩余**:Structured Output 接入解码、stop 序列 / penalties、并发与 SSE 增量投递(§70)、`docs/`、GUI
**唯一权威规范**:`Isvik_AI_MASTER_PROMPT_FINAL.md`。本文件是**过程记录**,不是规范。两者冲突时以规范为准。

---

## 一、这份文档记什么

三类内容,其它一律不写:

1. **决策及其理由**:选了什么、**拒绝了什么**、为什么。只记结论会让后人无法判断该结论在新情况下是否还成立。
2. **实测事实**:版本号、设备名、耗时、测试计数。凡未实测的一律标注「未验证」,不得推断后当事实写。
3. **踩过的坑**:现象 → 根因 → 修复。目的是不重复踩。

进度表在 `README.md`,不在这里重复。

---

## 二、项目定位与硬约束

Isvik 是 **100% Nim** 的本地 AI Runtime,通过 **Resonance** 库调用 **OpenVINO C API**,面向 **Intel CPU / GPU / NPU**。

硬约束(来自规范,违反即返工):

| 约束 | 含义 |
| --- | --- |
| 100% Nim | 运行时不得依赖 Python;C 代码仅允许作为 ABI 适配层编译进本体 |
| 分层不可越界 | `core/` 不得 import Resonance;只有 `backends/openvino/` 可以 |
| 不得伪造 | 测试、Benchmark、NPU 状态、硬件能力一律实测。未验证必须显式说「未验证」 |
| 中文交付 | 回复、报告、代码注释、文档均为中文 |
| 顺序施工 | 19 个 Task 严格按序 Build → Test → 报告 |

---

## 三、进度时间线

### Task 1:项目骨架与可复现构建

建立 `isvik.nimble` / `nim.cfg` / `src` / `tests` 布局,`nimble test` 一条命令跑全量。

**决策:`core/` 用扁平 `.nim` 文件,不照搬规范 §45 的子目录结构。**
理由:当前每个关注点都是单文件量级,提前造深层目录只增加导航成本。
拒绝:机械照搬 §45。规范给的是目标形态而非施工顺序,代码量到了再拆。

**决策:`nimble` 的 `version` 用字符串字面量,靠测试强制与 `version.nim` 同步。**
理由:nimble 解析 `.nimble` 时不接受常量,只认字面量。
拒绝:`include version.nim`(直接报错)。改为 `tversion.nim` 断言两处一致,漏改即测试失败。

### Task 2:统一错误模型

`core/errors.nim`:`IsvikErrorCode` 带字符串值(`ecXxx = "SCREAMING_SNAKE"`),`$code` 即稳定对外契约。

**事实核实:规范说「§22 + §20.5.7 共 17 个码」有误。** 实测 §22 有 13 个、§20.5.7 有 16 个,且 §22 是 §20.5.7 的**真子集**,并集为 16。

**决策:加第 17 个码 `ecNotImplemented`,并在注释中显式标注为「Isvik 扩展」。**
理由:§20.5.13 第 12 条要求能表达 Unsupported、§14 要求「pull 未实现不得伪装成成功」,而原 16 个码里没有对应语义。
拒绝:复用 `MODEL_UNSUPPORTED`(语义是「模型本身不受支持」,不是「功能没写」,混用会让调用方无法区分)。

**安全设计:`detail` 字段绝不进入 API 响应。**
`toJson()` 只输出 `{"error":{"code","message"}}`(§22 形状),`detail` 只出现在 `logLine()`。OpenVINO 的错误串常含绝对路径,泄漏到 HTTP 响应里等于泄漏文件系统布局。已有测试断言敏感路径不出现在响应中。

### Task 3:结构化事件与日志

**决策:`RuntimeEvent`(§29)与 `InferenceEvent`(§20.5.4)分开命名,不统一。**
理由:前者是进程级生命周期事件(GUI 的 Activity 页消费),后者是 token 级流事件(Protocol Adapter → SSE 消费)。是两种东西,统一命名会在 Task 7 撞车。

**决策:§29 用 `SCREAMING_SNAKE`,§20.5.4 保留原文 `PascalCase`。**
理由:§29 原文带空格(如 `Cache Hit`)无法直接作标识符,必须转换;§20.5.4 原文本身就是合法标识符。为了「风格统一」去改后者反而偏离规范原文。

**决策:依赖方向是 `logging → core`,`core` 不依赖 `logging`。**
理由:Core 需要记日志时只发布事件,由 logging 订阅落盘。这样 §29(GUI 消费结构化事件,不解析日志文本)与 §34(Console + File 双 sink)可以同时成立。

**决策:`ConsoleSink` 默认写 stderr。**
理由:`--json` 模式下 stdout 必须是干净的机器可解析输出。日志混进去会让下游 `jq` 直接失败。

`dispatch` 遍历订阅者**快照**:handler 内部 subscribe/unsubscribe 不破坏本次迭代。handler 异常被捕获并计入 `handlerErrorCount` —— 可观测,而非静默吞掉。

### Task 4:平台路径与配置

`resolveIsvikHome()`:`ISVIK_HOME` > `getHomeDir()/.isvik`。**不硬编码盘符或用户名。**

`checkRelativePath` 返回 `Option[string]`(拒绝原因),拒绝的形式包括:空串、NUL 字节、首尾空白、绝对路径、UNC、含 `:`(盘符相对路径 + NTFS ADS)、`..` 段、`.` 段、空段、**段尾点或空格**、段首空格、Windows 保留设备名、非法字符 `<>"|?*` 与控制字符。

其中两条容易漏:
- **段尾点/空格**:Windows 会静默剥离,导致「校验通过的名字」与「实际落盘的名字」不一致,校验形同虚设。
- **保留设备名在扩展名之前判定**:`CON.txt` 也必须拒绝。

`isInsideDirectory` 必须以 `base + 分隔符` 开头比较,否则 `C:\isvikEVIL` 会被判定为在 `C:\isvik` 内。

**决策:配置缺失字段回落默认值;字段存在但类型错或取值非法则报错。**
理由:静默把非法配置改成默认值是最糟的选择 —— 程序行为与用户所写不符,且没有任何提示。缺失回落是向前兼容,非法报错是可诊断性,两者不矛盾。

**决策:默认端口 `7317`,有意不用 Ollama 的 `11434`(§81)。**
默认 host 为 `127.0.0.1`,§21 禁止默认 `0.0.0.0`。

`saveSettings` 先写 `.tmp` 再替换。**已在注释中如实说明这不是完全原子**:Windows 的 `moveFile` 要求目标不存在,删除与移入之间存在窗口;真正原子需要 `ReplaceFileW`。留作后续。

### Task 5:Backend 抽象 + MockBackend

**决策:`Backend` 用继承(`ref object of RootObj` + 17 个 `method`),不用 vtable 结构体。**
**决策:操作方法挂在 `Backend` 上,不挂在各句柄类型上。**
理由:具体 Backend 需要访问自身状态(如 OpenVINO 的 Core 实例),方法挂句柄上就得让句柄反向持有 Backend。挂 Backend 上只需要一棵 method 分派树。
拒绝:插件注册表 + 动态加载(§6 明确不过度抽象;当前只有两个 Backend,注册表是纯粹的间接层)。

基类 17 个 method 全部抛 `ecNotImplemented` —— 新 Backend 漏实现某个方法时得到明确错误,而不是静默返回零值。

**决策:MockBackend 是必需品,不是测试脚手架。**
理由:它让 Core 的**全部生命周期与错误路径**能在「无 OpenVINO、无 NPU」的机器上确定性验证。11 个 `MockFailure` 注入点覆盖各阶段失败,`callLog` 验证调用序列,`doubleReleaseCount` 验证不会重复释放。没有它,CI 就只能跑在有 NPU 的机器上。

### Task 6:架构适应性测试

**决策:架构约束靠测试机械强制,扫描器解析 `import`/`from`/`include`/`export` 语句,不搜文本。**
理由:`core/backend.nim` 的注释里就写着「本文件不得 import resonance」这句话本身。搜文本会把注释当违规,产生假警报,然后团队就会关掉这个测试。

扫描器必须含**负例验证**:构造一个已知违规的假输入,确认扫描器真的报错。否则一个永远返回「通过」的扫描器也能让测试全绿。

**决策:`backends/openvino/` 的例外通过「不在受检范围内」表达,不给单个文件开例外。**
理由:白名单机制一旦存在就会被滥用,下一个人想 import 时也往里加一行。用范围表达则边界清晰:受检目录里没有例外。

### Task 7:统一请求 / 结果 / 事件流 / Tool / Structured Output

`UnifiedInferenceRequest` 实现 §20.5.3 全部 10 个字段,可选参数全部用 `Option[T]` —— 区分「用户没传」与「用户传了零值」。这两者在采样参数上语义完全不同(没传 temperature 用模型默认,传了 `0.0` 是贪心解码)。

`CancellationToken` 设计为 nil 安全:不传取消令牌是常态,不应强迫调用方造一个。

**决策:流式与非流式共用一条代码路径(`StreamAccumulator`)。**
理由:分成两条路径,两者的行为迟早分叉 —— 通常是非流式修了个 bug 而流式没跟上。让非流式 = 流式 + 累积,分叉在结构上不可能发生。

**决策:`ProtocolStreamChunk` 不含 SSE 物理格式。**
理由:`event:` / `data:` 前缀属于 HTTP 传输层,由 server 拼装。混进核心类型会让这个类型无法用于非 SSE 协议(如 WebSocket 或本地 IPC)。

### Task 8:补齐 Resonance 缺失的 OpenVINO 能力(上游改动)

这是第一个真正需要 `openvino_c.dll` 的节点。

**决策:Resonance 从 `{.dynlib.}` 静态绑定改为运行时手动加载(`LoadLibrary` + `GetProcAddress`)。**
理由:这是**必须**改,不是优化。Nim 的 `{.dynlib.}` 在加载失败时调用 `nimLoadLibraryError`,该函数直接 `quit(1)`,**无法 try/except 捕获**。后果是 `isvik.exe` 在没有 OpenVINO 的机器上根本无法启动 —— 连 `isvik doctor`(其唯一目的就是诊断「OpenVINO 缺不缺」)都跑不起来。
拒绝:沿用 `{.dynlib.}`(doctor 不可用)、`--dynlibOverride`(仍然走 quit 路径)。

改动文件:`Resonance/src/resonance/{c_api.nim, core.nim, perf_count_wrapper.c}`、`Resonance/resonance.nimble`(加 `task test`)、`Resonance/tests/tbindings.nim`(新建)。

### Task 9:OpenVINO Backend 骨架

第一个真正把 Core 与 OpenVINO 接起来的节点。新增 4 个文件:

```text
src/isvik/backends/openvino/
├── ov_handles.nim      Resonance 句柄类型的改名层
├── element_type.nim    元素类型双向映射
├── error_mapping.nim   OpenVINO 错误 → Isvik 错误码
└── ov_backend.nim      Backend 的 17 个 method 实现
tests/backends/tovbackend.nim   45 个测试
```

**架构测试的自动生效机制起作用了。** `tarchitecture.nim` 里那条「若
`backends/openvino` 已存在,断言它确实 import 了 Resonance」的用例,在目录被创建后
从 SKIPPED 变成 **[OK]** —— 不需要有人记得回来打开它。同时其余架构约束仍全部通过,
证明 `core/` 与产品层没有借机偷偷 import resonance。tarchitecture 现在
**OK=44 FAILED=0 SKIPPED=0**。

#### 决策:必须加一个只为改名而存在的模块

**问题**:Isvik 的 `src/isvik/core/tensor.nim` 与 Resonance 的
`src/resonance/tensor.nim` **文件名相同**,且各自有一个叫 `Tensor` 的类型。
同时 import 时 Nim 报:

```text
ambiguous identifier: 'Tensor' -- use one of the following:
  tensor.Tensor: Tensor
  tensor.Tensor: Tensor
```

**两个候选显示为同一个限定名。** Nim 的模块限定只用文件名(不含路径),所以
`tensor.Tensor` 对两者都成立 —— **用限定名无法消除这个歧义**。
`import resonance as ov` 也不行:模块别名只改模块的引用名,被 import 的符号
仍然直接进入作用域。

**决策**:新增 `ov_handles.nim`,它**刻意不 import `isvik/core/tensor`**,
因此其中的 `Tensor` 无歧义地指 Resonance 的那个,在那里把它别名为
`OvTensorHandle`,并提供改名后的构造函数 `newOvTensor`。调用方于是写:

```nim
import isvik/core/tensor                    # Tensor / newTensor = Isvik 的
import resonance except Tensor, newTensor    # 其余 Resonance 符号
import isvik/backends/openvino/ov_handles    # OvTensorHandle / newOvTensor
```

拒绝:重命名 Isvik 的 `core/tensor.nim`(它是 Core 的公开概念,不该为一个
下游 Backend 的 import 便利让路);拒绝在 `ov_handles.nim` 里顺便包装方法或加校验
(那会让人误以为它是适配层,进而把逻辑往里堆 —— 它的职责必须单一到只有改名)。

#### 关键设计一:输入张量的生命周期,两张表都是防 GC 的锚

Resonance 的 `newTensor` 走 `ov_tensor_create_from_host_ptr`,**OpenVINO 只持有
指针、不拥有数据**;而 Isvik 的 `Tensor` 把数据放在自己的 `seq[byte]` 里。
接缝处有两个悬空风险:

| 若被 GC 回收 | 后果 |
| --- | --- |
| Isvik `Tensor` | 其 `seq[byte]` 释放 → OpenVINO 手里的指针悬空 |
| Resonance `Tensor` | `=destroy` 调 `ov_tensor_free` → OpenVINO 内部对象失效 |

所以 `OvBackendInferRequest` 同时持有 `inputTensors: Table[int, Tensor]` 与
`nativeInputs: Table[int, OvTensorHandle]`。**这两张表不是缓存,是锚** ——
注释里写明了这点,否则后人很可能觉得「存了没用的东西」而删掉。

这类错误不会在 `setInputTensor` 处报错,只在后续 `infer` 时读到垃圾或崩溃,
现场与起因相距很远。已有测试「重复绑定同一索引不泄漏,且以最后一次为准」
断言同一索引只留一个绑定(覆盖时先 `close()` 旧的)。

#### 关键设计二:输出张量必须拷贝

`core/backend.nim` 的契约要求返回「Isvik 自己拥有数据的 Tensor」。这不是洁癖:
OpenVINO 输出缓冲**只在下一次 infer 之前有效**,直接包一层返回,调用方拿到的
引用会在下一轮推理被悄悄改写。

已有测试「输出张量是副本,不随下一次推理改变」专门验证这条:取第一次输出的
首元素,换 token 再推一次,断言第一次的结果没被改写、且两次结果不同。

拷贝前还有一道大小一致性检查:OpenVINO 报的 `byteSize` 与 Isvik 算出的
`byteLen` 不等时直接失败,而不是照较小的那个拷 —— 不等意味着两边对该类型的
内存布局理解不一致,照着拷会读越界或写越界。

#### 关键设计三:错误映射以「操作上下文」为主,状态码只做细分

同一个 `ov_status_e` 在不同调用点意味着完全不同的问题。最典型的是 `NOT_FOUND`:

| 出现位置 | 真实含义 | Isvik 错误码 |
| --- | --- | --- |
| `readModel` | 模型文件找不到 | `MODEL_NOT_FOUND` |
| `compileModel` | 设备名不存在 | `DEVICE_NOT_AVAILABLE` |
| `importModel` | blob 文件找不到 | `CACHE_INVALID` |

所以映射函数以 `OvOperation` 为主参数。反过来做(先按状态码分流)会把这三种
压成同一个无法区分的错误。已有测试逐条断言这三个映射不同。

另一条值得记的:推理阶段的 `PARAMETER_MISMATCH` / `INVALID_C_PARAM` /
`OUT_OF_BOUNDS` 映射到 `INVALID_PARAMETER` 而不是 `INFERENCE_FAILED` ——
这是调用方传错了形状/类型/索引,报 INFERENCE_FAILED 会让人去查推理引擎,
而真正该改的是调用参数。

`INFER_CANCELLED` 映射到 `STREAM_CANCELLED`,**刻意不新增第 18 个错误码**:
错误码是对外稳定契约,能用现有语义表达就不该扩张;而「推理自己取消了」这种
情况在 Isvik 里不存在,取消必然源自调用方。

`guardOv` 模板把所有调用 Resonance 的代码包成「只会抛 IsvikError」。捕获顺序有讲究:
`OpenVinoUnavailableError` **不是** `OpenVinoError` 的子类(两者都直接继承
`CatchableError`),必须单独一个分支且排在前面。

#### 关键设计四:元素类型映射不对称,且拒绝近似

```text
Isvik → OpenVINO    全映射(16 个都有对应),用 array[ElementType, ...]
                    下标编译期完备 —— 加了新类型忘了加映射会编译失败
OpenVINO → Isvik    部分映射,10 个值没有对应
```

无对应的 10 个:`DYNAMIC`、`U2`、`U3`、`U6`、`NF4`、`F8E4M3`、`F8E5M3`、
`STRING`、`F4E2M1`、`F8E8M0`。遇到时**抛 NOT_IMPLEMENTED,不做近似**。
把 `NF4` 当 `U4`、把 `F8E4M3` 当 `I8` 这种「宽度相同凑一下」会产出静默错误的
数值结果,比直接失败糟糕得多。

`STRING` 尤其不能凑:它在 OpenVINO 里是变长字符串张量,布局与所有数值类型都不同。
**tokenizer 的输入输出正是 STRING 张量**,Task 15 引入 tokenizer 时需要单独的
处理路径,而不是套用数值张量那套。

反向映射通过反查正向表实现,不另写一张表 —— 两张手写的表会各自漂移。
测试断言「可映射 16 + 不可映射 10 = OpenVINO 全部 26 个」,OpenVINO 新增类型时
这条会失败并提醒人来决定它该怎么办,而不是让它悄悄落进某个 else 分支。

#### 埋给 Task 18 的伏笔:`fromBlob` 标记

`importCompiledModel` 把 `profilingEnabled` 如实记为 `false` 并置
`fromBlob = true`。原因是 DEVLOG 6.1 第 1 条那条硬约束:blob 不含运行期属性,
而本机 NPU 驱动会拒绝在 import 之后设置 `PERF_COUNT`。

记成 `true` 会让 Task 18 报告一份空数据却声称采集成功 —— **那就是伪造 Benchmark**。
有了这两个字段,上层才能区分「没开 profiling」与「开了但驱动拒绝」。
已有测试断言 blob 导入后 `fromBlob == true` 且 `profilingEnabled == false`。

#### 测试:45 个用例,分三档外部条件

```text
第 1 档  纯逻辑(类型映射、错误映射、未初始化行为)   25 个,无条件
第 2 档  需要 openvino_c.dll                          9 个
第 3 档  需要 DLL + 真实 IR 模型                     16 个(含端到端推理)
```

缺条件时 SKIP 而非 FAILED。第 3 档的模型通过 `ISVIK_TEST_MODEL_XML` 提供。

**第 3 档能做语义级验证,而不只是「没报错」。** 用的是 Gemma 4 E2B 的
`text_embeddings` 子 IR:

```text
输入  input          I64   [-1, -1]        token id
输出  inputs_embeds  F32   [-1, -1, 1536]  对应向量
```

embedding 查表有一条可断言的性质:**相同 token id 必须得到完全相同的向量**。
于是传 `[[1, 2, 1]]` 一次验证四件事:输入数据真的传到了 OpenVINO(否则输出会是
全零)、输出真的是查表结果(位置 0 与 2 逐元素相等且与位置 1 不同)、数据布局
理解正确(row-major,步长 1536)、拷贝完整。另外单独断言输出非全零 ——
否则前两条会「通过」却毫无意义。

只断言「infer 没抛异常」的测试无法区分「推理正确」与「输出了一堆零」。

---

## 三点五、Task 9 带来的 Resonance 上游改动

Task 9 暴露了 Resonance 的三处真实缺失,都在上游补齐(§0.5.2:Isvik 不自己
另写 FFI)。

### 1. 只有 `=destroy`,没有显式释放 —— 与 §69 冲突

**问题**:Resonance 的 5 个句柄类型(`Core` / `Model` / `CompiledModel` /
`InferRequest` / `Tensor`)全部只有析构器。而 `core/backend.nim` 明确要求
「不依赖析构器的时机」。

**为什么这不是洁癖**:编译后的模型持有**设备端内存**。NPU 上这块内存很紧张,
等 GC 决定时机意味着另一个本该成功的编译会失败 —— 而失败原因是「内存被逻辑上
已经不用的模型占着还没归还」,这种问题极难排查。

**改动**:5 个类型各加 `close()` / `isClosed()` / `requireOpen()`。
`close()` 释放后把指针置 nil,因此**天然幂等**,且后续 `=destroy` 变成 no-op。

**同时引入的新风险与应对**:有了 close 就有了 use-after-close。此前所有函数
直接用 `x.pXxx` 不检查 nil,close 之后会把 nil 传进 C API —— 而失败方式**不一致**:
某些入口返回 `INVALID_C_PARAM`,某些直接解引用崩溃。后者的现场完全看不出起因。
因此给所有涉及句柄的入口加了 `requireOpen`,把它变成一个指明操作名的可捕获错误。

### 2. `OpenVinoError` 不携带结构化状态码

**问题**:状态码只被插值进 `msg` 字符串(`"... failed with status -14 (INVALID_C_PARAM)"`)。
Isvik 需要按状态码分流错误码,从字符串解析太脆弱 —— 措辞一改就失效。

**改动**:给 `OpenVinoError` 加 `status*: OvStatus` 与 `action*: string` 两个字段。
消息格式保持不变(向后兼容),字段是纯增量,已有的
`except OpenVinoError as e: echo e.msg` 照常工作。

### 3. 缺两个读取张量元信息的 C API

**问题**:`getOutputTensor` 要把 OpenVINO 的输出拷成 Isvik Tensor,必须知道
元素类型与字节数。输出张量的类型由**模型**决定,不能假定。

**改动**:补 `ov_tensor_get_element_type` 与 `ov_tensor_get_byte_size`,
并在 `tensor.nim` 上层包装为 `getElementType()` / `getByteSize()`。

用 OpenVINO 报的 `byteSize` 而不是自己算 `elementCount × elementSize`:
亚字节类型下两者不一致,且只有 OpenVINO 知道真实的对齐后大小。

Resonance 改动后测试复验:**OK=27 FAILED=0 SKIPPED=2**,与改动前一致。

---

## 四、修掉的 Resonance 真实 bug

依据 OpenVINO 官方头文件**逐字核对**得出,不是猜测。

### bug 1:`ov_status_e` 少了 4 个状态码

原实现 14 个值,官方头文件 18 个。缺失:

| 名称 | 值 |
| --- | ---: |
| `INVALID_C_PARAM` | -14 |
| `UNKNOWN_C_ERROR` | -15 |
| `NOT_IMPLEMENT_C_METHOD` | -16 |
| `UNKNOW_EXCEPTION` | -17 |

(最后一个的拼写缺 `N`,这是 OpenVINO 上游的拼写,照抄以保持一致。)

另外 `ALLOCATED` 拼错,应为 `NOT_ALLOCATED`。

**为什么要紧**:`-14 INVALID_C_PARAM` 恰好是变长参数用错时最常见的返回码(见下方 NimVoice 经验第 2 条)。枚举里没有它,错误会被显示成一个裸数字,排查时无从下手。

### bug 2:`ov_element_type_e` 缺 `U2` / `U3` / `U6`,导致 `U4` 起全部偏移

**`U8` 原本写 13,正确值是 16。数值 13 实际对应 `U3`。**

后果:任何用 `U8` 张量的路径都会把数据当 `U3` 解释。这个 bug 之所以一直没被发现,是因为上游 NimVoice 的 TTS 流水线只用 `F32` 和 `I64`,从未触碰 `U8`。而 Isvik 要跑 LLM,`U8` 是量化权重的常用类型 —— 这个 bug 一定会被触发。

跨版本事实(实测 + 头文件核对):

| | 2023.3 | 2025.4 | 2026.3 |
| --- | --- | --- | --- |
| `UNDEFINED` | 独立值 | 0 | **已移除** |
| `DYNAMIC` | 1(独立) | 0(= UNDEFINED) | **0** |
| `F32` | 5 | 4 | 4 |
| `U4` | 13 | 14 | 14 |
| `U8` | 14 | 16 | 16 |
| `U2`/`U3`/`U6` | 不存在 | 存在 | 存在 |

**结论:`ov_element_type_e` 的数值在 OpenVINO 版本间不稳定。** 任何硬编码都必须标注所依据的版本号,并有测试断言。2026.3 的数值与 2025.4 完全一致,只是移除了 `UNDEFINED` 这个名字。

---

## 五、环境与硬件实测事实

以下全部为本机实测,时间 2026-08-20。

### 工具链

| 项 | 值 |
| --- | --- |
| Nim | 2.2.10(Windows amd64) |
| nimble | 0.22.2 |
| C 编译器 | gcc (tdm64-1) 10.3.0 |
| git | **2.55.0.windows.4,已在系统级 PATH** |
| git-lfs | 3.7.1(随 git 安装,无需单独装) |
| Python | 3.14.7(仅作可选的模型转换工具) |
| curl / tar | Windows 自带 |

**git 已解决(2026-08-20)。** 此前 git 不在 PATH,每条 nimble 命令都要手工注入
`C:\Program Files\Git\cmd`。用户安装 git 后已进入**系统级** PATH,实测
`nimble test` 不再需要任何注入即可跑出 **OK=527 FAILED=0**,git 相关报错 0 条。

（历史记录：注入写法为 `$env:PATH = "C:\Program Files\Git\cmd;" + $env:PATH`，
现已不需要。）

### OpenVINO Runtime

| 项 | 值 |
| --- | --- |
| 版本 | `2026.3.0-22451-8a17657b995-releases/2026/3` |
| DLL 数量 | 25 个,共 205 MB |
| 来源 | **OpenVINO 官方 archive**(`openvino_genai_windows_2026.3.0.0_x86_64.zip`,220.2 MB) |
| 安装位置 | `D:\nim\Isvik\runtime\openvino\` |

**来源已从 pip 上游改为官方 archive(2026-08-20)。** 详见下方「DLL 来源的更换」。

系统**没有**独立安装的 OpenVINO。Adobe 应用捆绑了私有副本(2025.4.1),**已决定不使用** —— 私有部署路径、版本与裁剪程度都不受控,许可与可复现性都不成立。

### 设备清单(`ov_core_get_available_devices` 实测)

| 设备 | FULL_DEVICE_NAME | ARCHITECTURE |
| --- | --- | --- |
| `CPU` | Intel(R) Core(TM) Ultra 7 270K Plus | `intel64` |
| `GPU.0` | Intel(R) Graphics (iGPU) | `GPU: vendor=0x8086 arch=v12.70.4` |
| `GPU.1` | **NVIDIA GeForce RTX 5080 (dGPU)** | `GPU: vendor=0x10de arch=v12.0.0` |
| `NPU` | Intel(R) AI Boost | `3720` |

**关键发现:`GPU` 不等于 `Intel GPU`。** OpenVINO 把 NVIDIA RTX 5080 也枚举为 `GPU.1`(`vendor=0x10de` 即 NVIDIA)。

这对 **Task 10(Device Manager + AUTO Policy)** 是硬约束:

- AUTO 策略**不能**把 `GPU` 当作单一设备处理,必须按 `GPU.N` 逐个枚举并读 `DEVICE_ARCHITECTURE` 判断 vendor。
- Isvik 的目标是 Intel CPU/GPU/NPU。若 AUTO 盲选 `GPU` 而落到 `GPU.1`,实际是在 NVIDIA 卡上走 OpenVINO 的通用 GPU 路径 —— 支持度和性能均未验证,且会让「面向 Intel 硬件优化」这个前提失效。
- 设备选择的结果**必须显式上报实际使用的设备全名**,不能只报 `GPU`。用户看到 `GPU` 无法知道跑在哪张卡上。

**未验证事项**:`NPU` 报告的 architecture 是 `3720`。此处如实记录探测值,不推断其与具体 NPU 代次的对应关系。GPU.1(NVIDIA)上的实际编译与推理**完全未测试**。

### 驱动状态(实测版本号)

| 设备 | 驱动版本 | 要求 | 结论 |
| --- | --- | --- | --- |
| Intel(R) AI Boost(NPU) | **32.0.100.4841** | OpenVINO 文档要求 ≥ 32.0.100.3104 | 已满足,无需升级 |
| Intel(R) Graphics | 32.0.101.8864 | 无明确要求 | 可用 |
| NVIDIA GeForce RTX 5080 | 32.0.16.1088 | 不在目标范围 | 见上方 GPU.1 说明 |

NPU 与 GPU 驱动可用的独立证据:OpenVINO 能枚举到这两个设备并成功读取其
`FULL_DEVICE_NAME`。

内存 47.4 GB、D 盘剩余 1862 GB。(OpenVINO 文档提到 7B 以上模型处理超过
1024 token 的提示可能需要 16 GB 以上内存,本机充裕。)

### 网络可达性(决定依赖能否获取)

这一项以前没测过,而它直接决定了「要装什么」能不能装上。

| 站点 | 实测 | 影响 |
| --- | --- | --- |
| `storage.openvinotoolkit.org` | **HTTP 200** | OpenVINO 官方 archive 可下(已用) |
| `github.com` | HTTP 200 | 可用 |
| `www.modelscope.cn` | HTTP 302 | 可下模型,但只有原始格式 |
| `pypi.tuna.tsinghua.edu.cn` | HTTP 200 | pip 可用,需显式指定镜像 |
| `huggingface.co` | **HTTP 000** | **预转换的 OpenVINO IR 拿不到** |
| `hf-mirror.com` | **HTTP 000** | 常见镜像同样不可用 |
| `pypi.org` | HTTP 000 | 必须走镜像 |

`000` 是 TCP/TLS 连接层面失败,不是 404。

**这条发现推翻了原本的模型获取方案。** OpenVINO 官方把预转换好的 IR 模型
只发布在 HuggingFace 的 `OpenVINO/` 组织下,那些仓库的构成非常理想(LLM 本体 +
tokenizer IR + detokenizer IR 一应俱全),但拿不到。可选路径与取舍已写入
`docs/installation.md` 第四节。

**由此得到的一条脚本设计教训**:`scripts/fetch-deps.ps1` 最初会自动探测 HF 并
在失败后继续尝试下载,结果是用户对着十几条 curl 超时干等,而真正的原因(整个站点
不可达)被埋在噪声里。改为**默认不尝试**,需要显式加 `-TryHuggingFace` 才去探测,
默认情况直接打印可选路径。**在已知不可达的站点上重试没有信息价值,只有等待成本。**

另一个坑:脚本全局设了 `$ErrorActionPreference = 'Stop'`,而 curl 把进度条和
连接诊断写到 stderr,PowerShell 会把原生命令的 stderr 当成 `ErrorRecord` 并触发
终止 —— 于是「探测到不可达」这件完全正常的事会把整个脚本打断。修法是在调用原生
命令的函数内部局部设 `'Continue'`,靠 `$LASTEXITCODE` 判断成败。

还有一个环境坑:**PowerShell 5.1 按 ANSI(GBK)读取无 BOM 的 `.ps1` 文件**,
中文注释会变乱码并破坏引号配对,导致大量虚假语法错误(实测报 9 处错误,Token
只解析出 507 个)。加 UTF-8 BOM 后 0 错误、1828 个 Token。含中文的 PowerShell
脚本必须带 BOM。

### PATH 配置(本次完成)

`D:\nim\Isvik\runtime\openvino` 已写入**用户级** PATH(注册表 `HKCU\Environment`),不改系统级。

- 写入前检查是否已存在,避免重复追加
- 写入后条目数 8 → 9,PATH 总长 276 字符(远低于任何截断风险)
- 使用 `[Environment]::SetEnvironmentVariable(..., "User")` 而非 `setx` —— 后者有 1024 字符截断行为
- 原值备份至 `runtime/user-path-backup-<时间戳>.txt`

**关于备份位置**:最初备份写在 `build/` 下,随后发现 `nimble clean` 会删除整个
`build/` 目录 —— 一份「用来恢复系统环境变量」的备份不能放在会被构建脚本清空的地方。
已移到 `runtime/`(同样 gitignore,但不在 clean 的清理列表中)。

**撤销方法**(原始值已内联,不依赖任何文件是否还存在):

```powershell
# 方式一:只移除新增的这一项(推荐,不影响其它条目)
$p = [Environment]::GetEnvironmentVariable("PATH","User")
$n = ($p.Split(';') | Where-Object { $_ -ne "D:\nim\Isvik\runtime\openvino" }) -join ';'
[Environment]::SetEnvironmentVariable("PATH", $n, "User")

# 方式二:整体恢复为写入前的原始值
[Environment]::SetEnvironmentVariable("PATH", "C:\Users\WANG\AppData\Local\Microsoft\WindowsApps;C:\Users\WANG\.dotnet\tools;C:\Users\WANG\AppData\Local\Python\bin;C:\Users\WANG\go\bin;C:\ybc;C:\nim-2.2.10\bin;C:\Users\WANG\AppData\Local\Kiro-Cli\;C:\Users\WANG\AppData\Local\Programs\Kiro\bin", "User")
```

已存在的终端进程不会感知该变更(Windows 的进程环境在创建时快照),需新开终端。

**决策:DLL 放 `runtime/openvino/` 并 gitignore。**
拒绝:放仓库根(污染源码目录,且 194.9 MB 混在源码里)、放 exe 同目录(测试 exe 在 `build/tests/` 下,找不到)。用 PATH 统一解决,所有产物位置都能加载。

### DLL 来源的更换(2026-08-20)

**决策:用 OpenVINO GenAI 的 archive 包,而不是普通的 OpenVINO Runtime archive。**

理由:官方文档明确说明 GenAI archive「包含 OpenVINO Runtime 以及 Tokenizers」。
一个包同时解决两个独立的问题:

1. 把 DLL 来源换成官方 archive,不再是从 pip 包间接得到 —— 消除了「获取 DLL
   这一步隐含 Python 依赖」这个问题(见第六节 6.3 第 12 条)。
2. 补上 `openvino_tokenizers.dll`。**这是 tokenizer 方案的关键**:OpenVINO
   官方的模型仓库里带 `openvino_tokenizer.xml` / `openvino_detokenizer.xml`,
   即分词器本身就是 IR,可以用推理来做分词,不必在 Nim 里手写 BPE。但加载这两个
   IR 需要该 DLL 提供的自定义算子。

**版本一致性(这是敢换的前提)**:archive 的 build 号 `2026.3.0.22451` 与
替换前实测的 `2026.3.0-22451` **完全相同**。也就是说这不是升级,只是换了同一个
build 的获取渠道,不引起版本漂移。

替换后复验,与替换前完全一致:

| 测试 | 替换前(pip 上游) | 替换后(官方 archive) |
| --- | --- | --- |
| Resonance | OK=21 FAILED=0 SKIPPED=2 | **OK=21 FAILED=0 SKIPPED=2** |
| Isvik 全量 | OK=527 FAILED=0 SKIPPED=1 | **OK=527 FAILED=0 SKIPPED=1 WARNINGS=0** |

12 个 DLL 的体积发生变化(同 build 但打包不同),新增 3 个:
`openvino_tokenizers.dll` / `openvino_genai.dll` / `openvino_genai_c.dll`。

**踩到的坑:TBB 把调试版 DLL 放在 Release 目录里。** 第一次执行时混进了
`tbb12_debug.dll`、`tbbbind_2_5_debug.dll`、`tbbmalloc_debug.dll`、
`tbbmalloc_proxy_debug.dll` 四个文件 —— 因为脚本只排除了 `\Debug\` **目录**,
而这些是文件名带 `_debug` 后缀却位于 Release 目录下的。已改为目录与文件名双重
过滤。教训:按目录过滤调试产物是不够的,发布包不保证遵守目录约定。

**脚本设计:不硬编码包内目录结构,按文件名搜索 DLL。** OpenVINO 包的内部布局
在版本间变过,硬编码 `runtime\bin\intel64\Release` 这类路径迟早失效。

---

## 六、从 NimVoice 继承的经验

`C:\nim\NimVoice` 是同一作者在同一台机器上跑通的 Nim + OpenVINO + NPU 项目(TTS 方向)。它的 `DEVLOG.md` 记录了大量已付出代价换来的结论。下表按**对 Isvik 的约束力**分级,不是原文摘抄。

> 说明:以下每条的现象与根因来自 NimVoice 的开发记录;「对 Isvik 的影响」一列是本项目的判断。NimVoice 的性能数字是其 TTS 流水线的实测值,**不是 Isvik 的性能数据**,Isvik 自己的 Benchmark 要到 Task 18 才产生。

### 6.1 硬约束级(直接改变 Isvik 的设计)

#### 1. NPU 驱动不允许在从 `.blob` 加载的模型上启用 `PERF_COUNT`

- **现象**:blob 缓存命中后,NPU 路径的 per-layer 计数全部消失。
- **根因**:`.blob` 序列化产物不含运行期 property,`ov_core_import_model` 之后必须重新 `set_property`;但本机 NPU 驱动对 import 后的模型执行 `set_property("PERF_COUNT","YES")` 直接返回 `-1 (GENERAL_ERROR)`。这是驱动行为,不是 bug。
- **对 Isvik 的影响**:**Task 16(Compiled Cache)与 Task 18(真实 Benchmark)在 NPU 上功能互斥。** 这必须在设计阶段就处理,不能等到 Task 18 才发现。要求:
  - Benchmark 若需要 per-layer 数据,必须能**绕过 blob 缓存**重新编译。
  - 缓存命中且 profiling 被驱动拒绝时,**必须显式上报原因**(如「profiling hint 在 import 后被驱动拒绝」),不得静默返回空数据或零值。
  - 静默给空数据 = 伪造 Benchmark,直接违反硬约束。

#### 2. `property_args_size` 是「变长参数总数」,不是「property 对数」

- **现象**:`ov_core_compile_model` 返回 `-14 (INVALID_C_PARAM)`。
- **根因**:OpenVINO 内部有 `property_args_size % 2 != 0` 的偶数校验。一个 `<key, value>` 对算 **2** 个参数,传 `1` 直接被挡。
- **诊断方法值得记**:NimVoice 当时怀疑是跨语言 ABI 问题,于是**写了一个最小 Python ctypes 复现**来剥离 ABI 因素。Python 端返回**完全相同的 `-14`**,直接证明问题不在 ABI,然后去读 OpenVINO 源码找到了那句 guard。—— 用一个不同的语言/运行时复现同一个错误,是区分「我的绑定写错了」与「我对 API 的理解错了」的最快办法。
- **Isvik 状态**:已在 Resonance 落地。`perf_count_wrapper.c` 的注释中明确写了这条语义。

#### 3. MSVC 与 MinGW 的变长参数 ABI 不兼容

- **现象**:链接期 `undefined reference: __imp_ov_core_compile_model`;即使绕过链接,运行期参数错位。
- **根因**:
  - 链接:OpenVINO 的 Windows 发布包不提供 MinGW 用的 `openvino_c.lib`。
  - ABI:`openvino_c.dll` 由 MSVC 编译,变长参数走 MSVC ABI(前两个走寄存器);TDM-GCC 编译的 Nim 主体走 System V AMD64 ABI(变长参数全部走栈)。直接跨 ABI 调用栈帧错位。
- **解法**:一个轻量 C wrapper,函数指针类型用 `__attribute__((ms_abi))` 标注让 GCC 生成 MSVC 风格调用,内部用 `LoadLibraryA` + `GetProcAddress` 解析符号绕开 import library 缺失,对外只暴露**非变长**的稳定签名。
- **Isvik 状态**:已在 `Resonance/src/resonance/perf_count_wrapper.c` 落地,且比 NimVoice 更通用(支持最多 8 个 property 对,NimVoice 只硬编码了 `PERF_COUNT=YES` 一对)。该 wrapper 由 Nim 的 `{.compile.}` 编译进本体,**不引入新 DLL**,不违反 100% Nim 分发约束。

#### 4. NPU 不支持动态维度与复杂自回归控制流

- **现象**:NPU 编译器要求输入 Tensor 维度编译期完全静态;含动态轴或动态控制流的图会编译失败或回退 CPU。
- **NimVoice 的应对**:把流水线拆成「CPU 跑动态部分 + NPU 跑固定 shape 部分」的异构结构,NPU 侧固定为 `[1,128,80]`,超长输入按 128 帧分块,不足的补齐后推理再精准截断输出。
- **对 Isvik 的影响**:
  - **Task 13(Model Manifest)必须能表达「该模型在某设备上要求静态 shape」以及具体的 shape 约束**,否则 Task 15 无法在编译前判断可行性。
  - **Task 10 的 AUTO 策略不能把 NPU 当成「和 CPU 等价但更快」的设备。** 模型是否能上 NPU 是模型属性,不是运行时偏好。
  - LLM 的自回归解码天然是动态的,这意味着 NPU 上跑 LLM 的可行性**需要独立验证**,不能假定。当前**完全未验证**。

#### 5. 退出码约定:0 成功 / 1 系统错误 / 2 输入错误

- **理由**:让脚本与 CI 能区分「用户传错了参数」和「运行时炸了」。这两类需要完全不同的处理。
- **对 Isvik 的影响**:CLI 应遵循同一约定。Isvik 已有 17 个错误码,需要一张 `IsvikErrorCode → 退出码` 的映射表,在 Task 11(CLI 框架)落地。

#### 6. 「看起来成功但产物是垃圾」比直接报错糟糕得多

- **现象**:NimVoice 输入超长文本时,SpeechT5 的静态位置编码静默截断,生成一个 30 秒静音 wav。用户以为成功了。
- **应对**:入口处显式校验并拒绝,错误消息里说明**为什么**有这个限制以及**该怎么做**(而不是只说「输入无效」)。
- **对 Isvik 的影响**:这与 Task 4 已定的「配置非法则报错、不静默回落」是同一原则。需要贯彻到:模型 shape 不匹配、上下文长度超限、量化类型不支持等所有路径。**能静默降级的地方都要问一句:用户会不会以为它成功了?**

#### 7. Preflight 检查:启动时一次性校验全部必需资源

- **现象**:从错误的工作目录启动时,OpenVINO 抛出底层 `ov_core_read_model` 状态码,信息晦涩。
- **应对**:入口第一行校验所有必需文件,缺失则直接报「少了哪个文件」。
- **对 Isvik 的影响**:直接对应 **Task 12(`isvik doctor`)**。且 Isvik 的场景更复杂 —— 除了模型文件,还要检查 OpenVINO 是否可加载、各设备是否可用、缓存目录是否可写。`doctor` 的输出必须区分「缺失」「存在但不可用」「可用」三态。

### 6.2 参考级(有价值但非约束)

#### 8. blob 编译缓存的收益量级

NimVoice 实测:HiFi-GAN 在 NPU 首次编译约 **13.5 秒**,blob 缓存命中后约 **850 ms**(约 16×)。NPU 驱动侧没有内建缓存,每次冷启都要重编。

对 Isvik 的意义:这个量级足以论证 **Task 16(Compiled Cache)不是优化项而是可用性项** —— 13.5 秒的启动等待对交互式使用是不可接受的。但 Isvik 的模型规模与 HiFi-GAN 差异很大,**具体数字不可直接引用**,Isvik 需自己实测。

#### 9. NPU 使用率的计算与 clamp

NimVoice 的做法:对所有 `status == EXECUTED` 的层求 `Σreal_time`,再算 `Σreal_time / wall_clock × 100%`,并 **clamp 到 [0,100]**。

需要 clamp 的原因:NPU 驱动上报的是每个 kernel 的硬件执行时间,跨多个分块累加时总和天然会超过 wall clock,不 clamp 会出现「1300%」这种没有物理意义的数字。

对 Isvik 的影响:**Task 18 定义指标时必须先把语义写清楚** —— 「NPU 使用率」到底是 `Σ设备时间/墙钟时间` 还是别的东西。一个需要 clamp 才能落在合理区间的指标,说明其定义与直觉不符,文档里必须写明,否则读者会误读。

#### 10. 性能瓶颈往往不在你加速的那部分

NimVoice 的 per-phase 计时揭示:一次约 1210 ms 的推理里,**自回归循环占 1110 ms(92%)**,而费了大力气搬到 NPU 的 Vocoder 只占 69 ms。

对 Isvik 的影响:**Task 18 必须做分阶段计时,不能只报总耗时。** 只有总数时,优化方向只能靠猜。

#### 11. 推理热路径的 FFI 分配消除

NimVoice 把循环内的 `newTensor` 改为循环外预分配 + 循环内 `setShape` / 就地改 host buffer,把 `ov_tensor_create_from_host_ptr` 的调用次数从每步一次降到全程一次。

对 Isvik 的影响:该模式在 LLM 的逐 token 解码上同样适用(每个 token 一次 FFI 分配是很大的浪费)。Resonance 已具备 `ov_tensor_set_shape` 支持。留到 Task 15/17 视实测结果决定是否需要。

### 6.3 反面教材(Isvik 明确不这么做)

#### 12. 不用 pip 包作为 DLL 来源

NimVoice 的 OpenVINO DLL 来自 `.venv` 里的 `openvino` pip 包。这在**构建/部署期引入了 Python 依赖** —— 尽管运行期确实没有 Python,但「获取 DLL」这一步需要一个 Python 环境。

Isvik 的做法:应使用 OpenVINO 官方发布的 **archive 包**作为正式来源,并在文档中给出确切的版本与下载地址,使任何人不装 Python 也能复现构建。

**当前状态如实说明**:本次为了让 Task 8 能立即做真机验证,DLL 是从 NimVoice 的 `bin` 目录复制的(其上游即 pip 包)。这是**临时措施**,尚未改为 archive 来源。已记入下方未完成事项。

#### 13. GUI 技术栈的边界

NimVoice 先做了纯 Win32 GUI(零第三方 DLL),后为满足现代 UI 与双语需求转向 Electron + React + Tailwind,并通过 `child_process` 调用 Nim 二进制,保持推理核心纯净。

对 Isvik 的意义:这个「展示层可以妥协,推理核心不可妥协」的边界划法值得参考。但 Isvik 当前 Task 序列中 GUI 不在 Milestone 1/2 范围内,**不做技术选型决定**。

---

## 七、踩过的坑速查

### Nim / 标准库

1. **`for i, x in someJsonArray` 能编译但运行时必崩。** `pairs()` 只支持 `JObject`。数组必须 `for i in 0 ..< arr.len`。
2. **set 字面量 `{...}` 内不能放 `##` 文档注释。**
3. **单行 `if c: proc(): T = ... else: x` 非法**,报 "nestable statement requires indentation"。必须用多行 if/else 块赋值。
4. **`seq` 没有 slice 版 `delete`**(只有 `string` 有)。用 `s = s[a .. ^1]`。
5. `Table` 的 `.len` 需要 `import std/tables`。
6. **`unittest` 的 `TestStatus` 也有 `OK`**,与 OpenVINO 状态码同名 → 必须写 `OvStatus.OK`。
7. **`OvStatus` 的值是递减的,构成 holey enum,不能 `for x in OvStatus` 迭代。**
8. `e.name` 是 `cstring`,取字符串需 `$e.name`。
9. **Nim 的 method 分派要求参与继承的类型在模块级可见** —— 不能把测试用的子类定义在 `test` 块内。
10. **nimble 强制 `version` 为字符串字面量**,不接受常量。
11. **`{.dynlib.}` 加载失败会走 `nimLoadLibraryError` 直接 `quit(1)`,无法 try/except。** 这是 Task 8 改为手动加载的直接原因。
12. 手动加载后,释放类函数需标 `{.raises: [].}`(否则 `=destroy` 报 5 个 Effect 警告);函数指针类型需 `{.cdecl, raises: [].}`。
13. **proc 必须定义在调用它的 method 之前。**

### 测试自身的 bug

**「不硬编码用户名」这条断言最初是扫描 `paths.nim` 全文,结果因文档注释里引用了禁令原文(「禁止硬编码 `C:\Users\xxx`」)而误报失败。**

修正:先去掉每行 `#` 之后的内容再检查。

教训:**检查代码约束的测试只能扫描代码,不能扫描注释。** 这与 Task 6 架构扫描器必须解析 import 语句而非搜文本是同一个坑的两次出现。

### 本地终端环境

本项目的开发终端有几个已确认的不可靠行为,记录以免重复排查:

- **stdout 不可靠**:回显逐字符重复,exit code 恒为 1,管道内容常被吞。
- **可靠做法**:`命令 2>&1 | Out-File <绝对路径> -Encoding utf8`,再读文件。
- **`cwd` 参数不可靠**:命令内需显式 `Set-Location`,日志一律用绝对路径。
- **统计 `[OK]` 必须用 `-AllMatches`**:`(Select-String -Path X -Pattern "\[OK\]" -AllMatches).Matches.Count`。不带该参数是按行计数,而日志中多个 `[OK]` 常挤在同一行,会严重低估。
- **判断编译警告搜 `"Warning:"`,不要搜 `"Error"`** —— 后者会匹配中文行里的 `IsvikError` 字样。
- **命令执行工具会在长命令跑完之前返回。** 这条代价最大:它让「输出只有前几行」
  这个纯观测假象看起来像一个可复现的程序缺陷,并连续推出五个错误结论
  (详见第九点七节)。**凡是遇到「输出不完整」,先证明进程已经结束。**
  可靠做法是用可轮询的后台进程接口,并让脚本在最后自己写一个结束标记
  (例如 `echo ===== ALL DONE =====`),读日志前先确认那个标记出现。
- **`echo RC=%ERRORLEVEL%> f` 在 cmd 里不是你想的意思。** `0>` 被解析成
  **fd 0 重定向**(stdin),文件不会被创建。必须写 `%ERRORLEVEL% > f`(留空格)。
- **含中文的 `.cmd` 批处理会被 cmd 按 GBK 读**,UTF-8 的中文会破坏命令行解析,
  报出「'text' 不是内部或外部命令」这类与真实内容毫无关系的错误。
  批处理里只放 ASCII,中文内容放到单独的 UTF-8 文件里用 `type ... |` 喂进去。
- **PowerShell 对原生程序的 `1>` 重定向会按自己的编码写文件**,UTF-8 输出会
  变成乱码;`cmd /c "... > f 2>&1"` 才是原样字节。

---

## 八、当前状态

### 测试

| 项目 | 结果 |
| --- | --- |
| Isvik + Resonance 合计(全条件就绪) | **OK=605 FAILED=0 SKIPPED=2 WARNINGS=0 ERRORS=0** |
| Isvik 主项目 | 13 个测试文件,退出码 0 |
| Resonance(无 DLL) | OK=18 FAILED=0 SKIPPED=5 |
| Resonance(有 DLL,无模型) | OK=22 FAILED=0 SKIPPED=7 |
| Resonance(有 DLL + 模型) | **OK=27 FAILED=0 SKIPPED=2** |
| tarchitecture 单独 | **OK=44 FAILED=0 SKIPPED=0**(Task 9 后那条自动生效) |
| tovbackend 单独(全条件) | **OK=45 FAILED=0 SKIPPED=0** |

剩余的 2 个 SKIPPED 全部来自 Resonance 的「未加载 OpenVINO 时的行为」用例 ——
在 DLL 可用的环境下按定义无法执行,是正确的 skip 而非遗漏。

Resonance 的三档差值就是「依赖外部条件的用例」。给不同条件时 SKIP 而非 FAILED,
使 CI 能在没有 Intel 硬件、没有模型的机器上跑,同时不把「没测」伪装成「测过」。

启用需要模型的那一档:

```powershell
$env:RESONANCE_TEST_MODEL_XML = "D:\Model\gemma-4-E2B-it-int4-ov\openvino_text_embeddings_model.xml"
```

Resonance 两组数字的差值就是「真正需要 `openvino_c.dll` 的用例」。在无 DLL 环境下它们 SKIPPED 而非 FAILED,这是刻意设计:CI 可以在没有 Intel 硬件的机器上跑,同时不会把「没测」伪装成「测过了」。

有 DLL 后转为 OK 的用例:取得 OpenVINO Runtime 版本、创建 Core 并枚举设备、取得 CPU 的 `FULL_DEVICE_NAME`、查询不支持属性时 `tryGetProperty` 返回回落值、查询不支持属性时 `getProperty` 抛异常。

剩余 2 个 SKIPPED 是「未加载时的行为」用例,在 DLL 可用的环境下按定义无法执行 —— 这是正确的 skip,不是遗漏。

### 验证命令

```powershell
# Isvik 全量测试
# 加上模型环境变量才会跑「端到端推理」那一档,否则该 suite 全部 SKIP
Set-Location D:\nim\Isvik
$env:ISVIK_TEST_MODEL_XML = "D:\Model\gemma-4-E2B-it-int4-ov\openvino_text_embeddings_model.xml"
nimble test

# Resonance 绑定测试(PATH 已配置,无需再注入 openvino 路径)
# 加上模型环境变量才会跑「多属性编译」那一档,否则该 suite 全部 SKIP
$env:RESONANCE_TEST_MODEL_XML = "D:\Model\gemma-4-E2B-it-int4-ov\openvino_text_embeddings_model.xml"
Set-Location D:\nim\Isvik\Resonance
nim c -r --hints:off --path:src --nimcache:../build/nimcache/res -o:../build/tests/tbindings.exe tests/tbindings.nim
```

---

## 九、未完成事项

如实记录,不掩盖。

### Task 8 收尾(已全部完成,2026-08-20)

1. ~~**`c_api.nim` 的版本标注与实装不符**~~ —— **已完成**。
   注释、跨版本表格、两个 suite 名均改为 **2026.3**,枚举主名改为 `DYNAMIC = 0`。
   为不破坏现有代码,同时提供两个常量别名:`OvElementTypeDynamic`(原有,已被
   `core.nim` 导出)与新增的 `OvElementTypeUndefined`(给按旧名写的代码)。
   跨版本表格现在是三列(2023.3 / 2025.4 / 2026.3),明确标出 `UNDEFINED` 在
   2026.3 被**移除**、`DYNAMIC` 成为值 0 的正式名字。
   顺带修掉了 5 处 `鈥?` 乱码(原文是破折号,曾被按 GBK 误读后写回)。

   **新增一条防护**:「取得 OpenVINO Runtime 版本」这个用例现在会检查
   `buildNumber` 是否以 `2026.` 开头,不是则输出显式警告 —— 因为那些逐值断言的
   前提就是「运行时是 2026.x」。换了版本却静默通过,等于把断言变成了装饰。

2. ~~**`ov_get_error_info` 的所有权注释缺失**~~ —— **已完成**。
   已补注释说明该指针在进程生命周期内有效、**禁止传给 `ov_free`**,并特别指出
   这与 `ov_core_get_property`(其出参*必须* `ov_free`)的约定相反 —— 正是这种
   「同一个 API 家族里两种相反约定」最容易让人顺手写错。

3. ~~**多属性编译路径未做真机验证**~~ —— **已完成,并固化为回归测试**。

   实测结果(设备 CPU,模型为 Gemma 4 E2B 的 `text_embeddings` 子 IR,384 MB):

   | 属性对数 | 结果 | 编译耗时 |
   | ---: | --- | ---: |
   | 0(基线) | 通过 | 30 ms |
   | 1 | 通过 | 18 ms |
   | 2 | 通过 | 18 ms |
   | **4** | **通过** | 18 ms |
   | 9(超上限 8) | 如期抛 `OpenVinoError` | — |

   这证明 shim 里 `property_args_size = 2 * pair_count` 的算法在多于一对时正确 ——
   正是 NimVoice 当年栽在 `-14 INVALID_C_PARAM` 的那个点(见第六节 6.1 第 2 条)。

   **决策:不做成一次性验证脚本,而是加进 `tbindings.nim` 作为正式 suite。**
   模型路径通过环境变量 `RESONANCE_TEST_MODEL_XML` 提供(可选
   `RESONANCE_TEST_MODEL_BIN`,默认取同名 `.bin`),未提供时整个 suite SKIP 并
   在输出里说明启用方式。
   拒绝:硬编码 `D:\Model\...` —— 那会让这个测试在别的机器上要么永远失败、
   要么永远跳过,两种都没有价值。
   同时验证了两个方向:给模型时 6 个用例全 OK;不给模型时 5 个 SKIPPED 而非
   FAILED（「没测」不会显示成「测过」）。

   另外每个用例在编译成功后还会 `createInferRequest()`。理由:编译返回成功不等于
   产物可用,只断言「没抛异常」会漏掉「编译出一个不能用的 CompiledModel」这类问题。

4. ~~**README 的硬件与运行时验证状态表需更新**~~ —— **已完成**。

### 已完成(原为未完成事项)

5. ~~**DLL 来源应改为 OpenVINO 官方 archive 包**~~ —— **已完成(2026-08-20)**。
   改用 GenAI archive,同时补上了 `openvino_tokenizers.dll`。见第五节「DLL 来源的更换」。

### 新增的未完成事项

10. **Gemma 4 E2B 已下载到本机,但缺一个文件。**

    位置:`D:\Model\gemma-4-E2B-it-int4-ov`(用户选择,**不在仓库内**)。
    这个位置比 `runtime/models/` 更合理 —— 模型不该在代码仓库里,即使被
    gitignore。Task 14 做 Model Storage 时用 `settings.json` 的 `model_directory`
    字段指向它即可(该字段 Task 4 已实现,空串表示用 `<ISVIK_HOME>/models`)。

    校验结果(`scripts/verify-model.ps1`):20 个文件通过、合计 1.87 GB,
    **缺 `openvino_text_embeddings_per_layer_model.bin`(2,349,334,608 字节)**。
    其余 19 个必需文件的字节数全部精确匹配。

    **这次缺失正好印证了校验脚本存在的理由**:缺的是最大的单个文件,而它的
    `.xml` 在场,目录看起来是完整的 —— 不校验就要等到加载模型时才发现。

    该文件是 Per-Layer Embeddings 的权重本体。顺带一个值得记的事实:它
    **2.19 GB,比语言模型主体的 1.28 GB 还大**,占整个模型一半以上。这说明 PLE
    不是可以忽略的旁路,Task 15 的推理编排必须正确用上它。

    已用该目录下已到位的 `text_embeddings` 子 IR 完成了 Task 8 的多属性编译
    验证(见上方 Task 8 收尾第 3 项)—— 那项验证不需要缺失的那个文件。

11. **Gemma 4 的四项额外工作**(用户已确认偏好使用 Gemma 4)。
    官方 IR 存在、许可为 Apache-2.0(Gemma 系列首次,非 gated),
    推荐变体 `OpenVINO/gemma-4-E2B-it-int4-ov`(4.06 GB)。
    详见 `docs/installation.md` 第 4.1 节:

    - **由 5 个 IR 组成**(language_model / text_embeddings /
      text_embeddings_per_layer / vision_embeddings / tokenizer),需自行编排。
      Per-Layer Embeddings 要求每个解码层注入额外的低维条件信号。这套编排在
      GenAI 的 `VLMPipeline` 里现成,Isvik 必须自己写,且**编排错了不报错、
      只输出垃圾**。
    - **chat template 无法被标准模板引擎解析**(已知问题 ID 191107 —— 连
      OpenVINO GenAI 自带的 Minja 都解析不了,因为它不支持相邻字面量字符串
      拼接)。实测该模板 18.5 KB Jinja,含递归 macro、namespace 状态机、
      tool calling 自定义格式、thinking channel。Nim 里无 Jinja 引擎,
      只能用固定 prompt 拼接或退回旧模板,**且必须如实声明支持是有限的**。
    - **INT4/INT8 版本必须显式设 KV cache group size = 64**(已知问题
      ID 186412),漏掉不报错、只掉精度 —— 又一个静默失败路径。
    - **NPU 支持无官方声明**,发布说明中 Gemma 4 只涉及 CPU/GPU 与 SDPA 后端;
      31B 与 26B-A4B 明确标为「仅 GPU」。

    **建议(已提出,等确认)**:先用单 IR 的 `Qwen2.5-1.5B`(886 MB)把
    「读模型 → 编译 → 分词 → 自回归解码 → 反分词」验证到已知good,再换 Gemma 4。
    否则输出不对时无法区分是编排写错、IR 数据流接错、模板没渲染对,还是撞上了
    已知精度问题。用户尚未就此答复,当前按「直接用 Gemma 4」准备。

    **顺带记一个容易误判的事实**:`E2B` 的 E 是 effective(等效)。它采用
    Per-Layer Embeddings 架构,实际权重远大于名字暗示的规模 —— ModelScope 上
    `google/gemma-4-E2B-it` 的原始 `model.safetensors` 实测 **9.54 GB**,
    量化后 IR 4.06 GB。内存与编译时间要按 4 GB 级估算,不能按「2B 小模型」估算。

11. **NPU 上跑 LLM 的静态 shape 处理没有着落。** NPU 要求静态 shape,自回归解码
    需要处理提示与响应的长度上限、长提示分块预填充、KV cache 布局。这些在 OpenVINO
    GenAI 的 `LLMPipeline` 里是现成的,而 Isvik 要 100% Nim 自己实现推理编排就得
    自己做 —— **规范对此没有任何规定**,工作量不小。
    GenAI archive 里带了 `openvino_genai_c.dll`(C API),理论上可以绑定它,但那会
    让 Isvik 的推理编排依赖 GenAI 而非仅依赖 OpenVINO Runtime,是个需要单独讨论的
    架构决定,**目前没有做这个决定**。
    结论:先在 CPU/GPU 上打通再考虑 NPU 是更稳的顺序。

12. **Python 3.14.7 是否能装上模型转换工具链未验证。** 若走 ModelScope 自行转换的
    路径,官方给的组合是 `nncf==2.18.0 / onnx==1.18.0 / optimum-intel==1.25.2 /
    transformers==5.0.0`,这些包(尤其其依赖的 torch)在 Python 3.14 上是否有可用
    wheel **没有实测**。装不上则需额外准备一个 3.12 环境专门做转换。

### 待决策(已提出,等用户答复)

6. **Isvik 的分发策略**,三个选项:
   - **[1] 只依赖系统安装的 OpenVINO** —— 分发体积最小,但用户需自行安装,`doctor` 承担全部诊断责任。
   - **[2] 捆绑 DLL** —— 开箱可用,但需处理 Apache-2.0 的再分发义务(NOTICE 文件、许可声明),且分发体积增加约 195 MB。
   - **[3] 两者都支持,`doctor` 报告实际加载的是哪一份** —— 灵活但需要明确的搜索优先级,且「用户以为在用 A 实际在用 B」是很难排查的问题类别。

### 已识别但未处理

7. **`saveSettings` 非完全原子**(Windows `moveFile` 语义所致),真正原子需 `ReplaceFileW`。已在代码注释中说明。

8. **`EventBus` 当前单线程无锁**,已在注释标注。§70 引入 worker 时必须显式加同步。

9. **`GPU.1`(NVIDIA RTX 5080)上的编译与推理完全未测试。** Task 10 已将它明确
    记录为「已检测但因 vendor=0x10de 被 Intel 策略排除」,这不等于对 NVIDIA
    编译/推理能力做了结论。

---

### Task 10:Device Manager + AUTO Policy

新增:

```text
src/isvik/core/device_manager.nim
    DeviceType / DeviceId / DeviceInfo
    Device Manager 快照
    显式设备选择与 AUTO Policy

tests/core/tdevice_manager.nim
    12 个纯逻辑测试,不依赖 OpenVINO DLL
```

#### 决策:Backend 只报告原始设备,Device Manager 负责语义选择

`BackendDeviceInfo` 的 `rawName`、`fullName` 和 `properties` 保持原始契约。
Device Manager 接收 Runtime 已发现的快照,不直接调用具体 Backend,也不把
OpenVINO 类型带入 Core。这样 `CPU`、`GPU.N`、`NPU` 的语义解析和策略只有一个
入口,新增 Backend 只需提供同一组可选设备属性。

#### 决策:GPU.N 必须逐项判断 vendor

OpenVINO 的 `GPU.0` 与 `GPU.1` 不是同一设备。Device Manager 从中立属性键
`DEVICE_ARCHITECTURE`(或显式 `DEVICE_VENDOR`)提取 vendor id:

- `0x8086` → Intel GPU,可进入当前 Intel 目标策略。
- 其它 vendor,例如本机 `GPU.1` 的 `0x10de` → 已检测但被策略排除。
- 缺少 vendor 证据 → 不猜测,不进入 Intel GPU 候选。

`DeviceInfo.available` 与 `policyEligible` 分开表示「Backend 检测到」和「当前
策略允许选择」。被排除的 GPU 不会被伪装成缺失设备;排除原因会进入 metadata、
选择尝试和错误 detail。`fullName` 始终沿用 Backend 返回值,取不到时保持空。

#### 决策:AUTO 第一阶段保持简单且可解释

选择顺序固定为:

```text
AUTO → NPU → Intel GPU → CPU
```

AUTO 会在 NPU 缺失、Intel GPU 缺失或 GPU 被排除时继续尝试下一级;显式 `NPU`
和 `GPU` 则分别返回 `NPU_NOT_AVAILABLE` / `GPU_NOT_AVAILABLE`,绝不静默切换
到 CPU。选择结果同时携带 requested、实际 rawName/fullName、尝试状态和原因。
模型兼容性、性能、缓存命中等更高层因素留给后续 Model Profile / Runtime
Policy,本 Task 不把「设备可枚举」宣传成「任意模型可编译」。

#### 验证

新增测试覆盖:

- `GPU.0` Intel 与 `GPU.1` NVIDIA 的 vendor 区分,包括 NVIDIA 被排除而非消失;
- AUTO 的 NPU → Intel GPU → CPU 优先级与实际设备全名;
- 显式设备选择、NPU/GPU 专用错误码、非法请求;
- 禁用/缺失/策略排除状态和无候选设备;
- 快照更新不触发 Backend 重新枚举。

这些是模拟 `BackendDeviceInfo` 的纯逻辑测试。README 中记录的 GPU/NPU 实际编译
与推理状态不变,仍为未验证。

---

## 九点五、Gemma 4 E2B 与 OpenVINO C API 的实测结论(Task 15/17 前置调查)

这一节全部是**探针程序对真实模型与真实 DLL 的实测结果**,不是推断。三个发现
直接改变了推理编排的设计。

### 1. language_model 是**有状态模型**,没有显式 KV-cache 端口

实测端口(`openvino_language_model.xml`,CPU 编译):

| 方向 | 索引 | 名称 | 类型 |
| --- | --- | --- | --- |
| IN | 0 | `attention_mask` | I64 |
| IN | 1 | `position_ids` | I64 |
| IN | 2 | `inputs_embeds` | F32 |
| IN | 3 | `per_layer_inputs` | F32 |
| IN | 4 | `beam_idx` | I32 |
| OUT | 0 | `logits` | F32 |

**没有任何 `past_key_values.*` 输入,也没有 `present.*` 输出。** 取而代之的是
`beam_idx` —— 这是 OpenVINO 有状态 LLM 表示的标志:KV-cache 作为**模型内部状态**
由 OpenVINO 自己管理,不经过输入输出端口。

这推翻了此前的假设(「几十个 `past_key_values.N.key` 输入」)。按名绑定的工作
仍然必要且正确(5 个命名输入,按名比按索引安全),但 KV-cache 的机制是内部状态,
不是手工传递。

注意 `per_layer_inputs` 对应那个 2.19 GB 的 PLE 子模型 —— 它是必需输入,不是可选项。

### 2. state API 在 C API 中**完全缺失**

```text
ov_infer_request_query_state       MISSING
ov_infer_request_reset_state       MISSING
ov_infer_request_get_variable_state MISSING
ov_variable_state_*                MISSING(全部)
```

后果:**无法在两次生成之间重置 KV-cache 状态。** 可行的替代做法是每轮生成
新建一个 InferRequest —— 新建的 request 状态是干净的。代价是重建 request 的开销,
但这是当前 C API 下唯一诚实可行的路径。

### 3. STRING 张量**只能写,不能读**

```text
ov_tensor_set_string_data     FOUND
ov_tensor_get_string_data     MISSING
ov_tensor_data_string         MISSING
ov_string_tensor_data         MISSING
(其余读取候选全部 MISSING)
```

这条最要紧,它决定了端到端文本生成能做到哪一步:

| 环节 | 可行性 | 依据 |
| --- | --- | --- |
| 文本 → token id(tokenizer IR) | **可行** | 可以把文本写进 STRING 输入张量 |
| token id → 向量(text_embeddings) | 可行 | I64 输入,F32 输出 |
| 前向 + 采样(language_model) | 可行 | 全部为数值张量 |
| token id → 文本(detokenizer IR) | **不可行** | 输出是 STRING 张量,C API 读不出来 |

不能用 `ov_tensor_data` 拿裸指针再解析:OpenVINO 内部把字符串张量存为
`std::string` 数组,而 `openvino_c.dll` 由 MSVC 编译、Nim 代码由 MinGW 编译。
跨这两种 ABI 解析 `std::string` 的内存布局不可靠 —— 正是 DEVLOG 第六节记录过的
那类问题。**这条路明确不走。**

**因此 detokenize 改用纯 Nim 实现**,直接读 `tokenizer.json` 的词表做反向映射,
不依赖 detokenizer IR。这不是绕过困难,而是当前 C API 下唯一能得到正确结果的做法。

### 4. tokenizer / detokenizer IR 需要先注册扩展

直接 `readModel` 会失败:

```text
Cannot create SpecialTokensSplit layer ... from unsupported opset: extension
Cannot create VocabDecoder layer ... from unsupported opset: extension
```

实测注册扩展后可以读取:

```text
ov_core_add_extension(runtime/openvino/openvino_tokenizers.dll) -> 0
ov_core_read_model(openvino_tokenizer.xml)                      -> 0   读取成功
```

`ov_core_add_extension` 存在且可用。`openvino_tokenizers.dll` 已在
`runtime/openvino/` 中。

### 5. 端口形状读不出来(动态形状)

`ov_const_port_get_shape` 对上述所有端口都失败,`PortInfo.shape` 因此为空。
原因是这些端口都是动态形状,而该函数只能返回静态形状。`ov_port_get_partial_shape`
与 `ov_partial_shape_is_dynamic` 存在,需要时可以补 —— 当前编排不依赖静态形状,
所以先不引入。

`readPortInfo` 刻意容忍这个失败(名字读不到才算失败),因此端口枚举仍然可用。

### 6. tokenizer.json 的格式(决定纯 Nim 反解码的可行性)

```text
model.type              BPE
model.byte_fallback     true
model.vocab             { token: id }        约 29.8 MB
added_tokens            含 <pad>/<eos>/<bos>/<unk>/<mask> 等
```

SentencePiece 风格:`▁` 表示词首空格,字节回退 token 形如 `<0xNN>`。
反向解码只需 id → token → 拼接 → 还原空格与字节 token,不需要 merges。

---

## 九点七、`isvik chat` 与一次代价高昂的排查教训

### 1. 交互式对话已可用(CPU 实测)

```text
isvik chat [<模型标识或目录>] [--device <设备>] [--max-tokens <n>]
           [--system <文本>] [--prompt <文本>] [--no-stream] [--plain]
           [--extension <路径>]
```

`--prompt` 走单轮后退出(便于脚本);不给则进入 REPL,支持
`/exit` `/new` `/history` `/info` `/system` `/help`。

实测多轮上下文确实生效 —— 第二轮准确引用了第一轮的问题:

```text
> 你好,请用一句话介绍你自己。
我是一个由 Google DeepMind 开发的、具有开放权重的语言模型,能够理解和生成文本。
  22 token · 首字 1066 ms · 27.9 tok/s · 自然结束

> 我刚才问了你什么?
您刚才问我:"你好,请用一句话介绍你自己。"
  14 token · 首字 210 ms · 29.3 tok/s · 自然结束
```

注意第二轮首字延迟只有 210 ms 而第一轮 1066 ms:两轮的提示词长度不同,
而 prefill 与长度相关。这也说明多轮是**每轮重新预填充**的 —— KV-cache
无法跨 InferRequest 复用(第九点六节修正一)。

#### 决策:tokenizer **固定编译到 CPU**,与语言模型的设备无关

第一次跑 `isvik chat` 时默认设备是 `AUTO`,解析为 NPU,然后直接失败:

```text
intel_npu ... model_serializer.cpp:119: Incorrect precision: string
```

tokenizer 的输入端口是 **STRING**,NPU 插件不支持这个精度。就算支持也不该
放上去 —— 那是个字符串切分图,不吃算力,却要为此付一次设备编译。

#### 决策:编译失败可回落到 CPU,但**必须显式说明**,且显式指定设备时不回落

回落条件刻意收窄:只对**编译失败**、且用户**没有**显式 `--device`、且当前
不是 CPU 时才回落。显式请求的设备不回落 —— 否则「这个设备到底能不能跑」
永远得不到答案。

回落时打印实际尝试的设备(从错误 detail 里取 `device=`,而不是照抄用户写的
`AUTO`,因为「AUTO 上失败了」对排查毫无帮助):

```text
在 NPU 上编译失败,已改用 CPU 重试。原因:Model compilation failed
本机只在 CPU 上验证过文本生成。若要坚持用该设备,显式加 `--device NPU`,
那样不会回落,你会看到原始错误。
```

顺带拿到 NPU 拒绝语言模型的**具体原因**,这是第九点六节「NPU 未验证」那条
的第一份实证:

```text
Upper bounds are not specified for node '...input_layernorm/aten::pow/Power'
  input '0' bounds are '[9223372036854775807, 9223372036854775807, 1536]'
Got non broadcastable dimensions pair : '9223372036854775807' and '-9223372036854775808'
```

动态维没有上界,NPU 编译器要求静态形状 —— 与第六节 6.1 第 4 条一致。
**NPU 上跑本管线需要给所有动态维设上界或改成静态形状,目前没有做。**

### 1.5 双击运行不再一闪而过(§39 Windows First)

用户最初反馈「双击 isvik.exe 不出现 CLI」。第一版修复用
`GetConsoleProcessList` 区分双击与终端启动:双击时控制台专属于本进程(返回 1),
而 PowerShell/cmd 中宿主 shell 也附着在同一控制台(返回 ≥2)。当时无参数只显示
帮助,所以双击路径在帮助后等待一次 Enter,终端与 `--json` 路径不暂停。

常驻工作台落地后,这个临时行为被进一步收敛:**双击与终端无参数启动现在都直接
进入工作台**。`-exit` 后立即关闭,不会再多等一次 Enter；只有工作台启动前发生
错误、且确实是双击运行时,才保留等待逻辑,让用户有机会读完错误信息。

仍拒绝用「有没有命令行参数」判断是否双击:无参数终端启动现在正是正式工作台
入口,脚本/管道的 EOF 也必须正常退出,不能挂住等一个永远不来的回车。

### 1.6 从一次性命令升级为常驻工作台

**决策:传统子命令保持兼容,无参数入口改为常驻工作台。** 现有
`version/config/devices/doctor/list/info/import/rm/chat/run` 的参数、JSON 和退出码
不能破坏；新增的 `-ls` 同时支持顶层 `isvik -ls` 与工作台内使用。

工作台命令包括 `-ls/-use/-devices/-doctor/-info/-import/-rm/-new/-history/
-system/-lang/-help/-exit`。非命令文本直接发送给当前模型；未知的 `-xxx` 不会
误发给模型,以 `-` 或 `/` 开头的普通文本可写成 `-- <文本>`。

**语言选择只在首次交互启动出现并持久化。** `-lang zh/en` 可随时切换。
保存采用“先写盘、成功后换 catalog”的事务顺序；若 settings.json 损坏,拒绝用
退化默认值覆盖原文件。显式 `--lang` 仍是临时覆盖,不偷偷修改用户配置。

**模型采用懒加载常驻会话。** 启动、`-ls`、切语言都不初始化 OpenVINO；
`-use` 或第一次自然语言输入才创建 `ChatSession`。同一会话复用 Runtime 和已编译
TextGenerator,但每轮仍新建 InferRequest 并重新 prefill 完整历史 —— 当前 C API
缺少可靠 state reset,跨轮复用 KV cache 会污染结果。`-new` 只清历史,不重编译。

切模型先构造候选 Runtime/Generator,成功后才释放旧会话；失败时旧会话仍可继续。
AUTO 编译失败的回落规则与 `isvik chat` 相同:只对编译失败回落 CPU,并显示实际
失败设备；显式设备请求不应被静默替换。

**2026-08-20 真机验证:**Gemma 4 E2B INT4 在工作台中以 CPU 8.4 秒就绪。
第一轮要求记住 `ORBIT` 并回复 `OK`,实际返回 `OK`；第二轮只问此前的 code word,
实际返回 `ORBIT`。`-history` 显示 4 条 user/assistant 消息,证明自然语言直聊、
完整历史 prefill 和同一常驻会话均生效。两轮首 token 分别为 1150 ms 与 213 ms；
这些是该次运行的观察值,不是 Benchmark。另一次 AUTO 路径真实触发 NPU 动态 shape
编译失败并明确回落 CPU,没有把 CPU 结果伪装成 NPU 成功。

工作台首屏刻意强调 Isvik 自己的定位:本地优先、真实设备感知、不伪造运行状态。
它借鉴成熟 CLI 的常驻交互方式,但没有复制其他产品品牌、远程 Agent 能力或尚未
实现的功能。

### 2. 教训:排查工具本身在骗人

这次排查花的时间远超实现时间,而**全部结论最后都被推翻**,根因不在代码里。

**现象**:`isvik chat` 打印「已就绪」之后就没有输出了,退出码 0,stderr 为空。
反复出现,看起来完全可复现。

**当时依次提出并「验证」的假设**(全部是错的):

| 假设 | 当时的「证据」 | 实际 |
| --- | --- | --- |
| stdout 全缓冲、退出未刷新 | 加 `flushStreams` 后 JSON 模式「变好了」 | 巧合:那次读文件时进程刚好跑完 |
| 需要 `setvbuf` 设无缓冲 | 加了之后仍然缺输出 | 改动本身无必要 |
| `setvbuf` 导致崩溃 | A/B 对照:buffered 写出 RC=0,unbuffered 没写 | 第二次运行只是还没结束 |
| `loadVocabulary` 炸栈 | 探针在它那里「停住」 | 同上 |
| `enableUtf8Console` 有问题 | —— | A/B 证明无关 |

**真正的根因**:本机的命令执行工具在长命令**跑完之前就返回**。于是我每次
都在进程还在跑的时候去读日志文件,自然只看到前几行。第一个真正的线索是
同一个文件先读到 0 字节、后来变成 576 字节 —— 那时才该意识到问题在观测端。

**结论**:凡是「输出不完整」的现象,先证明被观测的进程**已经结束**,再谈代码。
改用可轮询的后台进程接口(启动 → 轮询直到出现自己写的结束标记 → 再读文件)后,
同一份代码一次通过,全部输出完整。

这条已写进第七节「本地终端环境」。代码里也留下了两处注释,说明为什么
**不**改 CRT 缓冲策略(`cli/console.nim`)以及 `flushStreams` 的真实理由
(`cli/main.nim`)—— 避免后人从这两处推断出一个不存在的缺陷。

---

## 九点六、第一次真实文本输出(Task 15 + 17 打通)

**2026-08-20 实测**。这一节记录端到端文本生成从「零」到「跑通」的全过程,
包含三条对第九点五节结论的**修正**。

### 1. 结果先行:真实输出

模型 `gemma-4-E2B-it-int4-ov`,设备 **CPU**,贪心解码,全程 100% Nim:

```text
问: What is the capital of France?
答: The capital of France is **Paris**.
    停止原因 end_of_sequence   prompt 16 token   生成 8 token

问: Name three primary colors.
答: The three primary colors are:
    1. **Red**
    2. **Yellow**
    3. **Blue**
    停止原因 end_of_sequence   生成 24 token

问: 用一句话说明什么是操作系统。
答: **操作系统是在计算机硬件和用户之间进行交互的"中间人"和"管理者"。**
    停止原因 end_of_sequence   生成 20 token
```

耗时(CPU,首次已含编译后的冷启):prefill **978 ms**,解码 **19.1 tok/s**。

**这些数字只是本机 CPU 上的观察值,不是 Benchmark。** 正式的分阶段计时属于
Task 18,那里才会定义指标语义、控制变量、区分设备。此处记录是为了留下
「跑通时大约是这个量级」的痕迹。

### 2. 补齐的三个 Resonance 绑定

| 符号 | 用途 | 为什么必须有 |
| --- | --- | --- |
| `ov_core_add_extension` | 注册 `openvino_tokenizers.dll` | 不注册则 tokenizer IR 根本加载不了 |
| `ov_tensor_create` | 分配运行时拥有内存的张量 | STRING 元素没有扁平字节布局,`create_from_host_ptr` 用不了 |
| `ov_tensor_set_string_data` | 写 STRING 张量 | tokenizer 的唯一输入端口就是 STRING |

上层封装:`Core.addExtension`、`newOwnedTensor`、`setStringData`、`newStringTensor`。

#### 决策:签名无法阅读验证时,靠**行为**验证,不靠信任声明

本机没有匹配版本的 OpenVINO 头文件,`ov_tensor_set_string_data` 的参数个数
无法通过阅读确认。做法:

**先按 3 参数声明**(tensor, `ptr cstring`, `csize_t`)。理由是 cdecl 下
**多传**一个参数是无害的(callee 直接忽略),而**少传**会让 callee 读到垃圾。
两种猜法的代价不对称,所以选那个错了也不会崩的方向。

**再用往返测试证明它对**。决定性的一条断言:

```text
tokenize("Hello, world!")                                → 4 个 token
tokenize("Hello, world!Hello, world!Hello, world!")       → 恰好 12 个 token
```

三倍文本得到**精确三倍**的 token 数。元素个数若没有正确传到运行时,这一条不可能
成立。再加上「两次调用逐元素相同」「id 全部落在合理区间」「中文也能编码」,
签名的正确性有了实证而非推测。

拒绝:只断言「返回状态码为 0」。状态码为 0 只说明没被 guard 挡下,不说明语义对。

#### 踩到的坑:`ov_tensor_set_string_data` 拒绝空输入

对空序列传 `nil` + size 0 返回 **`-14 INVALID_C_PARAM`**,而不是当成空操作。
修法是 `setStringData` 在输入为空时**提前返回**,不调 C 函数。

这样保住了一条不变式:`newStringTensor(xs).getSize() == xs.len` 对**任何**输入
成立,而不是只对非空输入成立。测试里那条用例最初是按「应该允许」写的,
它失败时暴露的是真实行为 —— 于是改代码而不是改断言。

### 3. 形状全部问出来,一个都不猜

第九点五节第 5 条说「端口形状读不出来」。这条**仍然成立**
(`ov_const_port_get_shape` 对动态端口全失败),但**它不等于形状不可知**。

引入探针调用 `ov_port_get_partial_shape` 后,动态维显示为区间、静态维显示为具体值:

| 端口 | 类型 | partial shape |
| --- | --- | --- |
| `attention_mask` | I64 | `[0..inf, 0..inf]` |
| `position_ids` | I64 | `[0..inf, 0..inf]` |
| `inputs_embeds` | F32 | `[0..inf, 0..inf, **1536**]` |
| `per_layer_inputs` | F32 | `[0..inf, 0..inf, 0..inf, **256**]` |
| `beam_idx` | I32 | `[0..inf]` |
| `logits`(OUT) | F32 | `[0..inf, 0..inf, **262144**]` |

于是 hidden size = **1536**、词表 = **262144**、PLE 维 = **256**。

**PLE 的层数那一维是动态的,partial shape 问不出来。** 它来自
`openvino_text_embeddings_per_layer_model.xml` 的输出端口,读那份 XML 得到
`text_embeds_per_layer` 形状 `[-1, -1, **35**, 256]`,并与权重形状
`262144 × 8960`(8960 = 35 × 256)相互印证。**层数 = 35。**

#### 决策:生产代码不读 partial shape,改用一次最小前向问形状

`text_generator.nim` 的 `discoverShapes` 跑一次单 token 的 embedding 前向,
直接读**输出张量的实际形状**。代价是一次极小的推理,换来的是:

- 不需要为 partial shape 再加一组绑定与结构体布局假设(那个结构体是按
  假设布局解析的,探针里靠「rank 是否是个小正数」自证,生产代码不该依赖这种自证)。
- 得到的是**事实**而不是声明。动态维在这里反而是优点:实际跑一遍,动态维就变成
  了具体数字。

### 4. 对第九点五节的三条修正

#### 修正一:KV-cache 的 InferRequest 策略说反了

第九点五节第 2 条写「每轮生成新建一个 InferRequest」。**这个说法有歧义且容易
被实现成错的。** 准确的说法是两条,粒度不同:

```text
一次生成**内部**:必须复用同一个 InferRequest —— 内部 KV-cache 靠它累积,
                  第二步起只喂新 token(seq=1),attention_mask 用累计总长
跨**两次**生成  :必须换新的 InferRequest —— 状态无法重置,残留 cache 会让
                  下一次生成无声地产出错误结果
```

按「每轮新建」实现会导致每一步都从零算,虽然结果仍然正确(全序列重算),
但白扔掉 KV-cache 的全部收益;而按「一直复用」实现会让第二次生成被污染。
两个方向的错误一个是慢、一个是错,不能混为一谈。

测试里「连续两次生成互不污染」专门锁这一条:问 A → 问 B → 再问 A,断言第三次
与第一次的 token 序列**完全相同**。

#### 修正二:`attention_mask` 与 `position_ids` 的长度不同,这不是笔误

```text
attention_mask  [1, pastLen + seqLen]   覆盖累计长度(含内部 cache 里已有的)
position_ids    [1, seqLen]             只覆盖本步新喂的位置,取值从 pastLen 起
```

有状态模型下这两个长度必然不同。写成一样不会报错,只会让注意力范围错。

#### 修正三:Gemma 4 的对话标记**不是** `<start_of_turn>`

这是本次代价最大的一个坑。第一次跑通时用了 Gemma 3 的模板,得到:

```text
答: The capital of France is Paris.
    <end_of_turn><turn|><turn|><turn|>...(重复 9 次)
```

答案是对的,但尾部有垃圾。查 `chat_template.jinja` 才发现 Gemma 4 用的是:

```text
{bos}<|turn>user\n{内容}<turn|>\n<|turn>model\n
```

标记是 `<|turn>` / `<turn|>`。tokenizer 不认识 `<start_of_turn>`,于是把它按
普通文本切成 `<`,`start`,`_`,`of`,`_`,`turn`,`>` **七个** token 送进模型。

**用错模板不报错。** 模型足够鲁棒,照样答对了问题,然后把 `<end_of_turn>` 当
普通文本又写了一遍。这正是第六节第 6 条那类失败:看起来成功,产物有瑕疵。

**中途一个差点走错的判断,记下来当教训。** 看到 id 106 被解码成 `<turn|>` 时,
第一反应是「我的词表加载漏读了 `added_tokens`,106 应该是 `<end_of_turn>`」,
差点去改一个没坏的模块。实际证据链是:`added_tokens` 里有 46 `<|tool>` /
47 `<tool|>` 这种成对形式,说明 `<x|>` 就是这个模型的命名风格;
`generation_config.json` 里 `eos_token_id` 含 106。**词表是对的,模板是错的。**
教训:症状出现在 A 不代表根因在 A;改之前先找独立证据。

### 5. `eos_token_id` 是**三个**,不是一个

`generation_config.json` 实测:

```json
{ "bos_token_id": 2, "eos_token_id": [1, 106, 50], "pad_token_id": 0 }
```

只认其中的 `1`(`<eos>`)会导致**生成永不停止**,只能靠 maxNewTokens 截断 ——
第一次跑通时正是如此,末尾多出 9 个重复 token。

#### 决策:EOS 从 `generation_config.json` 读,且必须支持数组与单值两种写法

只处理数组会在单值模型上静默丢掉唯一的 EOS。缺失字段一律表示「未知」
(空序列 / -1),**不回落到任何「常见默认值」** —— 猜一个 EOS 比承认不知道危险,
因为前者会静默产出错误的停止行为。

由此 `StopReason` 分出 `max_tokens` 与 `max_tokens_no_eos_declared` 两态:
「声明了 EOS 但没命中」与「根本没声明 EOS」是不同的事实,后者的截断是唯一
可能的结局,调用方需要能区分。

### 6. tokenizer IR 不加 BOS

实测 `"Hello, world!"` → `@[9259, 236764, 1902, 236888]`,**没有前置 BOS(id 2)**。
Gemma 需要 BOS,所以由编排层按 `bos_token_id` 补,且已经以 BOS 开头时不重复添加
(重复的 BOS 会让模型看到训练时不存在的前缀)。

BOS 刻意**不**写进渲染出的提示词文本里 —— 那要求 tokenizer 恰好把 `<bos>`
字面量识别成特殊 token,而这一点在真实模型上并不保证。

### 7. 决策:不实现 Jinja,只识别已知格式

Gemma 4 的 `chat_template.jinja` 有三百多行,含宏、namespace 状态机、递归调用、
工具声明序列化。**在 Nim 里实现一个部分兼容的 Jinja 解释器比不实现更糟**:
它会在某些模型上静默产出错误提示词,而错误提示词的症状是「模型答得不好」,
几乎不可能被归因到模板 bug。

做法是从模板文件里找特征标记(`<|turn>` + `<turn|>`)匹配内建格式化器:

| 情况 | 判定 | 处置 |
| --- | --- | --- |
| 匹配到 Gemma turn 标记 | `cfGemmaTurn` | 用内建格式化器 |
| 模板文件不存在 | `cfPlain` | 直接续写(基座模型的正确行为) |
| 模板存在但不认识 | `cfUnknown` | **抛 MODEL_UNSUPPORTED**,让调用方自己拼 |

最后一行是关键:`cfUnknown` **不**回落到 plain。回落会产出结构错误的提示词,
而那种失败无法被归因到这里。

### 8. 新增模块

```text
src/isvik/inference/
├── gen_defaults.nim     generation_config.json(BOS / 多个 EOS / 采样建议)
├── chat_format.nim      识别已知对话格式并渲染,不解释 Jinja
├── tokenizer.nim        tokenizer IR 包装(经 Runtime,不碰 Resonance)
└── text_generator.nim   编排:tokenize → embeddings(+PLE) → LM → 贪心 → 词表解码

tests/inference/
├── tgeneration.nim      23 项纯单元测试(gen_defaults + chat_format),无条件运行
└── tgeneration_real.nim 真机端到端,由 ISVIK_TEST_MODEL_DIR 开启
```

Backend 抽象新增 2 个 base method:`registerExtension`、`setStringInputByName`,
两个 Backend 都实现。Runtime 新增同名封装。

`setStringInputByName` 与 `setInputTensorByName` 分开而不是复用:Isvik 的
`Tensor` 只表示数值元素类型,STRING 元素装不进去。

`src/isvik/inference/` 在架构受检范围内,因此全程只经 Runtime,**不 import
resonance**。架构测试照常通过。

#### 决策:真机测试断言管线性质,不断言模型答案

刻意**不**断言「首都是巴黎」:那考的是模型不是 Isvik,且换模型必然失败,
变成噪音。断言的是那些**只要编排错就一定不成立**的性质:

- 自然停止(`end_of_sequence`)而非被长度截断 —— 锁的是多 EOS
- 流式片段拼接**等于**整体文本 —— 锁的是 UTF-8 缓冲不丢字节
- 每个流式片段都是合法 UTF-8 —— 锁的是中文不吐半个码点
- 贪心可复现(两次相同输入 token 序列相同)—— 锁的是相等取小 id + 跳过 NaN
- 连续两次生成互不污染 —— 锁的是 InferRequest 生命周期
- 计时非零 —— 锁的是「§35 不得声称未采集到的指标」

### 9. detokenizer IR 的结论不变

第九点五节第 3 条仍然成立:detokenizer 的输出端口是 STRING,而读取 STRING 的
符号(`ov_tensor_get_string_data` 等)**全部 MISSING**,该 IR 在当前运行时
无法使用。解码走纯 Nim 的 `vocabulary.nim`,已被中英文两种输出验证。

### 10. 验证

| 项目 | 结果 |
| --- | --- |
| Isvik 全量(含真机生成与工作台) | **26 个测试文件全通过,`[FAILED]` = 0,编译警告 = 0** |
| Resonance(含 STRING 张量往返) | **全通过**,新增 9 项 |

启用真机生成那一档:

```powershell
$env:ISVIK_TEST_MODEL_DIR = "D:\Model\gemma-4-E2B-it-int4-ov"
```

启用 Resonance 的 STRING 张量那一档:

```powershell
$env:RESONANCE_TEST_TOKENIZER_XML = "D:\Model\gemma-4-E2B-it-int4-ov\openvino_tokenizer.xml"
$env:RESONANCE_TEST_TOKENIZER_EXT = "D:\nim\Isvik\runtime\openvino\openvino_tokenizers.dll"
```

### 11. 仍未验证的事项(如实标注)

- **GPU / NPU 上的文本生成完全未测试。** 以上全部为 CPU。NPU 要求静态 shape,
  而本管线全程使用动态 shape,**NPU 可行性没有任何证据**。
- **INT4 的 KV cache group size = 64**(已知问题 ID 186412)**未设置**。
  当前跑的是默认值,输出质量是否受影响未测量。
- **多轮对话未测试。** 现有测试都是单轮。多轮需要把历史消息渲染进提示词,
  格式化器支持这么做,但没有跑过。
- **batch > 1 未支持。** `greedy.lastPositionView` 对 batch>1 抛 NOT_IMPLEMENTED,
  编排层也固定 batch=1。
- **温度 / top-p / top-k 采样未实现。** 只有贪心。模型建议的采样参数被读出
  并保留,仅用于如实回报「模型建议了什么」,不参与解码。
- **vision_embeddings 子 IR 未接入。** 多模态输入未实现。

---

## 十、下一步

Task 10 的 Device Manager 模块与策略测试已完成,但**有两处尚未闭合**,在进入
Task 11 之前必须先记清楚,不能当成已交付能力:

1. **Device Manager 还没有被任何生产路径调用。** `core/runtime.nim` 仍然把调用方
   给的 `CompileOptions.device`(rawName)原样交给 Backend;`settings.json` 的
   `default_device`(AUTO)与 `UnifiedInferenceRequest.device` 都还没有人解析。
   也就是说 §11/§12 的语义集中在库层面成立,端到端尚未生效。接入点涉及
   「谁在何时解析 request.device、实际设备写回哪里」,属于 Application Service
   的设计范围,不应在 Core 里随手接一条线。
2. **vendor 解析尚未在真机设备快照上验证。** 现有 12 个测试用的是模拟
   `BackendDeviceInfo`。解析器是按 DEVLOG 记录的实测串
   `GPU: vendor=0x8086 arch=v12.70.4` 设计的,但没有跑过一次真实
   `discoverDevices()` 来确认本机 `GPU.0` / `GPU.1` / `NPU` 会被正确分类。
   §52 要求「获取真实设备信息」,这一条尚未有证据。

**Task 编号沿用既有约定**(散见于本文件第六节与 Task 8 收尾):

```text
Task 11  CLI 框架 + i18n + 错误码到退出码映射
Task 12  isvik doctor / isvik devices
Task 13  Model Manifest
Task 14  Model Storage / Model Manager
Task 15  推理编排 + tokenizer(STRING 张量需单独路径)
Task 16  Compiled Cache
Task 17  端到端文本生成
Task 18  真实 Benchmark
```

Task 19 在既有记录中没有明确定义,**不在此处替它编造内容**,待与规范
PHASE 15-18(GUI / Integration / Documentation / Release)对齐后再确定。

继续保持「真实检测、真实错误、未验证不宣称」的约束。

---

## 十一、Application Services、采样、多协议 API、Local Server 与 Benchmark

本轮把「架构上已定型但没有执行者」的部分接通,并补齐 §21 / §35。GUI 按要求
暂缓。

### 1. 最重要的发现:统一请求此前没有执行者

`UnifiedInferenceRequest`(§20.5.3)的字段是齐的,`protocol/native.nim` 也能把
JSON 解析成它,但**整个 src 里没有任何代码消费它**:

```text
Protocol Adapter  →  UnifiedInferenceRequest  →  ???
```

后果是两处静默失效:

- `request.device` 被解析出来后无人使用。设备解析实际发生在
  `text_generator → runtime.compileModelForDevice`,与请求字段没有连接。
- `parameters.temperature / topP / topK / seed` 完全被忽略。`gen_defaults` 会从
  `generation_config.json` 读出模型建议的采样值,但注释明确写着「仅作记录」。

这正是 §20.5.13 第 12 条要防的情况:声明了字段却不实现,客户端按声明去用,
然后拿到静默错误的结果。`services/inference_service.nim` 是补上的那个执行者。

### 2. CPU 回落判据此前有两份,而且不一样

回落被实现了两遍:

```text
cli/cmd_chat.nim     e.code == ecCompilationFailed and not deviceExplicit
                     and not isCpuRequest(device)
cli/workbench.nim    e.code == ecCompilationFailed and device == "AUTO"
```

差异是真实的:`settings.json` 里写了 `default_device: GPU` 的用户,走
`isvik chat` 会被静默换到 CPU,走工作台则看到真实的编译失败。

**决策:统一为「只有 AUTO 才回落」**,判据落在
`services/device_service.allowsCpuFallback`。理由是 §12 —— 显式指定的设备不可用
时必须报错;`settings.json` 里的 GPU 同样是用户的显式选择,悄悄换成 CPU,
「这台机器的 GPU 到底能不能跑」就永远得不到答案。

拒绝:保留两套判据并在文档里说明差异。那等于承认同一个操作在两条路径上
结果不同。

### 3. 服务层不 import i18n

模型解析失败有多种成因,每种成因前端要说的话不一样:CLI 要说「用 -ls 查看
编号」,HTTP 要回 `MODEL_NOT_FOUND` 的 JSON。

于是 `ModelService.resolveReference` 返回 `ModelResolution`(状态是枚举),
由前端决定怎么说。CLI 侧新增 `ctx.raiseUnresolved` 渲染界面语言。

这与 `models/manager.Eligibility` 用 `status + reason` 而不是 bool 是同一个
取舍:调用方需要知道**为什么**,不只是「行不行」。

### 4. 采样:temperature=0 必须与贪心逐位相同

`sampling.nim` 在 `temperature <= 1e-6` 或 NaN 时**直接委托 `greedyChoice`**,
而不是自己写一份 argmax。

理由:「temperature=0 等于贪心」这条等价关系如果有两份实现,会在平票规则
(取较小 id)上慢慢分叉,而那种分叉只表现为「CPU 与 NPU 输出不同」,极难归因。

阈值不用 `== 0.0`:极小的温度会让 `logit / temperature` 溢出成 inf,softmax 得到
NaN,最终静默选出错误 token。

过滤顺序是 `temperature → top-k → top-p → 归一化 → 抽样`。top-p 是对**概率**的
截断,必须在温度缩放之后算,否则「保留累计 90% 概率」指的不是最终分布的 90%。

未指定 seed 时**也会生成一个具体 seed 并如实回报**(`GenerationResult.samplingSeed`
→ `result.metadata["sampling_seed"]`)。否则「模型有时输出乱码」这类报告无法复查。

### 5. Adapter 声明的能力就是真正实现的能力

OpenAI 协议本身能表达 tools 与 response_format,但 `OpenAiChatAdapter` **不声明**
这两项。好处是 `requireSupportedRequest` 在入口就返回 NOT_IMPLEMENTED,
而不是让请求跑到解码层才失败。

一个踩到的坑:`requiredCapabilities(req)` 会因为消息里含 reasoning 片段而要求
`pcReasoning`。Anthropic Adapter 最初没声明它,于是带 thinking 块的请求在入口
被自己拒了。**修正方式是声明它** —— 因为 Anthropic 确实有 `thinking` 块与
`thinking_delta`,推理内容能双向如实表达。OpenAI Chat 没有对应字段,只能丢弃,
因此不声明,这个差异是真实的而不是遗漏。

`ContentDelta` 之外的取舍:`ReasoningDelta` 在 OpenAI Chat 里返回 `noChunks()`。
塞进 `content` 会让思考过程出现在回答正文里。

### 6. 流式块的身份字段由传输层补齐

OpenAI 的每个 chunk 都带 `id` / `created` / `model`,但 `formatEvent` 只收到一条
事件,除 `InferenceStarted` 与 `InferenceCompleted` 外都不携带模型名。

**决策:让 Adapter 保持无状态**,缺失字段由 HTTP 层用 `withStreamIdentity` 补齐。

拒绝:让 Adapter 记住 `streamModel` / `streamId`。两个并发流会互相覆盖对方的
状态,症状是「偶尔有个请求的 model 字段是别人的」。

### 7. Local Server 的一个真实限制:SSE 不是增量投递

`asynchttpserver` 是单线程 async,而解码是同步的。在事件回调里 `waitFor` 发送
数据会**递归进入事件循环**,那是明确的错误用法。

三个选项:

1. 用 fd 直接做阻塞写。可行,但要绕过 asyncdispatch 的状态管理。
2. 对 `stream: true` 返回 NOT_IMPLEMENTED。会让 OpenAI / Anthropic SDK 直接不可用。
3. 攒完整条事件流再一次发出。帧格式完全正确,客户端能正常解析,区别只在它们
   同时到达。

**选 3,并在启动日志与 README 里明确写出这一点。** 选 2 会让能用的东西不可用;
选 1 的复杂度在当前阶段不划算 —— 真正的增量投递需要把推理挪出事件循环,
那是 §70 的工作。

不接受的做法是选 3 但不说,让人以为拿到了增量流。

另外:`ProtocolAdapter` 的 method 是动态派发的,编译器无法证明 GC-safe,
于是 `serve` 回调用了 `{.cast(gcsafe).}`。这在**单线程**前提下成立,注释里写明了
引入 worker 线程时必须去掉并逐个审查。

### 8. Benchmark 的危险不是造假,而是统计代码给出合理的假数字

`metrics.nim` 用 `UnknownMetric = -1.0` 表示「测不出来」,并且**从不**让它参与
平均:

```text
只生成 1 个 token   →  解码吞吐没有定义。0 会被读成「慢」,inf 会被读成「快」。
decodeMs = 0        →  除零。
样本数为 0          →  平均值没有定义。
```

其它三条:

- 分位数用**最近秩**法,不做线性插值。插值会产生样本里并不存在的数值;
  「p95 是某次真实观测」可以回去查那一次到底发生了什么。
- 解码吞吐的分子是 `generatedTokens - 1`。prefill 与 decode 是两种计算模式,
  混在一个吞吐里会同时低估解码速度、高估端到端速度。
- 默认贪心。随机采样会让每轮生成的 token 数不同,而 token 数直接决定耗时 ——
  那样测出来的是运气,不是性能。

展示层还有最后一道:`formatMetric` 对未知值输出 `n/a`,JSON 输出 `null`
(而不是把 `-1` 这个内部哨兵泄漏给脚本 —— 脚本很可能直接把它画进图表)。

### 9. 本轮的真机验证

Local API(临时配置 + 真实 Gemma,CPU):

```text
GET  /api/version|health|models|runtime   200
GET  /api/nope                            404
GET  /api/chat                            405   Allow: POST
POST /api/chat  (坏 JSON)                 400
POST /v1/chat/completions                 200   content "READY"
                                                finish_reason "stop"
                                                usage 16/1/17
                                                isvik.device "CPU"
POST /v1/messages                         200   stop_reason "end_turn"
POST /v1/chat/completions (stream)        200   text/event-stream
                                                role → content → finish → [DONE]
```

Benchmark(请求 AUTO → NPU 编译失败 → 实际 CPU,3 次 + 1 预热,16 token):

```text
first token (ms)          mean 87.0    p50 78.5    p95 104.6   3/3
decode rate (tok/s)       mean 18.56   p50 19.05   p95 19.71   3/3
end-to-end rate (tok/s)   mean 16.83   p50 16.35   p95 18.09   3/3
```

输出里同时打印了「请求 AUTO / 实际 CPU」并附加说明。**没有把 CPU 的数字挂在
NPU 名下。**

### 10. 本轮仍未实现的部分(如实列出)

> 后续更新:下表中的 **OpenAI Responses API** 与 **Tool Calling 接入解码**
> 已在第十二节完成,其余条目仍然成立。

```text
GUI                          按要求暂缓
OpenAI Responses API         未实现,只有 Chat Completions
Tool Calling 接入解码         协议层模型就绪,解码层显式报 NOT_IMPLEMENTED
Structured Output 接入解码    同上
stop 序列 / penalties        同上
非对话 input 路径(embeddings) 同上
batch > 1                    解码层固定 batch=1
多模态 vision_embeddings      未接入
并发请求                     推理阻塞事件循环(§70)
SSE 增量投递                  帧正确但同时到达,原因同上
HTTP 鉴权                    没有。默认只监听回环,绑定对外地址时启动日志警告
GPU / NPU 上的文本生成        仍然没有证据
```

---

## 十二、OpenAI Responses API 与 Tool Calling 的解码接入

本轮闭合第十一节 §10 表格里的前两条。GUI 仍按要求暂缓。

### 1. 核心取舍:工具调用用提示词方案,并把这个事实写进文档

Gemma 4 没有工具调用专用 token,也没有经过 function-calling 微调。摆在面前
只有三条路:

| 选项 | 结果 | 是否采纳 |
| --- | --- | --- |
| 等模型侧原生支持 | §20.5.5 的统一 Tool 模型**永远无法端到端验证** | 拒绝 |
| 继续在解码层报 NOT_IMPLEMENTED | 协议层能表达而解码层拒绝,整条链路无法验证 | 拒绝 |
| 提示词注入 + 输出解析 | 链路可跑通,但可靠性取决于模型是否听话 | **采纳** |

采纳第三条的前提是**把局限写在 README 里**,而不是让人以为拿到了
function-calling 微调模型的等价物。第二条看起来最「诚实」,但它的代价是
统一 Tool 模型、Adapter 的 tools 解析、事件流的 `toolCallStarted` /
`toolCallDelta` 全都没有任何一条端到端证据 —— 那种「实现了但从未跑通」的代码
和没实现的区别很小,而且会在真正接模型时集中暴露。

### 2. 信封键必须带命名空间

新模块 `src/isvik/inference/tool_calling.nim` 定义两个键:

```text
isvik_tool_call     模型 → Isvik   {"isvik_tool_call": {"name":..., "arguments": {...}}}
isvik_tool_result   Isvik → 模型   工具执行结果回传时的标记
```

**拒绝通用形状 `{"name":..., "arguments":...}`。** 理由不是洁癖:用户问
「调用这个工具的 JSON 长什么样」时,模型会在回答里随手写一个示例,而那个示例
的形状与真实调用完全一致 —— 于是一段解释性文字被当成真调用执行了。这是最难
排查的一类误判,因为请求和响应两边看起来都正常。带命名空间的键让「示例」和
「调用」在词法上就不同。

配套两个私有辅助:`balancedObjectEnd`(按花括号配对找对象边界,不靠正则)、
`stripFenceArtifacts`(去掉模型习惯性加的 ``` 围栏)。

### 3. 四条「宁可报错也不猜」的规则

| 情况 | 处置 | 拒绝的做法 |
| --- | --- | --- |
| 请求**没有**声明任何工具 | `extractToolCalls` 完全不解析 | 照样解析。没告诉模型工具存在,形状相似的内容只能是普通文本 |
| 模型调用了**未声明**的工具 | `ecToolCallFailed` | 原样透传。客户端会被要求执行自己没提供的工具 |
| `tool_choice` 为 `required`/指定工具,模型却没调用 | `ecToolCallFailed` | 把那段文字当正常回答。客户端会误以为「模型认为不需要工具」 |
| 出现工具调用 | `stopReason` 强制为 `srToolUse` | 沿用模型自身的终止原因。客户端靠 stop reason 决定要不要执行工具 |

`checkToolChoiceSatisfied` 是第三条的落点。它检查的是**约束**而不是内容质量 ——
「模型答得好不好」不是 Isvik 该判断的,「模型有没有遵守客户端给的约束」是。

### 4. 工具结果回传:`mrTool` → `crUser` + 标记

`chat_format.ChatRole` 只有 `crSystem` / `crUser` / `crAssistant`,没有 tool。

**决策:`mrTool` 渲染为 `crUser`,内容包在 `isvik_tool_result` 标记里。**

拒绝给 `chat_format` 加 tool 角色:各模型的工具回合模板差异很大且大多含
特殊 token,而 Isvik 明确不实现 Jinja(第九点六节 §7),硬加一个角色等于
再引入一处「猜模板」的风险。

拒绝伪装成普通用户发言:模型需要知道这段内容来自工具执行而不是用户输入,
否则它会把工具的返回值当成用户的新提问。

### 5. 工具指令插在 messages **最前面**

`renderToolInstructions` 产生的 system 消息插到消息列表首位,不是追加末尾。

理由是对话模板**按顺序渲染**:末尾的 system 会出现在用户问题之后,而训练
数据里不存在「用户提问 → 系统指令 → 模型回答」这种顺序。追加末尾不会报错,
只会让模型对指令的遵守率莫名下降 —— 又一个静默失效。

### 6. `argumentsObject` 的归属:放 `core/tools.nim`,且不抛错

OpenAI 的 `arguments` 是**字符串**,Anthropic 的 `input` 是**对象**。两个
Adapter 都需要把 `ToolCall.argumentsText` 变成 `JsonNode`。

**决策:该函数放 `core/tools.nim`,解析失败返回空对象而不是抛异常。**

拒绝放 `tool_calling.nim`:那是 inference 层,protocol 层不该依赖它。
拒绝解析失败时抛异常:这个函数只在**输出格式化**阶段被调用,此时推理已经
成功完成。在那里抛异常会把一次成功的推理变成失败请求,而客户端拿到的是
500 而不是「这次工具参数没解析出来」。

### 7. Responses 的 `status` 必须严格区分

```text
srEndTurn / srStopSequence / srToolUse  →  "completed"
srMaxTokens  →  "incomplete" + incomplete_details.reason = "max_output_tokens"
srCancelled  →  "cancelled"
srError      →  "failed"
```

拒绝一律返回 `completed`:被 `max_output_tokens` 截断的半截回答会看起来完整,
客户端不会重试也不会提示用户。

### 8. Responses 拒绝有状态字段(501),不静默忽略

`previous_response_id` 与 `store: true` 一律 `NOT_IMPLEMENTED`;
`store: false` 接受,因为它与无状态实现一致。

静默忽略 `previous_response_id` 是最危险的选项:客户端会以为上一轮上下文还在,
而模型什么都不记得。症状是「模型突然失忆」,极难归因到一个被忽略的请求字段。

`instructions` 转成第一条 system 消息 —— 与 Anthropic 顶层 `system` 同一处理
方式,差异在 Adapter 边界消化。

### 9. 流式事件的两个必须

**OpenAI 的参数增量块不重复 `id` / `name`。** 客户端按 `index` 累积
`function.arguments`,重复的 id 会被当成第二次工具调用。

**Anthropic 的工具流式要先发 `content_block_stop`,再以 index 1 开
`tool_use` 块。** 少了那个 stop,官方 SDK 的状态机会认为文本块还没结束,
后续事件全部错位。

### 10. 三个 HTTP Adapter 均**不**声明 `pcStructuredOutput`

`response_format` / `text.format` 没有接入解码,所以能力声明里不能有它。
这是第十一节 §5 那条原则的延续:声明的能力就是真正实现的能力,
`requireSupportedRequest` 在入口就拒绝,而不是让请求跑到解码层才失败。

> **后续修正(第十三节):本轮只做到一半。** 不声明能力确实会让入口拒绝,
> 但前提是那个字段被 `parseRequest` **解析进了统一请求** —— 而当时两个
> OpenAI Adapter 都没有读 `response_format` / `text.format`,于是
> `requiredCapabilities` 看不到 `pcStructuredOutput`,请求被当成普通文本
> 返回 200。真机实测确认了这个洞,已在第十三节修复。

### 11. 踩到的坑

**`declared` 是 Nim 的编译期魔法。** 测试里把变量命名为 `declared` 后编译报
`Error: cannot generate code for: mDeclared`,报错位置在
`unittest.nim:543`(`check` 宏展开处),与真正的原因相距很远。改名 `toolSet` 解决。
教训:报错行号指向宏定义时,先怀疑自己的标识符撞了魔法/内建名。

**Nim 不支持内联 `try:` 表达式。** `anthropic.nim` 里写
`let x = try: parseJson(s) except: newJObject()` 报 `Error: expected 'except'`。
改为调用 `call.argumentsObject()` —— 顺带印证了第 6 条把这个函数下沉的必要性。

**`toChatMessages` 拼接文本片段时不能无脑加换行。** 最初每个片段之间都插
`\n`,导致 `tinference_service.nim` 里断言 `content == "abcd"` 得到 `"ab\ncd"`。
改为文本片段直接拼接,只在工具信封之前插换行。

**OpenAI 工具循环第一次真机测试返回 400。** 原因是 `parseRequest` 拒绝
`content: null` —— 而带 `tool_calls` 的 assistant 消息按 OpenAI 规范正是
`content: null`。补上 `tool_calls` 与 `role: "tool"` + `tool_call_id` 的解析后
闭环成立。这条说明:工具调用不是「输出一个调用」就完了,**回传路径同等重要**,
只测第一轮会漏掉一半。

### 12. 新增与改动

```text
新增
  src/isvik/inference/tool_calling.nim        指令渲染 + 输出解析(纯模块)
  src/isvik/protocol/openai_responses.nim     Responses Adapter
  tests/inference/ttool_calling.nim           25 个用例
  tests/api/openai_responses/topenai_responses.nim   39 个用例

改动
  src/isvik/core/tools.nim                    加 argumentsObject
  src/isvik/services/inference_service.nim    接入工具调用;requireSupported 不再拒 tools
  src/isvik/protocol/openai_chat.nim          声明 pcToolCalling;tools/tool_choice/工具循环
  src/isvik/protocol/anthropic.nim            声明 pcToolCalling;tool_use/tool_result
  src/isvik/protocol/registry.nim             注册 openai-responses
  src/isvik/server/routes.nim                 加 /v1/responses
  README.md                                   状态表、端点表、Tool Calling 一节、已知限制
```

既有测试的断言同步更新:`tregistry.nim`(3 → 4 个 Adapter)、
`thttp_server.nim`(`adapters().len == 4`)、`troutes.nim`(四个协议端点)、
`topenai_chat.nim` 与 `tanthropic_messages.nim`(断言 `pcToolCalling in caps`)。

### 13. 真机验证(真实 Gemma,CPU)

```text
POST /v1/responses                        200  output_text "Ready"
                                               status "completed"
                                               incomplete_details null
                                               isvik.device "CPU"
POST /v1/responses (previous_response_id) 501  NOT_IMPLEMENTED
POST /v1/chat/completions                 200  content null
     tool_choice "required"                    tool_calls[0].function.arguments
                                                 "{\"city\":\"Oslo\"}"
                                               finish_reason "tool_calls"
POST /v1/messages                         200  tool_use 块
     tool_choice {"type":"any"}                input {"city":"Oslo"}
                                               stop_reason "tool_use"
POST /v1/chat/completions                 200  content "The weather in Oslo is
     (第二轮,回传 tool 结果)                       12C and raining."
                                               finish_reason "stop"
```

最后一条是关键:它证明**工具循环闭环**,而不只是「能输出一个调用」。

### 14. 本轮仍未实现(如实列出)

```text
Structured Output 接入解码    response_format / text.format 仍报 NOT_IMPLEMENTED
                             三个 Adapter 均不声明 pcStructuredOutput
stop 序列 / penalties        同上
Responses 的服务端会话状态    previous_response_id / store:true 报 501
GUI                          按要求暂缓
其余第十一节 §10 的条目       不变(并发、SSE 增量、鉴权、batch>1、多模态、GPU/NPU)
```

**工具调用可靠性未量化。** 已验证的是链路正确与约束被强制执行;
「模型在多大比例的请求里会正确产出信封」没有测量,那需要一批标注好的
工具调用样本,不在本轮范围。

---

## 十三、一次「检查 Anthropic API」检查出的真实漏洞

起因是一句「Anthropic API 有吗,检查一下」。Anthropic Adapter 本身完整且可用,
但这次逐条真机探测顺手发现 **OpenAI 侧有一个静默忽略**,而它恰好是第十二节的
README 刚刚承诺过「不会发生」的那件事。

### 1. Anthropic Messages 的实测结论:完整可用

代码层面:注册在 `newDefaultAdapterRegistry`,路由 `/v1/messages` →
`anthropic`,27 个单元用例。真机(真实 Gemma,CPU)逐条打过:

```text
system + 单轮              200  content[0].text "Circle"  stop_reason "end_turn"
多轮 + 块数组 content       200  "SECOND"(历史确实生效)
stream: true               200  六个具名事件序列完整
tool_choice {type:"tool"}  200  tool_use 块  input {"city":"Bergen"}
                                stop_reason "tool_use"
缺 max_tokens              400  INVALID_REQUEST
messages 里放 system       400  INVALID_PARAMETER
image 块                   501  NOT_IMPLEMENTED
temperature: "hot"         400  INVALID_PARAMETER
未知 tool_choice.type      400  INVALID_PARAMETER
未知模型                    404  MODEL_NOT_FOUND
```

错误体是 Anthropic 自己的形状 `{"type":"error","error":{...}}`,含 Isvik 错误码,
不含 `detail`。

### 2. 真正的发现:`response_format` 被静默忽略

顺手在 `/v1/chat/completions` 上打了一发
`response_format: {"type": "json_object"}`,**返回 200 和一段普通散文**。

README 上一节刚写着「`response_format` 请求这些字段会得到 `NOT_IMPLEMENTED`
而不是被静默忽略」。那句话是错的。

**根因:`openai_chat.parseRequest` 从来没有读 `response_format`。**

链条是这样断的:

```text
requiredCapabilities(req)  从**统一请求**推导,不看原始 JSON
        ↓
req.responseFormat 保持默认 rfkText
        ↓
不 incl(pcStructuredOutput)
        ↓
requireSupportedRequest 认为「这个请求不需要结构化输出」,放行
        ↓
inference_service.requireSupported 检查 responseFormat.kind != rfkText,也放行
        ↓
按普通文本生成,200
```

`openai_responses.nim` 的 `text.format` 同一个问题。

### 3. 教训:「不声明能力」只在字段被解析出来时才生效

这是本轮唯一值得记的结论,而且它是反直觉的。

第十一节 §5 立的规矩是「声明的能力就是真正实现的能力,不声明就会在入口被拒」。
这条规矩本身没错,但它有一个没写出来的前提:**能力是从统一请求推导的,
所以字段必须先被解析进统一请求。**

于是出现一个荒谬但真实的情形:**为了拒绝一个字段,必须先认真解析它。**
不解析不等于拒绝,而等于当它不存在 —— 也就是静默忽略,正是要防的那件事。

拒绝的替代方案:在 `parseRequest` 里遇到 `response_format` 直接
`raiseIsvikError(ecNotImplemented)`。**没有采纳。** 那样会绕开能力声明这套机制,
将来 Structured Output 真接进解码时,得记住回来删掉这个特判 ——
而「记得回来删」在实践中不成立。照常解析 + 靠能力声明拒绝,
接进解码那天只需要在 `capabilities()` 里加一项。

### 4. 两处协议差异

```text
Chat Completions  response_format.json_schema.{name, schema}   有一层包装
Responses         text.format.{name, schema}                   扁平
```

按 Chat Completions 的形状给 Responses 写会缺 `schema` —— 现在报
`INVALID_REQUEST` 而不是当成 `text` 放行。测试里专门锁了这条:
「把 Responses 写成 Chat Completions 的形状」不能悄悄降级成普通文本。

`{"type": "text"}` 是默认值,不构成结构化输出需求,照常放行 —— 否则显式写出
默认值的客户端会莫名拿到 501。

### 5. Anthropic 侧为什么不需要改

Anthropic Messages **没有** `response_format` 字段。它的结构化输出机制是
**强制调用一个带 `input_schema` 的工具**,而那条路径已经走 Tool Calling
(已接入)。所以 Anthropic 没有对应的洞。

真机上给 `/v1/messages` 发 `response_format` 仍返回 200 —— 那是个**未知顶层
字段**,不是被忽略的已知字段。所有 Adapter 目前都不做严格未知字段拒绝
(Anthropic 官方会报 `unexpected keyword argument`)。这是另一个层面的问题,
**本轮没有扩大范围去做**,如实记在这里。

### 6. 改动与验证

```text
src/isvik/protocol/openai_chat.nim       + parseResponseFormat,接入 parseRequest
src/isvik/protocol/openai_responses.nim  + parseTextFormat,接入 parseRequest
tests/api/openai_chat/topenai_chat.nim         + 9 个用例
tests/api/openai_responses/topenai_responses.nim + 6 个用例
README.md                                已知限制补 Anthropic 的机制说明 +
                                         Anthropic 逐条实测表
```

测试不只断言「返回 501」—— 那无法区分「解析了并按能力拒绝」与「压根没解析、
恰好别的地方报了 501」。因此同时断言 `e.detail` 里含 `missing=structured_output`,
以及 `type: "text"` 时 `requiredCapabilities` 确实**不含** `pcStructuredOutput`。

修复后真机复验:

```text
/v1/chat/completions  response_format json_object   501(修复前 200)
/v1/chat/completions  response_format text          200(默认值,正确放行)
/v1/responses         text.format json_schema       501
/v1/messages          response_format(未知字段)     200(见上第 5 条)
```

---

## 十四、把 API 接到成品客户端(TRAE)时暴露的两个真实缺陷

前几节的验证都是自己发请求给自己看。这一节换成**成品客户端的请求形状**去打,
于是暴露了两个只有在「真的有人用」时才会显形的问题。两个都不是协议翻译写错,
而是**已实现的能力在真实路径上没有生效**。

目标客户端:TRAE 3.5.87(本机 `C:\Users\WANG\AppData\Local\Programs\Trae`)。
它的 `设置 > 模型 > 添加模型 > 自定义模型` 提供两种 API 格式:
`OpenAI Chat Completions 格式` 与 `Anthropic Messages 格式`,
填「自定义请求地址」后由它自己追加 `/chat/completions` 或 `/v1/messages`,
也可以打开「完整 URL」开关自己写全。这正好对上 Isvik 已有的两个兼容端点。

### 1. 缺陷一:`settings.default_device` 对兼容协议完全无效

第一个 `/v1/chat/completions` 请求直接在服务端刷出:

```text
[ERROR] [vpux-compiler] Got non broadcastable dimensions pair ...
[ERROR] [IE::FrontEnd::importNetwork] Upper bounds are not specified for node ...
```

而 `isvik --config <tmp> --json config path` 明确显示 `"default_device": "CPU"`。
配置说 CPU,实际却在编 NPU。

链条是这样断的:

```text
settings.json default_device=CPU
  → CliContext.settings           ✓ 读到了
  → cmd_serve → newApiServer      ✓ 传下去了
  → newInferenceService(paths, s) ✓ 收到了
  → 然后被丢掉                    ✗ InferenceService 没有字段存它
```

`InferenceService` 只用 `s` 去构造 `ModelService`,`defaultDevice` 没有落点。
而 OpenAI / Anthropic 协议**没有设备字段**,`parseRequest` 把 `req.device`
留成空串;空串在 `normalizeDeviceRequest` 里等价 `AUTO`;`AUTO` 的候选顺序是
硬编码的 `NPU → GPU → CPU`。于是每个兼容协议请求都从 NPU 开始试。

这里要说清楚**为什么这是缺陷而不是设计**。原注释写的是「device 保持为空即
交给 Runtime Policy(等价 AUTO)」,单看这句是自洽的。但它让
`settings.default_device` 成了一个**只对 CLI 生效、对 API 无声失效**的配置项。
用户改了配置、`config path` 也回显了新值,而 API 行为一点没变 ——
这正是 §20.5.13 第 12 条要避免的那种静默。

修法是让 `InferenceService` 记住它,并且只在**请求没给**设备时使用:

```nim
# newInferenceService
result.defaultDevice = normalizeDeviceRequest(s.defaultDevice)

# load
let requested =
  if device.strip().len == 0: svc.defaultDevice()
  else: device
```

顺序是刻意的:**显式请求优先,配置只填空缺**。原生协议
(`POST /api/v1/chat` 带 `"device"`)因此不受影响,而没有设备字段的兼容协议
终于能继承服务端默认值。`/api/load` 回报的 `requestedDevice` 也跟着改成
回显真实继承值,不再无条件写 `"AUTO"` —— 那个字段的存在意义就是如实回报。

修复后同一个请求:

```json
{"choices":[{"message":{"role":"assistant","content":"READY"},
 "finish_reason":"stop"}],"isvik":{"device":"CPU"}}
```

顺带说明:这台机器上 Gemma 4 E2B 的 NPU 编译失败本身是环境事实
(`vpux-compiler` 对动态上界的处理),不是 Isvik 的 bug。Isvik 的 bug 是
**用户已经说了用 CPU,却还是去试了 NPU**。

### 2. 缺陷二:流式错误被投递两次,`[DONE]` 之后还有帧

带 `tools` 的流式请求返回了这个(截取尾部):

```text
data: {"error":{...,"code":"TOOL_CALL_FAILED"}}
data: [DONE]
event: error
data: {"error":{...,"code":"TOOL_CALL_FAILED"}}
data: [DONE]
```

Anthropic 侧同构:`event: error` → `message_stop` → **又一个** `event: error`。

原因是收尾被写了两遍。`InferenceService.execute` 在抛错前会先
`emit(inferenceErrorFrom(e))`,而两个 Adapter 的 `formatEvent(iekInferenceError)`
本来就返回**完整的收尾序列**(OpenAI 是 error 块 + `doneChunk()`,
Anthropic 是 error + `message_stop`)。然后 `encodeEventStream` 的
`except IsvikError` 分支又补了一遍 error 帧和 `[DONE]`。

这个 bug 的后果分两种客户端,都不好:

- 按约定在 `[DONE]` 处停止解析的客户端(多数 OpenAI SDK):
  它在第一个 `[DONE]` 就停,后面那份重复无害 —— 但它**看到的错误是第一份**,
  这次恰好没丢。真正的问题是下一条。
- 严格状态机(Anthropic 官方 SDK 风格):`message_stop` 之后又来事件,
  属于协议外的帧;同一个错误出现两次也可能被记成两次失败。

修法不是删掉兜底,而是**只在流还没收尾时兜底**:

```nim
var terminated = false
proc emit(e: InferenceEvent): bool =
  ...
  if e.isTerminal:
    terminated = true
  ...
except IsvikError as e:
  if not terminated:
    payload.add(sseFrame("error", $response.body))
    ...
```

兜底仍然必要:在任何事件产生**之前**就失败的路径(入口校验、模型解析)
不会走 `emit`,那时客户端确实需要这一帧。

回归测试用「模型不存在 + `stream: true`」触发,它在解析阶段就失败,
**不需要真实模型也不需要 OpenVINO**,因此能进常规测试集:

```text
OpenAI    payload.count("data: [DONE]") == 1,且 [DONE] 是最后一帧
Anthropic count("event: error") == 1,且不含 [DONE]
```

### 3. 实测矩阵(TRAE 等价请求,含客户端常见附加字段)

| 请求 | 端点 | 结果 |
| --- | --- | --- |
| 单轮 + system,带 `stream_options` / `parallel_tool_calls` / `user` | `/v1/chat/completions` | 200,`content:"READY"`,`device:"CPU"` |
| 流式,`max_completion_tokens` | `/v1/chat/completions` | 200,`text/event-stream`,单个 `[DONE]` 收尾 |
| 流式 + `tools` + `tool_choice:"required"` | `/v1/chat/completions` | 200,收尾正确(工具解析失败见下) |
| 单轮 + `system` + `metadata.user_id` | `/v1/messages` | 200,`content:[{"type":"text",...}]` |
| 流式 | `/v1/messages` | 200,具名事件序列完整 |
| 流式 + `tools` + `tool_choice:{"type":"any"}` | `/v1/messages` | 200,收尾正确 |
| `GET /v1/models` | — | **404**(未实现,如实记录) |

带 `Authorization: Bearer` / `x-api-key` / `anthropic-version` 均正常 ——
因为 Isvik **没有鉴权**,这些头被忽略。这不是「兼容」,是「无认证」,
两者必须区分清楚。

### 4. 一个不是协议缺陷的失败:Gemma 没按信封输出

工具调用请求里模型输出的是:

```json
{"isvik_tool_call": {"path": "src/main.nim"}}
```

信封要求的是 `{"isvik_tool_call": {"name": ..., "arguments": {...}}}`。
少了 `name`,于是 `extractToolCalls` 报 `TOOL_CALL_FAILED`。

这是**提示词方案的固有可靠性问题**,不是协议翻译错误:2B 级模型对信封的
遵从度就是这样。这里刻意**不做**「只声明了一个工具时就把 name 补上」的猜测 ——
那会在多工具场景下把猜错的调用伪装成模型的意图。已知的、可复现的失败
比一个偶然正确的猜测更有价值。

对客户端的实际含义:TRAE 的 Agent 模式依赖稳定的工具循环,当前这个模型
撑不住;普通对话与流式没问题。所以给出的接入建议里,工具轮次要压低,
并且明确说明 Agent 能力**未达到可用**,而不是含糊地说「支持 Tool Calling」。

### 5. 改动与验证

```text
src/isvik/services/inference_service.nim  + defaultDevice 字段/访问器,load 继承空设备
src/isvik/server/http_server.nim          encodeEventStream 增加 terminated 收尾判据
                                          /api/load 的 requestedDevice 回显真实继承值
src/isvik/protocol/openai_chat.nim        更正注释(不再声称等价 AUTO)
src/isvik/protocol/anthropic.nim          同上
tests/server/thttp_server.nim             + 2 个流式收尾回归用例
```

```text
BUILD=0  TEST=0  TAB=0  FAILED=0  WARN=0  FILES=38
```


## 十五、面向 TRAE 的动态 API Key 接入

本轮把 Local API 从「只能靠回环地址保护」补成了一个可直接对接 TRAE 等成品客户端的安全入口。目标不是再写一套 HTTP 服务,而是在现有 `server/http_server` 与三个 Protocol Adapter 上增加一层可管理的凭据校验。

### 1. CLI 与配置

新增专用命令组:

```text
isvik api key create [--name <名称>]
isvik api key list
isvik api key revoke <id>
isvik api serve [--host <地址>] [--port <端口>]
```

`api serve` 强制启用 API Key;旧的 `isvik serve` 为保持兼容仍默认无鉴权,需要显式加 `--require-api-key`。创建命令只显示一次明文 `isvk_...` Key,列表和撤销只显示元数据,不会显示凭据或摘要。

Key 使用 `std/sysrand` 的操作系统随机源生成:Secret 为 32 字节随机值的十六进制表示,ID 为 8 字节随机值的十六进制表示。`<ISVIK_HOME>/config/api_keys.json` 只保存 SHA-256 `digest`、ID、名称、创建时间和撤销时间,不保存明文 Key。写盘采用临时文件替换;服务端每个请求重新读取文件,因此新增和撤销在服务运行期间立即生效,无需重启。摘要比较使用固定时间循环,有效 Key 只接受 active 记录。

### 2. HTTP 鉴权边界

认证在路由分派前执行,所以 `/api/health`、版本、模型、设备、运行时、load/unload、Native、OpenAI 和 Anthropic 路径使用同一套规则。支持:

```text
Authorization: Bearer <key>   OpenAI 常用
x-api-key: <key>              Anthropic 常用
Authorization: <key>          Anthropic 兼容写法
```

缺失、错误或已撤销的 Key 返回 HTTP 401、协议对应的 `authentication_error` / `UNAUTHORIZED`,并带 `WWW-Authenticate: Bearer`。不按 User-Agent、请求内容或「连通性测试」放行,因为 TRAE 的测试请求必须与实际请求使用同一鉴权规则。

### 3. TRAE 配置方式

创建 Key 后 CLI 同时打印两种协议的 Base URL 与完整 URL:

```text
OpenAI Base URL       http://127.0.0.1:7317/v1
OpenAI Full URL       http://127.0.0.1:7317/v1/chat/completions
Anthropic Base URL    http://127.0.0.1:7317
Anthropic Full URL    http://127.0.0.1:7317/v1/messages
```

关闭 TRAE 的「完整 URL」开关时填 Base URL,由客户端追加路径;打开时填完整 URL,不能把两种模式混成 `/v1/v1/messages`。两种格式使用同一个一次性显示的 API Key 和 `isvik list` 输出的模型 ID。`--json` 创建结果也只在当前响应返回明文 `apiKey`,不会泄漏 `digest`。

### 4. 决策与未验证项

- 选择 `isvik api serve` 而不是复制 HTTP 服务实现,保证协议翻译、错误映射、SSE 和推理路径只有一份。
- 选择撤销而不是物理删除,保留创建与撤销元数据,同时通过每请求读取保证撤销立即生效。
- 旧 `isvik serve` 不强制改成鉴权,避免升级后已有本地脚本立即失效;但无鉴权模式不应绑定非回环地址。
- 本节收尾实测结果(2026-08-20):主程序 `nimble build` 返回 0,构建日志无 `Warning:` / `Error:`；`nimble test` 返回 0,共通过 38 个测试文件；`nimble tabcheck` 返回 0,输出「未发现制表符缩进」。最终验收计数为:

```text
BUILD=0
TEST=0
TAB=0
FAILED=0
WARN=0
FILES=38
```

CLI 冒烟确认文本与 JSON 的 Key create/list/revoke 全部成功,JSON 不含 `digest`,磁盘只保存摘要且不含 `isvk_` 明文。HTTP 鉴权矩阵确认无 Key/错误 Key/已撤销 Key 均为 401 并带 `WWW-Authenticate: Bearer`,Bearer 与 `x-api-key` 有效请求成功,OpenAI 与 Anthropic 有效 Key 请求进入模型路由而非被误判为 401,Native `/api/version` 为 200,服务不重启即可识别撤销。

本轮验证还修复了两个真实的 JSON 实现问题:嵌套 `%*` 组装 JsonNode 时生成了错误的数组形状,以及 JSON 数组不能用 `pairs()` 遍历而必须按索引读取。另同步了现有服务启动信息测试:回环无鉴权现在必须明确输出 `WARNING: API key authentication is disabled` 及仅本机可达说明。

## 十六、工作台缺少服务入口

用户在工作台里执行 `-help`,发现命令表里**没有任何开启服务的指令**。这是真实缺口:
上一节把 `isvik api serve` 与 Key 管理做完了,但无参数启动进入的常驻工作台是多数人
实际待着的地方,而它对新增能力一无所知。

### 1. 新增两条命令,复用同一份实现

```text
-serve [--port <n>]           等价 isvik api serve(强制 API Key)
-key create [--name <名称>]   等价 isvik api key create
-key list / -key revoke <id>  等价 isvik api key list / revoke
```

实现是把参数转发给已有的 `runApiCommand`,**不在工作台里另写一套服务或 Key 逻辑**。
理由与上一节选择 `api serve` 复用 `runServeCommand` 相同:协议翻译、错误映射、SSE
与鉴权只应有一份。工作台只负责把一行输入切成 argv。

### 2. 关键决策:服务在前台运行,拒绝后台线程

工作台是个 REPL,直觉上「启动服务后还能继续聊天」才顺手。**但这里不能开线程。**

`server/http_server.serve` 的回调用了 `{.cast(gcsafe).}`,而那个 cast 的成立前提
写在注释里:本服务是单线程 async,§70 的线程模型尚未落地。把 serve 丢到后台线程,
它就与工作台的 `ChatSession` 并发共享 GC 堆 —— 那条断言不再成立,而**症状是偶发的
内存错误,不是明确失败**。用一个「顺手」换一类几乎无法归因的崩溃,不值得。

所以 `-serve` 在前台阻塞,并把三件事如实说清:

```text
服务在前台运行,期间工作台不接受输入。按 Ctrl+C 会同时结束服务与 Isvik 进程;
若要一边聊天一边提供服务,请另开终端运行 `isvik api serve`。
```

刻意不写「Ctrl+C 后返回工作台」:Nim 默认 SIGINT 直接终止进程,写成返回就是伪造。

### 3. 两条主动提示,都是为了避免静默困惑

- **没有 Key 时**:`api serve` 强制鉴权,一个 Key 都没有时服务能起来但**所有请求
  都是 401**。启动前检查 `activeApiKeyCount`,为 0 就提示先 `-key create`,并说明
  也可以在服务运行期间另开终端创建 —— 服务每请求重读 Key 文件,新建立即生效。
  这里**不拒绝启动**:动态 Key 的设计本来就允许边跑边加。
- **已加载模型时**:服务自带独立的 `InferenceService`,会再加载一份模型。4 GB 级
  模型上两份同时驻留不是小事,因此如实提示并建议先 `-stop`,而**不擅自关掉用户
  当前会话**(那会静默丢掉对话历史)。

### 4. 顺带修掉一个输出缺陷:URL 与标签粘连

验证 `-key create` 时看到:

```text
  Anthropic Base URLhttp://127.0.0.1:7317
```

`kvLine` 的默认标签宽度是 18,而 `Anthropic Base URL` 正好 **18** 个字符,填充量为
零,标签与 URL 直接粘在一起。URL 是要被复制进客户端的内容,粘连会让人连不上却看
不出原因。已给这四行显式加宽到 21。

`kvLine` 按字符数而非显示宽度填充(中英文混排不完美对齐)是既有的有意取舍,这里
没有推翻它 —— 只修「粘连」这个会导致复制错内容的部分。

### 5. 验证

工作台内实测(临时配置目录,真实二进制):

```text
-help                     命令表出现 -serve 与 -key,且对齐正常
-key(无参数)              打印用法而不是报错
-key list(空)             如实说明还没有 Key
-key create --name wbtrae  明文只显示一次 + 两种协议的 Base/完整 URL(已不再粘连)
-key list                  显示 key_… / wbtrae / 有效
api_keys.json              只有 digest,不含 isvk_ 明文
-serve --port 7319         打印前台运行说明,随后服务启动日志明确
                           「API key authentication enabled」
```

服务起来后从外部打(服务由工作台启动,未重启):

```text
GET /api/health  无 Key            401  UNAUTHORIZED  www-authenticate: Bearer
GET /api/health  Authorization Bearer 200  {"status":"ok","modelLoaded":false}
GET /api/health  x-api-key 错误值   401  UNAUTHORIZED
```

回归:

```text
BUILD=0  TEST=0  TAB=0  FAILED=0  WARN=0  FILES=38
```

## 十七、Key 变成可取回:一次明确的安全取舍反转

用户的说法是「没有生成 APIkey 和本地存储 key 的功能」。严格讲生成和存储都在,
第十五节就做完了 —— 但**取不回**:磁盘只有 SHA-256 摘要,明文只显示一次。对一个
要反复填进不同客户端的凭据来说,不可取回基本等于没有存储。这个反馈是对的。

同时用户要求「实现和模型一样的调取 key」,即 `list` 给编号、按编号取用。

### 1. 反转第十五节的决策,并说明为什么

第十五节写着「拒绝保存明文 Key,避免配置目录泄露直接暴露凭据」。本轮**反转**这条,
理由不是原来的分析错了,而是当时漏算了使用成本:

```text
只存摘要   配置目录泄露拿不到可用凭据;代价是 Key 不可取回,
           没当场复制就只能撤销重建
存明文     Key 可随时取回;代价是 api_keys.json 泄露等于 Key 泄露
```

选后者的依据是 Isvik 是本地优先工具,该文件与 `settings.json` 同处用户自己的配置
目录;但**「本地」不等于「安全」**,所以这个后果必须出现在文档和 CLI 输出里,而不是
只留在代码注释。创建时的提示已经改成如实说明「可再次取回 + 该文件泄露等于 Key
泄露」,不再写「之后无法恢复」。

**拒绝「加密后存储」。** 解密密钥只能放在同一台机器上,那是混淆而非保护,真正的
危害是它会让人以为泄露没有后果,从而放松对该文件的处理。宁可明确说明明文存储。

**凭据不进日常输出。** 取明文走单独的 `show`,`list` 和**所有** JSON 输出默认不含
凭据 —— `list` 这类「看一眼有哪些 Key」的输出经常被截图或重定向进日志。

### 2. 调取方式与模型对齐

```text
isvik api key list             带 [1] [2] 编号,外加「可取回」列
isvik api key show <编号|标识>  取回明文(别名 get / use)
isvik api key revoke <编号|标识> 撤销也接受编号
```

`parseApiKeySelector` 与工作台选模型的 `parseModelIndex` 行为一致(`1` 与 `[1]`
都认),用户不需要记两套规则。撤销**不删除**记录,所以编号不会因为撤销而整体前移,
昨天记下的 `[2]` 今天仍指同一个 Key。

撤销同时支持编号是顺手补的一致性:能用 `[2]` 取出来却只能用长标识撤销没有道理。

### 3. 两条防「静默失败」的处理

- **加载时校验 `sha256(secret) == digest`,不一致直接报错。** 手改过文件的后果是
  `show` 出来的明文通不过服务端校验,客户端只看到 401 —— 那种问题几乎无法归因到
  「我改过那个文件」。实测手改后报 `INVALID_PARAMETER` 并指明 `field=keys[0]`。
- **v1 记录如实标注取不回。** 存储版本升到 2,但 v1 **仍然可读**(升级 Isvik 不应
  让已经发给客户端的 Key 全部失效)。那些记录没有 `secret`,列表里「可取回」显示
  「否」,`show` 明确说明创建于只存摘要的旧版本、建议撤销重建 —— **不返回空字符串
  让人以为复制到了什么东西**。高于当前版本则拒绝读取:那是降级运行,字段含义未知,
  继续读比报错危险。

另外 `secret` 字段只在真的有明文时写入,不给 v1 迁移来的记录写一个空串冒充
「有明文但是空的」。

### 4. 验证

工作台内(临时配置目录,真实二进制):

```text
-key create --name trae / second   两个 Key,创建提示已改为「可再次取回 + 泄露风险」
-key list                          [1] [2] 编号 + 可取回=是
-key show 1                        取回明文
-key use 2                         别名生效
-key revoke 2                      按编号撤销成功
-key show 2                        仍能取回明文,但明确警告「已撤销,服务端返回 401」
```

存储与 JSON 边界:

```text
api_keys.json      version=2,digest 与 secret 并存
--json api key list  不含 apiKey/secret
--json api key show  含 apiKey + retrievable=true + 接入 URL
```

**取回的 Key 是真凭据**(这是本轮最该验证的一条,不能只看命令有没有报错)。
起 `api serve --port 7321` 后从外部打:

```text
GET /api/health  Bearer <show 取回的 Key>   200  {"status":"ok","modelLoaded":false}
GET /api/health  x-api-key <已撤销的 Key>   401  UNAUTHORIZED
```

兼容与防篡改:

```text
v1 文件      list 正常,可取回=否;show 说明明文取不回并建议重建(退出码 0)
手改的文件   show 报 INVALID_PARAMETER,detail 指出 field 与 id(退出码 2)
```

回归:

```text
BUILD=0  TEST=0  TAB=0  FAILED=0  WARN=0  FILES=38
```

### 5. 仍未做的部分(如实列出)

- **没有对 `api_keys.json` 做文件权限收紧。** Windows 上限制 ACL 需要调用 `icacls`
  这类外部程序,而架构测试禁止 `src` 下启动外部进程(§0.5.4 相关约束),Nim 的
  `setFilePermissions` 在 Windows 上只映射只读位、不解决访问控制。因此当前的保护
  只有「文件位于用户配置目录」这一层,**没有**额外的 ACL 加固,如实标注而不是暗示
  有更强的保护。
- **没有 Key 过期时间与使用次数限制。** 只有 active / revoked 两态。

## 十八、启动时自动补 Key

第十七节做完取回后还剩一步多余动作:`api serve` 强制鉴权,而一个 Key 都没有时服务
**能起来但所有请求都是 401**。上一节的处理只是「提示你去手动 create」——
那是一个能启动却完全不可用的状态,让用户自己撞上再回头执行一条命令没有价值。

现在 `isvik api serve` 在没有任何可用 Key 时**自动生成一个并打印**,一条命令即可用。

### 1. 逻辑住在 `cli/cmd_serve`,不在任何上层入口

三条启动路径最终都走 `runServeCommand`:

```text
isvik api serve                  强制鉴权
isvik serve --require-api-key    等价的旧入口
工作台 -serve                     转发给上面第一条
```

把自动补 Key 放在其中任何一个入口,另外两条都会漏。因此它落在这个汇合点,
工作台里原来那段自己检查 Key 的代码**被删掉** —— 两处各写一遍迟早给出不同结果,
这与第十一节 §2「CPU 回落判据有两份而且不一样」是同一类问题。

顺带把 URL 拼装与打印从 `cli/cmd_api` 下沉到新的 `cli/api_integration`:
`cmd_api` 已经 import `cmd_serve`,反向 import 会成环,而复制一份 URL 拼装到
`cmd_serve` 就会有两份接入参数实现。下沉是唯一不留重复的做法。

### 2. 三条边界,都是为了不产生意外副作用

| 情形 | 行为 | 理由 |
| --- | --- | --- |
| 强制鉴权 + 无可用 Key | 自动生成(名字 `auto-serve`) | 否则服务全 401,等于不可用 |
| 强制鉴权 + 已有可用 Key | **不生成** | 每次启动都堆一个,用户很快分不清哪个在用 |
| 无鉴权的 `isvik serve` | **不生成** | 不需要 Key,凭空写出凭据文件是副作用 |

`--no-auto-key` 可以关闭。关掉后若确实没有 Key,**必须警告**:静默启动一个全 401
的服务比自动补 Key 糟糕得多。

自动生成的名字用固定 ASCII `auto-serve`,**不用**本地化文本 —— 名字会写进
api_keys.json,随界面语言变化会让同一台机器上的记录看起来来源不同。

### 3. 两个顺序细节

- **补 Key 发生在构造服务之前。** 服务端每请求重读 Key 文件,所以晚补也能生效;
  但启动日志里「API key authentication enabled」印出来之后再说「顺便给你造了个
  Key」,读起来因果是反的。
- **Key 文件损坏在这里就报错**,而不是让服务起来后每个请求都 401。

`--json` 模式下这条凭据走 `emitJson` 输出,而不是只印在人读的文本里 ——
脚本化启动时也要能拿到它。

### 4. 验证

全新配置目录直接 `api serve --port 7325`:

```text
启动日志先打印「没有可用的 API Key,已自动生成一个并保存到本地」
+ Key 标识 / 名称 auto-serve / 明文 + 泄露提示 + 接入 URL(端口跟随 --port)
随后才是「API key authentication enabled」
```

自动生成的 Key **确实可用**(这是本轮必须验的一条):

```text
GET /api/health  Bearer <自动生成的 Key>  200  {"status":"ok","modelLoaded":false}
GET /api/health  无 Key                   401  UNAUTHORIZED
```

三条边界逐一实测:

```text
已有 Key 再启动(端口 7326)  启动日志无「已自动生成」,--json key list 仍只有 1 个
--no-auto-key + 空目录       打印警告后照常启动
isvik serve(无鉴权)          config/api_keys.json 不存在,连 config 目录都没建
```

回归:

```text
BUILD=0  TEST=0  TAB=0  FAILED=0  WARN=0  FILES=38
```

### 5. 又踩了自己记过的坑

写边界验证脚本时用了含中文注释的 `.cmd`,cmd 按 GBK 读坏,报出
`'绔彛涓嶅悓)' 不是内部或外部命令` 这种与真实内容毫无关系的错误。
第七节「本地终端环境」早就写着「批处理里只放 ASCII」。改成纯 ASCII 注释后一次通过。

记录这件事本身:**已经写进 DEVLOG 的坑仍然会被再踩一次**,说明那条经验在动手写
脚本时不够显眼 —— 它在第七节的一长串列表里,而不是在写脚本的当下。

## 十九、别再每次都编译一遍注定失败的 NPU

用户反馈:每次启动都先去编译 NPU,然后刷出一屏

```text
[ERROR] [IE::FrontEnd::importNetwork] Upper bounds are not specified for node
        '...input_layernorm/aten::pow/Power': input '0' bounds are
        '[9223372036854775807, 9223372036854775807, 1536]'
[ERROR] [vpux-compiler] Got non broadcastable dimensions pair : ...
```

这不是新缺陷:第六节 6.1 第 4 条早就记着「NPU 要求静态 shape」,第九点七节也记过
本管线在 NPU 上编译失败的实证。**真正的缺陷是每次都重来一遍。**
`default_device` 是 AUTO,AUTO 顺序为 NPU → Intel GPU → CPU,于是每次加载都要
先白等一次注定失败的 NPU 编译。

### 1. 设施早就建好了,只是没有接线

`ModelManifest.deviceSupport` 是一等字段,`storage.recordDeviceVerification` 是
「唯一可以把 verified 置为 true 的入口」,`manager.checkEligibility` 还留着
`esUnknown` 并注释「由调用方决定是要试一把还是先要求用户补清单」。

**但没有任何代码调用它们。** 这与第十一节 §1「统一请求此前没有执行者」是同一类
问题:设计做完了,执行者没接上。本轮就是接线。

### 2. 排除集作为**数据**传给 Core,顺序仍只有一份

AUTO 的候选顺序在 `core/device_manager`,而「该模型在某设备上编译失败过」这个知识
在 Model Manifest 里 —— Core 不得依赖上层。

做法:`resolveDevice(manager, requested, excluded: seq[string])`。Core 不关心排除的
**理由**,只接受调用方给的语义设备名集合。于是 NPU→GPU→CPU 这个顺序**仍然只有
Core 这一份实现**,服务层不必再写一遍。

拒绝的替代方案:在 `inference_service` 里自己按 NPU→GPU→CPU 循环。那会让顺序有两份,
正是第十一节 §2「CPU 回落判据有两份而且不一样」那个坑。

两条边界:

- **排除只作用于 AUTO。** 显式 `--device NPU` 一律照请求去试:用户明确指定了,就该
  看到该设备真实的成败,而不是被一条历史记录挡住。
- **被跳过的设备仍出现在 attempts 里**(`status=excluded`,`reason=excluded-by-caller`)。
  让它从决策过程里消失会使结果看起来像「Isvik 从未考虑过 NPU」。

### 3. 结论必须会**失效**,否则升级驱动后永远看不到改善

「NPU 编译不了」只对当次的 Backend / 驱动版本成立。一条永不失效的记录会让用户升级
OpenVINO 或 NPU 驱动之后仍然被跳过,还以为是 Isvik 不支持。

因此结论里嵌入 Backend 版本:

```text
note = "Model compilation failed [backend=openvino/2026.3.0-22451-...]"
```

读取时比对当前版本,不匹配就**重试一次**。没有标记的旧记录同样视为不匹配 ——
宁可多花一次编译,也不要因为一条来源不明的记录永久跳过某个设备。

刻意**没有**为此新增 manifest 字段:`note` 本来就是「为什么」的位置,而加字段要动
schema、序列化与校验三处;格式固定,解析只有一处。

### 4. 记录的是**具体**设备,不是 AUTO

失败时从错误 detail 里取 `device=`,而不是照抄用户请求的 `AUTO` —— 记录
「AUTO 编译失败」对下一次决策毫无用处。`GPU.0` 会归一成语义设备 `GPU`,因为
manifest 只记 CPU / GPU / NPU(`SemanticDeviceNames` 刻意不含 AUTO)。

回落判据仍看**原始请求**:上一步可能已经把 AUTO 具体化成了 NPU,若拿具体化后的
设备去问 `allowsCpuFallback`,AUTO 的回落资格会被自己的优化弄丢。

记录失败本身被 try 包住:写 manifest 失败不该让一次本来能回落成功的加载变成错误。

### 5. 意外收获:用户此前从未真正用上 iGPU

真机两轮实测(用户的 Gemma 4 E2B,`default_device=AUTO`):

```text
第一轮  试 NPU → 失败(那一屏 ERROR)→ 回落 CPU → 200,device=CPU
        manifest 写入 NPU / supported=false / verified=true / note 带 backend 版本
第二轮  日志里**不再出现** NPU 错误
        AUTO 跳过 NPU → 选中 GPU.0 → 编译成功 → 200,device=GPU.0
```

第二轮跑在 **GPU.0(Intel iGPU)** 上,而不是 CPU。

原因是旧的回落只有一级:`allowsCpuFallback` 让 NPU 失败后**直接跳到 CPU**,
把 AUTO 候选里的 Intel GPU 整个跳过了。也就是说在此之前,这台机器上的 iGPU
从未被真正尝试过 —— 用户一直在用 CPU,却以为 AUTO 已经挑过最好的设备。

这条值得单独记:**一个「省事」的回落捷径会让某个设备永久得不到验证机会**,
而症状只是「有点慢」,不会报错。

### 6. 验证

```text
BUILD=0  TEST=0  TAB=0  FAILED=0  WARN=0  FILES=38
```

Core 的签名改动用默认参数,现有调用与 `tdevice_manager` / `truntime` /
`tdevice_service` 的既有断言全部不受影响。

### 7. 仍未做(如实列出)

- **没有抑制 OpenVINO 自己打印的 ERROR。** 第一次仍会看到那一屏。抑制它需要调
  OpenVINO 的日志级别,而那会同时压掉真正需要看到的诊断;当前选择是让它只出现一次。
- **GPU 首次编译很慢**(本次实测约一分钟量级)。Task 16 的 compiled cache 应该能
  改善后续启动,但本轮**没有**测量缓存命中后的时间,不做宣称。
- **没有为这条路径新增测试。** 用户明确要求不自动加测试;它依赖真实 NPU 编译失败,
  在没有 NPU 的机器上无法复现,属于第 3 档(需要真机)的用例。

## 二十、`Inference execution failed (4028)` 与一个更根本的问题:现场不留证据

用户在 TRAE 的 Agent 模式里看到 `Inference execution failed (4028)`。
前半句正是 Isvik `INFERENCE_FAILED` 的默认消息(`errors.nim`),所以那确实是服务端
返回的错误,不是客户端自己编的。

### 1. 复现尝试:全部成功,没能复现

按 Agent 的真实请求形状逐条打(用户的 Gemma 4 E2B,`default_device=AUTO`,
此时实际跑在 `GPU.0`):

```text
带 tools 的单轮(348 token)        200  finish_reason=tool_calls
工具循环第二轮(回传 tool 结果)    200  正确总结,闭环
流式 stream:true                   200  事件序列完整,单个 [DONE]
长上下文(1234 token)              200  正常回答
三个请求并发                       200 / 200 / 200(串行处理,无交错)
```

**一条都没失败。** 因此当前掌握的证据不足以指认根因 —— 不做猜测性的「修复」。

### 2. 真正该先修的:`logging` 配置是**声明了却没有执行者**

排查到一半发现 `<ISVIK_HOME>/logs` 是**空目录**。查下去:

```text
logging/logger.nim   Logger / ConsoleSink / FileSink / MemorySink 都写好了
logging/event_log.nim bridgeEventsToLogger 也写好了
生产代码引用          只有 settings.nim 为了 LogLevel 这个**类型**
```

也就是说 `settings.json` 里的 `logging.level` / `logging.console` / `logging.file`
**三项全部没有效果**,而用户看到配置里写着 `"file": true`,合理地以为有日志可查。

这与第十一节 §1(统一请求没有执行者)、第十三节(response_format 没被解析)、
第十九节(device_support 没人写)是**同一类问题的第四次出现**:设施建好、配置暴露、
但没接线。

**它的直接后果就是本轮的困境:** 服务端在 `handleRequest` 的 `except` 里把
IsvikError 翻译成响应就结束了,而响应体按安全边界只带 `code` + `message`
(detail 可能含绝对路径)。于是 `detail` —— 唯一能区分
「`operation=ovOpInfer` 推理失败」和「全部 token 被屏蔽」的信息 —— 在那里被彻底
丢弃。客户端只显示一句 `Inference execution failed`,谁也不知道为什么。

### 3. 改动

- `handleRequest` 的两个 `except` 分支记录 `e.logLine()`(**含 detail**),
  并带上方法与路径。`logLine()` 本来就是为此存在的(第 Task 2 的安全边界设计:
  detail 只进日志,不进响应)。
- `cmd_serve` 按 `settings.logging` 建 Logger:`file` 为真时写
  `<ISVIK_HOME>/logs/server.log`,`console` 控制是否同时打屏。
- 日志开不起来时**明说一句**警告后继续启动 —— 服务不该因为日志失败而起不来,
  但也不能假装它在记。

**错误单独走 `error` 级别。** 一开始图省事全用 `log.info`,随即意识到那是个坑:
用户把 `logging.level` 收紧到 `ERROR` 时,错误会和启动信息一起被过滤掉 ——
而那正是最需要留下记录的时候。因此 `ApiServer` 增加可选的 `errorLogger`
(nil 时回落到 `log`,现有调用与 `thttp_server` 的断言不受影响)。

### 4. 验证

```text
清空 logs/ → 起服务 → 发一个必然失败的请求(不存在的模型)

C:\Users\WANG\.isvik\logs\server.log:
2026-08-21T03:53:41.729Z [INFO ] Isvik Local API  http://127.0.0.1:7353
...
2026-08-21T03:54:20.399Z [ERROR] POST /v1/chat/completions ->
  MODEL_NOT_FOUND: Neither an imported model id nor an existing directory
  | detail: requested=no-such-model-xyz
```

`[ERROR]` 级别 + **detail 在里面**。下次 4028 再发生,日志里会有
`INFERENCE_FAILED: ... | detail: operation=... reason=...`,那才是能定位的东西。

```text
BUILD=0  TEST=0  TAB=0  FAILED=0  WARN=0  FILES=38
```

### 5. 关于第十九节改动的风险,如实记下

第十九节让 AUTO 跳过 NPU,结果本机落到了 `GPU.0` —— 而 **GPU 上的文本生成此前
从未被验证过**(第九点六节 §11 明确列为未验证)。也就是说那次改动把用户从
「已验证的 CPU」推到了「未验证的 GPU」。本轮的 5 组请求在 GPU 上全部成功,
但这**不等于** GPU 路径已被充分验证。

同时发现一个尚未闭合的缺口:**只有编译失败会被记录到 `device_support`,推理失败
不会。** 如果某个设备编译得过但推理在特定输入上失败,AUTO 会一直选它并反复失败。

**没有**顺手把「推理失败」也记成设备不支持,理由是证据不足:推理失败可能与设备
无关(例如 sampling 的「全部 token 被屏蔽」是输入问题)。凭一次失败就写下
「该设备不支持」是伪造结论,比不记录更糟。正确顺序是先有日志(本轮已做),
拿到真实 detail 再决定。

**给用户的即时规避**:把 `settings.json` 的 `default_device` 设为 `"CPU"` 就能回到
唯一被充分验证的路径;或者删掉该模型 manifest 里的 `device_support` 记录,让 AUTO
恢复原来的行为。

### 6. 又踩了一次同一个坑

构建时 `ld.exe: cannot open output file D:\nim\Isvik\isvik.exe: Permission denied`。
原因是停掉 Kiro 终端后 `isvik.exe` 还没退出。第九节早就记过这条。
教训与第十八节 §5 相同:**写进 DEVLOG 不等于不会再犯**,因为它不在动手的那一刻可见。

## 二十一、上一节的日志修复漏了流式路径

用户重现了 `Inference execution failed (4028)`,而 `logs/server.log` 里**一条相关记录
都没有**。第二十节刚接上的日志没有覆盖到它。

### 1. 漏在哪

第二十节把记录点放在 `handleRequest` 的 `except`。但流式请求的错误**到不了那里**:

```text
inference_service.execute   emit(inferenceErrorFrom(e)) 然后 raise e
        ↓
encodeEventStream 的 except  捕获后**不再抛出**(为了保留已产出的增量)
        ↓
HTTP 状态仍是 200,错误只作为流内 error 事件送出
        ↓
handleRequest 的 except      根本不会进
```

Agent 模式用的正是流式,所以它恰好落在唯一没被覆盖的那条路上。

雪上加霜的是:流内的 error 事件由 `inferenceErrorFrom` 构造,而它按安全边界
**不携带 detail**(Task 2 的设计:detail 只进日志不进响应)。于是「失败的具体原因」
在客户端和日志里**同时**消失,只剩一句 `Inference execution failed` ——
这正是用户看到的。

### 2. 修法

`encodeEventStream` 的 `except` 里 `e` 还是**完整的 IsvikError**,detail 仍在。
在那里记录 `e.logLine()`,并带上协议名与模型。

一个必须想清楚的细节:**无论流是否已经自行收尾都要记。** 那个 `terminated` 标志
控制的是「要不要再补一帧给客户端」,与「要不要留下记录」是两件事。最常见的失败形态
恰好是 `execute` 内部失败(已经 emit 过终止事件,`terminated` 为真)——
如果沿用同一个条件,那一类错误会继续一条都不留。

非流式路径不需要改:`runInference` 没有自己的 catch,错误照常冒泡到
`handleRequest`,第二十节已经覆盖。

### 3. 验证

构造一次真实的流式失败(`stream: true` + `tool_choice: required`,而模型没有按信封
输出 —— 第十四节 §4 记过这个可靠性问题):

```text
HTTP 200(流式失败仍是 200,错误在流内)

logs/server.log:
2026-08-21T04:11:53.772Z [ERROR] stream openai-chat model=gemma-4-e2b-it-int4-ov
  -> TOOL_CALL_FAILED: The model did not call a tool although tool_choice
  required one | detail: toolChoice=required
```

这条记录在修复前**完全不存在**。

```text
BUILD=0  TEST=0  TAB=0  FAILED=0  WARN=0  FILES=38
```

### 4. 教训:「已修好」的判断需要覆盖所有出口

第二十节我验证日志时用的是**非流式**的失败请求(不存在的模型),它确实写进了日志,
于是我判定日志接线完成。但那条请求走的是两条出口中的一条。

**错误出口有几条,就要各验一条。** 这次的出口是「被内部 catch 转成流内事件、
HTTP 仍 200」——它在形态上与「返回错误响应」完全不同,不会被同一个测试覆盖到。

## 二十二、4028 的真正根因:iGPU 的 4 GiB 单次分配上限

第二十一节把日志补上之后,用户重现一次就拿到了确切原因:

```text
stream anthropic model=gemma-4-e2b-it-int4-ov -> INFERENCE_FAILED:
  Inference execution failed | detail: operation=infer
  ovStatus=GENERAL_ERROR(-1) ... ovMessage=Run inference failed with status -1
  | OpenVINO: Check '!exceed_allocatable_mem_size' failed at
  intel_gpu\src\runtime\engine.cpp:322: [GPU] Exceeded max size of memory
  object allocation: requested 7549747200 bytes, but max alloc size supported
  by device is 4294959104 bytes.
```

算一下就清楚了:

```text
7549747200 / 4 (F32) / 262144 (vocab) = 7200
```

那是 logits `[1, 7200, 262144]` = **7.03 GiB 的单个张量**,而 iGPU 的单次内存对象
上限是 **4 GiB(2^32 - 8192)**。Agent 模式的上下文长到 7200 token,prefill 一次性
产出整个序列的 logits,于是必然越界。CPU 没有这个单对象上限(本机 47 GB 内存),
所以在 CPU 上一直好用。

**这是第十九节改动的直接回归**:让 AUTO 跳过 NPU 之后,本机落到了 GPU.0,
而 GPU 上的长上下文从未被验证过。短请求(实测 348 / 446 / 1234 token)都能跑,
所以第十九节的验证没有暴露它 —— 上下文长度是这个失败的第二个必要条件。

### 1. 把「设备容量上界」与「普通推理失败」区分开

第二十节末尾我拒绝过「推理失败就记为设备不支持」,理由是证据不足:
全部 token 被屏蔽之类的失败与设备无关,凭一次失败写下结论是伪造。

**这一条不同。** 错误里明确写着 `max alloc size supported by device`,那是设备
能力的硬上界,与输入长度一起构成确定性失败。所以新增 `isDeviceCapacityFailure`
只识别这一类(分配越界 / 设备内存不足),其余推理失败照旧不做设备判定。

### 2. 当次请求就地救回,不只是记录

```text
识别为容量失败 + 原始请求是 AUTO + 还没产出任何 token + 当前不是 CPU
  → 记录该设备容量不足 → 强制换 CPU 重新编译 → 重跑
```

三个前提缺一不可:

- **原始请求是 AUTO。** 显式 `--device GPU` 就该看到 GPU 真实的失败。
- **还没产出 token。** 这个错误发生在 prefill,通常一个 token 都没发出;
  若已经流式送出了内容,换设备重跑会让客户端看到重复文本。用 `produced` 标志
  盯住这一点。
- **当前不是 CPU。** 已经在 CPU 上失败就没有下一级可退。

`note` 写成 `Inference exceeded this device's allocation limit: ...`,而不是笼统的
「不支持」—— 短请求在 GPU 上其实跑得动,是长上下文越界。但对 AUTO 来说结论仍然是
「别选它」:一个「短的能跑、长的崩」的设备无法可靠服务,而用户没法预先知道哪个请求
会越界。

### 3. 顺手修掉自己引入的一个开销

第十九节写了 `backendIdentity()` 与 `effectiveAutoDevice()` 两个函数,**各自
`openDeviceService()`** —— 一次 load 因此要初始化三个 OpenVINO Core(两个只为查询,
一个真正编译)。合并为 `planAutoDevice()`,只开一个。

不只是慢:同一进程里并存多个 Core 会各自持有设备上下文,在 GPU 上没有必要冒这个险。

### 4. 验证(硬证据)

```text
构建                     i-build.rc=0,日志无 Warning / Error

manifest 写入(实测)     "device": "GPU", "supported": false, "verified": true,
                         "note": "Inference exceeded this device's allocation
                                  limit: ... [backend=openvino/2026.3.0-...]"

7200+ token 流式请求     200,内容 "READY"
                         —— 修复前这个请求就是用户看到的 4028

之后的短请求(干净单跑)  9.04 秒(12:44:31 → 12:44:40),200,
                         "isvik":{"device":"CPU"}
                         —— AUTO 现在既不试 NPU 也不试 GPU
```

### 5. 回归(补跑完成)

全量测试当时**没能跑完**:反复尝试后后台终端不再产出任何输出,连 `nimble test` 的
日志文件都不再生成(第七节记过这类环境不可靠,那是最严重的一次)。当时如实标注为
未完成,**没有**写 `TEST=0` —— 没跑就不能声称通过。

环境恢复后补跑,结果:

```text
BUILD=0  TEST=0  TAB=0  FAILED=0  WARN=0  FILES=38
```

顺带一条旁证:修复上线后的服务端日志里**不再出现** `INFERENCE_FAILED`,
最后两条 GPU 容量失败的时间戳都早于修复后的构建。

### 6. 仍未解决的根本问题

**prefill 会为整个序列产出 logits,而解码只需要最后一个位置。** 7200 token 的请求
因此要分配 7 GiB,在任何设备上都是浪费,只是 CPU 容得下。真正的解法是分块 prefill
或让模型只输出最后位置的 logits,那需要改推理编排(§20 之外的工作),**本轮没有做**。

也就是说:GPU 现在被正确地避开了,但「长上下文的 logits 占用」这个浪费依然存在。
