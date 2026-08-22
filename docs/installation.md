# Isvik 依赖清单与安装指引

**最后更新**:2026-08-20
**适用范围**:完成 Task 9 到 Task 19 所需的全部外部依赖。

本文档的所有「已装 / 未装 / 可达 / 不可达」都是**本机实测结果**,不是推断。
实测方法与原始数据见 `DEVLOG.md` 第五节。

---

## 一、结论先说

**绝大部分东西已经就绪,需要你动手的只有一项:模型。**

| 类别 | 状态 |
| --- | --- |
| 编译工具链(Nim / gcc / nimble) | 已就绪,无需操作 |
| git / git-lfs | 已就绪,无需操作 |
| 下载与解压工具(curl / tar) | Windows 自带,无需操作 |
| Intel NPU / GPU 驱动 | 已就绪且**版本高于官方要求**,无需升级 |
| OpenVINO Runtime + Tokenizers 扩展 | **已自动完成**(见第三节) |
| Python(可选的模型转换工具) | 已装 3.14.7 |
| **LLM 模型** | **缺,且需要你先做一个选择** |

---

## 二、已验证就绪的部分(不需要你做任何事)

### 编译工具链

| 组件 | 实测版本 | 说明 |
| --- | --- | --- |
| Nim | 2.2.10 (Windows amd64) | |
| nimble | 0.22.2 | |
| gcc | TDM-GCC 10.3.0 | **必须是 gcc,不能换 vcc**,原因见 README |
| git | 2.55.0.windows.4 | 位于系统级 PATH |
| git-lfs | 3.7.1 | 随 git 一起安装,不需要单独装 |
| curl | Windows 自带 | |
| tar | Windows 自带,能解 zip | |
| Python | 3.14.7 | 仅在选择方案 B 时才需要 |

`nimble test` 已验证在不额外注入 PATH 的情况下直接可跑:**OK=527 FAILED=0**。

### 硬件驱动

| 设备 | 驱动版本(实测) | 要求 | 结论 |
| --- | --- | --- | --- |
| Intel(R) AI Boost(NPU) | **32.0.100.4841** | OpenVINO 文档要求 ≥ 32.0.100.3104 | **已满足,不用升级** |
| Intel(R) Graphics | 32.0.101.8864 | 无明确要求 | 可用 |
| NVIDIA GeForce RTX 5080 | 32.0.16.1088 | 不在 Isvik 目标范围 | 见下方说明 |

内存 47.4 GB、D 盘剩余 1862 GB,均充裕。
(OpenVINO 文档提到:7B 以上模型处理超过 1024 token 的提示可能需要 16 GB 以上内存。)

> **关于 `GPU.1` 是 NVIDIA**:OpenVINO 会把 NVIDIA 独显也枚举成 `GPU.1`。
> Isvik 面向 Intel 硬件,Task 10 的 AUTO 策略必须按 vendor 区分,不能把
> `GPU` 当单一设备。该设备上的编译与推理**尚未测试**。

### 网络可达性(直接决定依赖能不能拿到)

| 站点 | 实测 | 影响 |
| --- | --- | --- |
| `storage.openvinotoolkit.org` | **HTTP 200** | OpenVINO 官方 archive 可下 |
| `github.com` | HTTP 200 | 可用 |
| `www.modelscope.cn` | HTTP 302 | 可下模型,但只有原始格式 |
| `pypi.tuna.tsinghua.edu.cn` | HTTP 200 | pip 可用,需显式指定镜像 |
| `huggingface.co` | **HTTP 000** | **预转换的 OpenVINO IR 拿不到** |
| `hf-mirror.com` | **HTTP 000** | 常见镜像同样不可用 |
| `pypi.org` | HTTP 000 | 必须走镜像 |

`000` 表示 TCP/TLS 连接层面失败,不是 404。

---

## 三、OpenVINO Runtime + Tokenizers(已自动完成)

一条命令即可,已经执行过:

```powershell
.\scripts\fetch-deps.ps1 -What Runtime
```

它做的事:

1. 下载 `openvino_genai_windows_2026.3.0.0_x86_64.zip`(220.2 MB)
2. 解压,把其中的 Release DLL 复制到 `runtime\openvino\`
3. 校验 `openvino_tokenizers.dll` 确实到位

**为什么用 GenAI 包而不是普通 Runtime 包**:官方文档明确说明 GenAI archive
「包含 OpenVINO Runtime 以及 Tokenizers」。一个包同时解决两件事:

- 把 DLL 来源换成**官方 archive**,不再是从 pip 包间接得到(那样「获取 DLL」
  这一步隐含 Python 依赖,与项目目标冲突)。
- 补上 `openvino_tokenizers.dll`。这个扩展是加载模型仓库里
  `openvino_tokenizer.xml` / `openvino_detokenizer.xml` 的**前提** ——
  没有它,「文本 → token id」这一段就无从实现。

**版本一致性**:archive 的 build 号 `2026.3.0.22451` 与替换前实测的
`2026.3.0-22451` 完全相同,所以这次替换不引起版本漂移。替换后两套测试复验:

| 测试 | 结果 |
| --- | --- |
| Resonance(真实调用 OpenVINO) | OK=21 FAILED=0 SKIPPED=2 |
| Isvik 全量 | OK=527 FAILED=0 SKIPPED=1 WARNINGS=0 |

与替换前完全一致。

当前 `runtime\openvino\` 有 25 个 DLL,205 MB,其中 3 个是本次新增的
`openvino_tokenizers.dll` / `openvino_genai.dll` / `openvino_genai_c.dll`。

> 包里的 TBB 把 `tbb12_debug.dll` 这类调试版直接放在 Release 目录下。
> 脚本已按文件名后缀过滤,它们不会进入 `runtime\openvino\`。

---

## 四、模型:需要你先做一个选择

这是唯一还缺的东西,也是唯一需要决策的地方。

### 问题在哪

OpenVINO 官方把**预转换好的 IR 模型**只发布在 HuggingFace 的 `OpenVINO/`
组织下。这些仓库的构成非常理想 —— 以 `OpenVINO/Qwen2.5-1.5B-Instruct-int4-ov`
为例,它同时包含:

```text
openvino_model.xml / .bin          LLM 本体(INT4 量化)
openvino_tokenizer.xml / .bin      分词器,本身就是 OpenVINO IR
openvino_detokenizer.xml / .bin    反分词器,同样是 IR
tokenizer.json / vocab.json / merges.txt
config.json / generation_config.json / tokenizer_config.json
```

**分词器本身就是 IR 意味着分词可以用 OpenVINO 推理来做,不需要在 Nim 里
手写 BPE。** 这是一个很大的省力点。

但 `huggingface.co` 从本机不可达(实测 HTTP 000),`hf-mirror.com` 也一样。
所以这批现成的东西暂时拿不到。

### 三条路径,请选一条

#### [A] 让本机能访问 huggingface.co(推荐)

**代价**:配置代理。
**收益**:最省事。官方 IR 直接可用,不需要任何模型转换,不需要 Python,
分词器也是现成的 IR。

配好之后跑:

```powershell
.\scripts\fetch-deps.ps1 -What Model -TryHuggingFace
```

可选的模型:

| 标识 | 仓库 | 体积 | 结构 | 许可 |
| --- | --- | ---: | --- | --- |
| `small` | `OpenVINO/Qwen2.5-1.5B-Instruct-int4-ov` | 886 MB | 单 IR | Apache-2.0 |
| `npu` | `OpenVINO/Phi-3.5-mini-instruct-int4-cw-ov` | 1.9 GB | 单 IR,channel-wise | MIT |
| `npu-big` | `OpenVINO/Qwen3-8B-int4-cw-ov` | 8.8 GB | 单 IR,channel-wise | Apache-2.0 |
| `gemma4-e2b` | `OpenVINO/gemma-4-E2B-it-int4-ov` | 4.1 GB | **5 个 IR,多模态** | Apache-2.0 |
| `gemma4-e4b` | `OpenVINO/gemma-4-E4B-it-int4-ov` | 6.1 GB | **5 个 IR,多模态** | Apache-2.0 |

默认(`both`)下载 `small` + `npu`。指定单个用 `-Model <标识>`。

**为什么 NPU 要单独一个模型**:OpenVINO 文档规定 NPU 上的 LLM 必须是
对称量化(`--sym`)+ INT4/NF4 + `--group-size -1`(channel-wise)或 `128`,
且 `--ratio 1.0`。官方为此单独维护带 `-cw-`(channel-wise)后缀的仓库。
普通的 `-int4-ov` 是 group-wise,**不保证能上 NPU**。

Gemma 4 的详细情况见第 4.1 节。

#### [B] 从 ModelScope 下原始模型,自己转成 IR

**代价**:装 Python 工具链,自己跑一次转换,耗时较长(7B 级模型的 INT4
量化在 CPU 上可能要几十分钟)。
**收益**:不依赖 HuggingFace。

ModelScope 实测可达,`Qwen/Qwen2.5-1.5B-Instruct` 存在,但**只有
`model.safetensors`(3.08 GB 原始精度),没有 OpenVINO IR**,必须自己转。

合规性:规范 §0.5.4 禁止 Python 成为 Isvik 的**运行时**依赖,但明确允许
「构建辅助工具或开发工具」,只要「与正式 Runtime 解耦,且不得成为用户运行
Isvik 的必要条件」。一次性的模型转换属于这一类,**合规**。

大致步骤(pypi.org 不可达,必须指定镜像):

```powershell
python -m venv D:\nim\Isvik\build\convert-env
D:\nim\Isvik\build\convert-env\Scripts\activate

pip install -i https://pypi.tuna.tsinghua.edu.cn/simple `
    nncf onnx optimum-intel transformers `
    openvino openvino-tokenizers

# 从 ModelScope 取原始模型
pip install -i https://pypi.tuna.tsinghua.edu.cn/simple modelscope
modelscope download --model Qwen/Qwen2.5-1.5B-Instruct --local_dir .\qwen-src

# 转成 IR。给 NPU 用时必须按 NPU 的量化要求传参:
optimum-cli export openvino -m .\qwen-src `
    --weight-format int4 --sym --ratio 1.0 --group-size -1 `
    .\runtime\models\Qwen2.5-1.5B-Instruct-int4-cw-ov
```

**两个尚未验证的风险,如实说明**:

1. **Python 3.14.7 可能太新。** OpenVINO 官方给的组合是
   `nncf==2.18.0 / onnx==1.18.0 / optimum-intel==1.25.2 / transformers==5.0.0`。
   这些包(尤其是它们依赖的 torch)在 3.14 上是否有可用的 wheel **我没有实测**。
   如果装不上,需要额外装一个 Python 3.12 专门做转换。
2. **`--group-size -1` 的写法容易出错。** 官方文档特别强调是 `-1`(负一)
   而不是 `1`。写错会得到一个能编译但不满足 NPU 要求的模型。

#### [C] 暂不引入 LLM,先用本机已有的 ONNX 推进

**代价**:`isvik run` 的文本生成和 Task 18 的 `Tokens/sec` 做不了。
**收益**:零下载,立刻能继续。

`C:\nim\NimVoice\models\` 下有大量可用的 ONNX 模型(SpeechT5、HiFi-GAN、
VITS、Piper 等),足以验证:

- Task 8 收尾:`compileModelWithProperties` 传 2 个和 4 个属性的多属性编译路径
- Task 9:OpenVINO Backend 骨架
- Task 15 的一部分:「读模型 → 编译 → 推理」链路本身
- Task 16:blob 缓存的导出与导入(该目录下已有现成的 `.blob` 可作参照)

做不了的:任何需要 tokenizer 与自回归文本生成的部分。

---

## 4.1 Gemma 4 专节

Gemma 4 可用,官方 IR 是现成的,许可也很干净。但它比单 IR 的纯文本模型多出
若干工作量,这些必须在动手前知道,而不是跑不通了再回头查。

### 可选变体(全部 Apache-2.0、非 gated)

| 变体 | int4 体积 | 设备支持 | 备注 |
| --- | ---: | --- | --- |
| **E2B** | **4.06 GB** | CPU / GPU | **推荐起步**,官方仓库下载量最高 |
| E4B | 6.01 GB | CPU / GPU | 能力更强 |
| 26B-A4B | — | **仅 GPU** | MoE(26B 总参 / 4B 激活);长提示有精度问题 |
| 31B | — | **仅 GPU** | Dense;输入含图像时有精度问题 |

「仅 GPU」是 OpenVINO 发布说明的原文分类(2026.2 新增支持时明确写为
`Only on GPUs: Gemma 4 31B and Gemma 4 26B-A4B`)。

**许可**:Gemma 4 是 Gemma 系列首次采用 **Apache-2.0**(Gemma 2 / Gemma 3 都是
`license:gemma` 的自定义条款)。HuggingFace 上 `OpenVINO/gemma-4-*` 仓库标注为
`license:apache-2.0` 且 `gated: false`。**正式采用前请以模型卡原文为准**,
本文档只如实记录仓库元数据。

**关于 E2B / E4B 的命名**:E 是 effective(等效)。Gemma 4 的小尺寸模型采用
Per-Layer Embeddings(PLE)架构,继承自 Gemma 3n 的 MatFormer 思路 ——
实际权重远大于名字暗示的规模。可以直接对比:

| | 实测体积 |
| --- | ---: |
| `google/gemma-4-E2B-it` 原始权重(ModelScope 实测) | **9.54 GB** |
| `OpenVINO/gemma-4-E2B-it-int4-ov` 量化后 IR | 4.06 GB |

所以「E2B」不等于「2B 参数的小模型」,内存与编译时间要按 4 GB 级的 IR 估算。

### 它由 5 个 IR 组成

这是与单 IR 模型最根本的区别:

```text
openvino_language_model.xml / .bin                 语言模型主体
openvino_text_embeddings_model.xml / .bin          文本嵌入
openvino_text_embeddings_per_layer_model.xml/.bin  逐层嵌入(PLE)
openvino_vision_embeddings_model.xml / .bin        视觉嵌入
openvino_tokenizer / openvino_detokenizer          分词 / 反分词
```

**推理时需要自行编排这些模型之间的数据流**,其中 PLE 要求在每个解码层注入
一个额外的低维条件信号。这套编排在 OpenVINO GenAI 的 `VLMPipeline` 里是现成的,
Isvik 要 100% Nim 自己实现推理编排,就必须自己写。编排错了不会报错,只会输出垃圾 ——
属于最难排查的一类问题。

对比 `small`(Qwen2.5-1.5B):单个 `openvino_model.xml` + tokenizer,两个 IR。

### 四项额外工作(依据 OpenVINO 2026.3 发布说明的已知问题)

**1. chat template 无法被标准模板引擎解析。**
已知问题 **ID 191107**:Gemma 4 更新后的 chat template 无法被 Minja 解析
(Minja 是 OpenVINO GenAI 自带的 C++ Jinja 引擎),原因是 Minja 不支持相邻
字面量字符串拼接语法。官方给出的变通办法是手动把旧版 chat template 设回
pipeline。

这个模板的实测规模:**18.5 KB Jinja**(ModelScope 上 `chat_template.jinja` 的
实际文件大小),内含递归 macro、namespace 状态机、tool calling 的自定义格式、
thinking channel 处理。

**对 Isvik 的含义**:Nim 里没有 Jinja 引擎。连 OpenVINO 官方的 C++ 引擎都解析
不了这个模板,在 Nim 里正确实现它不现实。可行的做法只有两种 —— 用固定的 prompt
拼接覆盖常用对话形态,或者改用旧版模板。**无论哪种都要在文档里说清楚
「Isvik 对 Gemma 4 的 chat template 支持是有限的」,不能让用户以为完全兼容。**

**2. 必须显式设置 KV cache group size = 64。**
已知问题 **ID 186412**:Gemma 4 的 INT8 / INT4 权重压缩模型需要显式把 KV cache
group size 设为 64 才能保持精度。漏掉不会报错,只会精度下降 —— 又是一个静默
失败路径。Isvik 编译 Gemma 4 时必须传这个属性。

**3. NPU 支持没有官方声明。**
发布说明中 Gemma 4 只涉及 CPU / GPU 与 GenAI 的 SDPA 后端,**NPU 一个字没提**。
同时 NPU 插件的更新记录里有「增强了此前导致若干 VLM 编译失败的分区稳定性」,
说明 VLM 在 NPU 上历来不稳。
结论:**Gemma 4 上 NPU 属于未验证事项**,不得假定可用。如果 NPU 是重点目标,
应另外准备一个带 `-cw-` 后缀的单 IR 模型(如 `npu` 标识那个)。

**4. 已记录的精度问题。**
**ID 187019**:Gemma 4 模型在某些平台上精度偏低。
**ID 187785 / 187019**:26B-A4B 长提示精度问题、31B 含图像输入精度问题。

### 建议的推进顺序

**先用 `small` 打通链路,再换 Gemma 4。**

理由不是 Gemma 4 不好,而是上面四条里有三条是 Gemma 4 特有的。如果第一次跑
真实推理就用它,一旦输出不对,你无法区分:

- 是我的推理编排(KV cache、采样、停止条件)写错了?
- 还是 5 个 IR 之间的数据流接错了?
- 还是 chat template 没渲染对?
- 还是撞上了那几个已知精度问题?

先用单 IR 的 `small` 把「读模型 → 编译 → 分词 → 自回归解码 → 反分词」这条链路
验证到已知good,再引入 Gemma 4,那时新出现的问题必然来自多 IR 编排本身。

如果决定直接上 Gemma 4,以上四项工作会前移到 Task 15,需要相应调整该 Task 的
范围预期。

### 下载

**仓库页面**:https://huggingface.co/OpenVINO/gemma-4-E2B-it-int4-ov

**必须放到这个目录**(脚本与校验工具都按此路径查找):

```text
D:\nim\Isvik\runtime\models\gemma-4-E2B-it-int4-ov\
```

所有文件平铺在该目录下,不要再套子目录。

#### 方式一:脚本自动下(需先能访问 huggingface.co)

```powershell
.\scripts\fetch-deps.ps1 -What Model -Model gemma4-e2b -TryHuggingFace
```

#### 方式二:手动下载

直链格式是 `https://huggingface.co/OpenVINO/gemma-4-E2B-it-int4-ov/resolve/main/<文件名>`。

> **必须用 `resolve/main`,不能用 `blob/main`。** 后者返回的是 HTML 网页,
> 会得到一个看起来存在、实际是网页的文件。这是手动下载最常见的错误。

按体积从大到小(便于安排下载顺序),精确字节数用于核对:

| 文件 | 字节数 | 约 |
| --- | ---: | ---: |
| `openvino_text_embeddings_per_layer_model.bin` | 2,349,334,608 | 2.19 GB |
| `openvino_language_model.bin` | 1,379,621,905 | 1.28 GB |
| `openvino_text_embeddings_model.bin` | 403,177,480 | 384 MB |
| `openvino_vision_embeddings_model.bin` | 169,024,052 | 161 MB |
| `tokenizer.json` | 32,169,626 | 30.7 MB |
| `openvino_tokenizer.bin` | 17,270,328 | 16.5 MB |
| `openvino_detokenizer.bin` | 4,413,547 | 4.2 MB |
| `openvino_language_model.xml` | 4,012,442 | 3.8 MB |
| `openvino_vision_embeddings_model.xml` | 2,028,930 | 1.9 MB |
| `openvino_tokenizer.xml` | 42,753 | 42 KB |
| `openvino_detokenizer.xml` | 27,378 | 27 KB |
| `openvino_text_embeddings_per_layer_model.xml` | 17,927 | 18 KB |
| `chat_template.jinja` | 16,317 | 16 KB |
| `openvino_text_embeddings_model.xml` | 7,119 | 7 KB |
| `config.json` | 4,983 | |
| `tokenizer_config.json` | 2,712 | |
| `processor_config.json` | 1,689 | |
| `openvino_config.json` | 1,424 | |
| `preprocessor_config.json` | 403 | |
| `generation_config.json` | 203 | |

合计 **约 4.06 GB**(20 个必需文件)。`README.md` 与 `.gitattributes` 可不下。

**注意 `text_embeddings_per_layer` 是最大的单个文件(2.19 GB),比语言模型主体
还大。** 这正是 Per-Layer Embeddings 架构的体现 —— 逐层嵌入表占了模型一半以上,
也说明这个模型的推理绕不开对该 IR 的正确使用。

#### 方式三:curl 批量(粘贴到能访问 HF 的终端)

```powershell
$base = 'https://huggingface.co/OpenVINO/gemma-4-E2B-it-int4-ov/resolve/main'
$dest = 'D:\nim\Isvik\runtime\models\gemma-4-E2B-it-int4-ov'
New-Item -ItemType Directory -Path $dest -Force | Out-Null

$files = @(
    'openvino_language_model.xml',                 'openvino_language_model.bin'
    'openvino_text_embeddings_model.xml',          'openvino_text_embeddings_model.bin'
    'openvino_text_embeddings_per_layer_model.xml','openvino_text_embeddings_per_layer_model.bin'
    'openvino_vision_embeddings_model.xml',        'openvino_vision_embeddings_model.bin'
    'openvino_tokenizer.xml',                      'openvino_tokenizer.bin'
    'openvino_detokenizer.xml',                    'openvino_detokenizer.bin'
    'config.json', 'generation_config.json', 'openvino_config.json'
    'tokenizer_config.json', 'tokenizer.json', 'chat_template.jinja'
    'preprocessor_config.json', 'processor_config.json'
)

foreach ($f in $files) {
    Write-Host "下载 $f"
    # -C - 支持断点续传,中断后重跑同一条命令即可继续
    curl.exe -L -f -C - --progress-bar -o (Join-Path $dest $f) "$base/$f"
}
```

`-C -` 是断点续传:网络中断后重新执行同一段脚本会从断点继续,不会重下已完成的部分。

#### 下载完成后务必校验

```powershell
.\scripts\verify-model.ps1 -Model gemma4-e2b
```

该脚本按上表的精确字节数逐个核对,并检查文件头以识别两类静默失败:

- **LFS 指针文件** —— 用错下载方式时得到的是几百字节的文本(内容以
  `version https://git-lfs.github.com/spec/v1` 开头),文件存在但不是权重。
- **HTML 错误页** —— 用了 `blob/main` 链接时得到的是网页。

这两种情况都不会在下载时报错,只会在加载模型时炸,且错误信息晦涩。先校验能省很多时间。

若模型放在别处,用 `-Path` 指定:

```powershell
.\scripts\verify-model.ps1 -Model gemma4-e2b -Path D:\downloads\gemma4
```

### 关于 ModelScope

已确认 **ModelScope 上没有 OpenVINO IR 版的 Gemma 4**,只有 Google 的原始权重
`google/gemma-4-E2B-it`(`model.safetensors` 实测 9.54 GB)。走那条路要先下
9.54 GB 再自己量化,产出约 4 GB 的 IR —— 比直接取官方 IR 多下 2.4 倍的量,
还要加上转换耗时与 Python 工具链。**能访问 HF 就直接取官方 IR。**

---

## 五、明确不需要安装的东西

列出来避免白装:

| 项 | 为什么不需要 |
| --- | --- |
| 独立的 OpenVINO 安装包 | GenAI archive 已包含 Runtime |
| `openvino-tokenizers` pip 包 | archive 里已有 DLL,不需要 Python 包 |
| `huggingface-cli` / `hf` | git-lfs 或 curl 就够;且它需要 Python |
| 7-Zip | Windows 自带的 tar 能解 zip |
| cmake | Isvik 不用 cmake 构建 |
| 任何 Nim 第三方包 | 当前零第三方依赖,规范 §41 要求优先标准库 |
| NPU / GPU 驱动更新 | 实测版本已高于要求 |
| Visual Studio / MSVC | `nim.cfg` 把编译器钉死为 gcc |

---

## 六、一个需要提前知道的架构问题

这不是安装项,但会影响后续几个 Task 的工作量,提前说明比事后发现好。

**NPU 上跑 LLM 的复杂度被 OpenVINO GenAI 的 `LLMPipeline` 封装了,而 Isvik
不用它。**

NPU 要求静态 shape,所以在 NPU 上做自回归解码需要处理:

- 提示词长度与响应长度的静态上限(GenAI 里是 `MAX_PROMPT_LEN` 默认 1024、
  `MIN_RESPONSE_LEN` 默认 128,两者之和即最大上下文)
- 长提示的分块预填充(GenAI 里是 `NPUW_LLM_PREFILL_CHUNK_SIZE`)
- KV cache 的布局与复用

这些在 GenAI 的 C++ `LLMPipeline` 里是现成的。Isvik 要 100% Nim 自己实现
推理编排,就得自己处理这一层 —— **规范对此没有任何规定**,而工作量不小。

顺带一提:GenAI archive 里带了 `openvino_genai_c.dll`(C API)。理论上可以
考虑直接绑定它,但那会让 Isvik 的推理编排依赖 GenAI 而不只是 OpenVINO
Runtime,是个需要单独讨论的架构决定,**目前没有做这个决定**。

CPU / GPU 上没有静态 shape 的强制要求,所以先在 CPU/GPU 上打通再考虑 NPU
是更稳的顺序。

---

## 七、还需要你拍板的两件事

1. **模型走 [A] / [B] / [C] 哪条路,以及是否先用 `small` 过渡再上 Gemma 4**
   (见第 4.1 节末的建议)。

2. **Isvik 的分发策略**(影响 Task 12 `isvik doctor` 的探针逻辑):
   - 只依赖用户系统里已安装的 OpenVINO
   - 捆绑 DLL 一起分发(需处理 Apache-2.0 再分发义务与 NOTICE,体积 +205 MB)
   - 两者都支持,由 `doctor` 报告实际加载的是哪一份

---

## 相关文档

- [../DEVLOG.md](../DEVLOG.md) —— 实测原始数据、设计决策与未完成事项
- [../README.md](../README.md) —— 项目概览与构建命令
- `../Isvik_AI_MASTER_PROMPT_FINAL.md` —— 唯一权威规范

> 本文档中的 OpenVINO 版本号、下载地址、NPU 量化要求与驱动版本要求均来自
> [OpenVINO 官方文档](https://docs.openvino.ai/),内容经改写以符合许可要求。
