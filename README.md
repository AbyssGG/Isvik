# Isvik

<p align="center">
  <strong style="font-size: 1.5em;">面向 Intel AI PC 的高性能原生本地 AI 推理平台与多协议运行时</strong>
  <br>
  <i>100% 纯 Nim 实现 · 零 Python 依赖 · 基于 Intel OpenVINO C API · 深度适配 CPU / iGPU / NPU</i>
</p>

<p align="center">
  <a href="https://github.com/AbyssGG/Isvik/releases"><img src="https://img.shields.io/badge/version-0.1.0-blue.svg?style=flat-square" alt="Version"></a>
  <a href="https://nim-lang.org/"><img src="https://img.shields.io/badge/Nim-2.0+-orange.svg?style=flat-square&logo=nim" alt="Nim"></a>
  <a href="https://www.intel.com/content/www/us/en/developer/tools/openvino-toolkit/overview.html"><img src="https://img.shields.io/badge/Backend-OpenVINO_2026.3-0071C5.svg?style=flat-square&logo=intel" alt="Intel OpenVINO"></a>
  <a href="https://github.com/AbyssGG/Isvik/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-Apache_2.0-green.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/AbyssGG/Isvik/actions"><img src="https://img.shields.io/badge/CI-Passing-brightgreen.svg?style=flat-square" alt="CI"></a>
</p>

<p align="center">
  <a href="./README.md"><b>简体中文</b></a> | <a href="./README_EN.md"><b>English</b></a>
</p>

---

## 🌟 什么是 Isvik？

**Isvik** 是一个 100% 使用 **Nim** 语言构建的高性能、极轻量、单二进制的本地 AI 推理运行平台（Runtime Platform）。

它以底层基础库 **[Resonance](https://github.com/AbyssGG/Resonance)** 为基石，通过 OpenVINO 原生 C API 直连硬件，专为 **Intel AI PC（Intel Core / Core Ultra 系列）** 打造，提供统一、极致优化的 **CPU / iGPU (Arc, Iris Xe) / NPU (Intel AI Boost)** 本地推理能力。

### 为什么选择 Isvik？

* ⚡ **100% 原生纯编译二进制**：没有臃肿的 Python 解释器环境，没有 Node.js / Electron 进程开销，毫秒级冷启动，极致低内存占用与系统资源消耗。
* 🎯 **Intel 硬件深度调度**：支持自适应 `AUTO` 设备决策（`NPU → Intel GPU → CPU`），精确区分 Intel 原厂显卡与第三方独显（自动过滤 NVIDIA 等非目标卡），具备 iGPU 单次显存越界（4 GiB 限制）自动 CPU 熔断救回机制。
* 🖥️ **现代化开箱即用工作台**：自带美观、交互式的终端 REPL 工作台，支持双语环境、编号模型选择（`[1] [2]`）、多轮对话流式输出与模型热切换。
* 🔌 **多协议本地 API 服务（Local API）**：内置高性能 HTTP 服务，零中转无缝兼容 **OpenAI Chat Completions**、**OpenAI Responses** 与 **Anthropic Messages** 协议标准，开箱直连 **TRAE**、**Continue.dev**、**Open WebUI**、**Cherry Studio** 等各类 IDE 与前端应用。
* 🛡️ **工业级安全与内存安全**：基于不透明整数句柄的资源所有权管理（彻底杜绝 Use-After-Free、Double Free、Dangling Pointer），严格的跨平台路径穿越防护（防 NTFS 数据流、UNC 注入及保留名攻击）。
* 📊 **真诚无套路的 Benchmark**：内置真实硬件基准测试工具，严格区分预热与有效统计，拒绝虚假插值，如实上报 P50 / P95 延迟与 Token 生成速率。

---

## 📑 目录

- [硬件与功能矩阵](#-硬件与功能矩阵)
- [系统架构](#-系统架构)
- [快速开始](#-快速开始)
  - [环境准备](#1-环境准备)
  - [获取依赖与 OpenVINO Runtime](#2-获取依赖与-openvino-runtime)
  - [编译与运行](#3-编译与运行)
- [交互式工作台体验](#-交互式工作台体验)
- [Local API 服务与多协议接入](#-local-api-服务与多协议接入)
  - [启动服务与 API Key 凭据管理](#启动服务与-api-key-凭据管理)
  - [API 端点一览](#api-端点一览)
  - [接入成品客户端（以 TRAE IDE 为例）](#接入成品客户端以-trae-ide-为例)
  - [标准 cURL 调用示例](#标准-curl-调用示例)
- [基准测试 (Benchmark)](#-基准测试-benchmark)
- [架构约束与安全性设计](#-架构约束与安全性设计)
- [项目结构](#-项目结构)
- [参与贡献](#-参与贡献)
- [开源许可](#-开源许可)

---

## 📊 硬件与功能矩阵

### 1. 硬件支持与真机实测（Intel Core Ultra 7 270K Plus 环境）

| 硬件设备类别 | 识别名称 / 架构 | 驱动状态 | 推理与生成支持状态 |
| :--- | :--- | :--- | :--- |
| **Intel CPU** | `Intel(R) Core(TM) Ultra 7 270K Plus (intel64)` | 系统自带 | ✅ **已验证（完整文本生成、流式对话、API 服务）** |
| **Intel iGPU** | `Intel(R) Graphics (GPU: vendor=0x8086 arch=v12.70.4)` | `32.0.101.8864` | ✅ **已验证（AUTO 智能调度、编译与推理验证）** |
| **Intel NPU** | `Intel(R) AI Boost (3720)` | `32.0.100.4841` | 🔄 **已接入（支持硬件枚举与静态 IR 编译，动态 LLM 持续优化中）** |
| **OpenVINO** | `2026.3.0-22451` | C API 绑定 | ✅ **已验证（运行时动态链接，缺少环境时不崩溃）** |

### 2. 核心特性支持表

| 功能特性 | 状态 | 说明 |
| :--- | :---: | :--- |
| **端到端文本生成 (LLM)** | ✅ | 包含 Tokenizer IR、Embedding、Transformer 解码循环与纯 Nim 词表还原 |
| **终端 REPL 工作台** | ✅ | 包含 `-ls`, `-use`, `-stop`, `-devices`, `-info`, 多语言切换等丰富指令 |
| **OpenAI Chat Completions** | ✅ | `/v1/chat/completions` (支持流式 SSE `stream: true` 与非流式) |
| **OpenAI Responses API** | ✅ | `/v1/responses` |
| **Anthropic Messages API** | ✅ | `/v1/messages` (支持 Anthropic 标准 SSE 事件块、Tool Use 结构与 529 状态码) |
| **Isvik Native Protocol** | ✅ | `/api/chat` 原生往返无损统一格式 |
| **采样策略** | ✅ | 支持确定性贪心解码（Greedy）、Temperature、Top-P、Top-K 采样与 Seed 固定 |
| **工具调用 (Tool Calling)** | ✅ | 基于结构化提示词注入与安全信封提取（兼容 OpenAI / Anthropic 两种入参格式） |
| **编译缓存 (Compiled Cache)**| ✅ | 自动缓存已编译的 `.blob` 并绑定硬件签名与 SHA-256 完整性校验 |
| **API 鉴权与 Key 管理** | ✅ | 支持明文本地安全取回、创建、吊销与自动生成，提供端到端访问控制 |

---

## 🏗️ 系统架构

Isvik 遵循极其严苛的分层设计原则，各层依赖单向流动，由架构测试程序机械强制执行，绝不允许逆向或跨层污染：

```
┌─────────────────────────────────────────────────────────────┐
│               GUI / CLI / Local API HTTP Server             │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                    Application Services                     │
│        (ChatSession / ModelService / DeviceService)         │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                         Isvik Core                          │
│     (Runtime / DeviceManager / ModelStorage / Cache / IR)   │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                     Backend Abstraction                     │
│                  (Backend / Tensor Handles)                 │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                      OpenVINO Backend                       │
│    (src/isvik/backends/openvino/ - 唯一允许 import Resonance)│
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                 Resonance (Low-level C-API)                 │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│              Hardware (Intel CPU / iGPU / NPU)              │
└─────────────────────────────────────────────────────────────┘
```

---

## 🚀 快速开始

### 1. 环境准备

Isvik 针对 Windows x64 平台深度调优，构建工具链要求如下：

* **Nim**: `>= 2.0.0`（推荐 2.2+）
* **C 编译器**: **GCC (MinGW-w64)**（推荐 `tdm64-1 10.3.0` 或更高版本）。
  > ⚠️ **重要说明**：由于 Windows x64 下跨 MSVC 与 MinGW 的变参 ABI 差异，必须使用 GCC 编译以支持 OpenVINO ABI 适配层，请勿使用 MSVC (`--cc:vcc`)。
* **Git**: 系统已安装并在 PATH 中。

### 2. 获取依赖与 OpenVINO Runtime

Isvik 提供了全自动化脚本一键获取官方预构建的 OpenVINO 2026.3 Runtime 与 Tokenizers 运行时库：

```powershell
# 仅下载并解压 OpenVINO Runtime + Tokenizers 到 runtime/ 目录
.\scripts\fetch-deps.ps1 -What Runtime
```

> 💡 **提示**：该脚本会将解压后的 `runtime/openvino/` 路径安全添加到当前用户的 PATH 中。完成后建议重新打开终端窗口使环境变量生效。

### 3. 编译与运行

在项目根目录下执行标准 Nimble 命令：

```powershell
# 1. 编译构建
nimble build

# 2. 运行完整测试套件 (38 个测试套件，覆盖架构、安全、API、模型编排)
nimble test

# 3. 启动 Isvik
.\isvik.exe
```

---

## 💬 交互式工作台体验

直接无参运行 `isvik.exe` 即可进入全功能常驻工作台：

```powershell
.\isvik.exe
```

首次运行会自动引导选择中英文界面，并可随时通过 `-lang zh` / `-lang en` 切换。

```text
  ___          _ _
 |_ _|_____   _(_) | __
  | |/ __\ \ / / | |/ /
  | |\__ \\ V /| |   <
 |___|___/ \_/ |_|_|\_\   Local AI Runtime for Intel AI PC

isvik[未选模型@AUTO]> -ls
已导入的模型:
  选择  标识                           大小       支持设备
  [1]  gemma-4-e2b-it-int4-ov         1.8 GB     CPU, GPU.0, NPU
  [2]  qwen2.5-1.5b-instruct-ov       1.1 GB     CPU, GPU.0

isvik[未选模型@AUTO]> 1
[INFO] 正在编译模型至 CPU ... 完成 (870ms)
isvik[gemma-4-e2b-it-int4-ov@CPU]> 解释什么是本地大模型推理？

本地大模型推理是指将人工智能模型直接部署在用户的终端设备（如搭载 Intel CPU、
iGPU 或 NPU 的 AI PC）上运行，数据无需上传到云端服务器即可完成生成与计算。
具有极低延迟、保护数据隐私以及离线可用的优势。

isvik[gemma-4-e2b-it-int4-ov@CPU]>
```

### 工作台常用快捷命令

| 命令 | 别名 / 说明 | 功能描述 |
| :--- | :--- | :--- |
| `-ls` | `-models` | 列出所有已导入模型，显示 `[1]` `[2]` 编号 |
| `-use <编号\|id>` | `1`, `2` | 切换并加载指定模型（未加载时直接输数字编号即可选择） |
| `-stop` | `-unload` | 卸载当前模型，立即释放占用内存并回到空闲状态 |
| `-devices` | `-doctor` | 检测并输出本机真实硬件设备状态与架构详情 |
| `-info [id]` | - | 查看当前会话状态、上下文消耗或模型元数据详情 |
| `-import <路径>`| - | 从指定本地目录导入 OpenVINO IR 格式模型 |
| `-rm <id>` | - | 从模型库中注销并移除模型元数据 |
| `-new` | `/new` | 清空上下文，开启全新对话轮次 |
| `-history` | `/history` | 查看当前会话的多轮对话历史记录 |
| `-system [文本]`| `/system` | 查看、设置或清除当前会话的 System Prompt |
| `-key <action>`| - | 便捷管理 API Key（`create`, `list`, `show`, `revoke`） |
| `-serve` | - | 在当前前台直接拉起 API 服务端 |
| `-lang <zh\|en>`| - | 切换界面语言偏好并保存至 `settings.json` |
| `-exit` | `/exit`, `quit` | 安全退出工作台 |

---

## 🔌 Local API 服务与多协议接入

Isvik 内置高性能 Local API Server，为各类上层应用提供标准的 HTTP/REST 与 SSE 接口。

### 启动服务与 API Key 凭据管理

```powershell
# 推荐方式：以安全 API Key 模式启动，绑定 7317 端口（若无可用 Key 会自动生成一个并打印）
.\isvik.exe api serve --port 7317

# 也可以预先创建具有特定名称的 API Key
.\isvik.exe api key create --name trae-client
.\isvik.exe api key list
.\isvik.exe api key show 1

# 兼容模式启动（无鉴权，仅限回环地址本地调试）
.\isvik.exe serve --port 7317
```

### API 端点一览

| 协议标准 | HTTP 方法 | 端点路径 | 说明 |
| :--- | :---: | :--- | :--- |
| **OpenAI 兼容** | `POST` | `/v1/chat/completions` | 标准对话补全（支持流式 SSE 与非流式） |
| **OpenAI 别名** | `POST` | `/chat/completions` | 方便部分未写 `/v1` 前缀的客户端访问 |
| **OpenAI 响应** | `POST` | `/v1/responses` | Responses API 标准端点 |
| **Anthropic 兼容**| `POST` | `/v1/messages` | Messages API 标准端点（支持 Tool Call 与 SSE） |
| **Isvik Native** | `POST` | `/api/chat` | Isvik 原生多功能统一推理接口 |
| **系统与运维** | `GET` | `/api/health` | 服务健康检查与当前模型装载状态 |
| **系统与运维** | `GET` | `/api/version` | 运行时版本与协议特性声明 |
| **模型管理** | `GET` | `/api/models` | 获取所有已导入模型清单 |
| **模型管理** | `POST` | `/api/load` | 动态加载指定模型 |
| **模型管理** | `POST` | `/api/unload` | 动态卸载模型释放显存/内存 |
| **硬件监控** | `GET` | `/api/devices` | 获取当前环境检测到的硬件设备与调度状态 |
| **运行时状态** | `GET` | `/api/runtime` | 查看当前激活模型与实际执行推理的物理硬件 |

---

### 接入成品客户端（以 TRAE IDE 为例）

在 **TRAE IDE**（或其他支持自定义 AI 模型的客户端如 Continue.dev、Cherry Studio）中，进入 `设置 (Settings) > 模型管理 (Models) > 添加自定义模型 (Add Custom Model)`：

#### 方案 A：OpenAI Chat Completions 协议格式（推荐）
* **API 格式 / Provider**: `OpenAI`
* **请求地址 / Base URL**: `http://127.0.0.1:7317/v1`
* **完整 URL 开关**: `关闭`（客户端自动拼接 `/chat/completions`）
* **模型名称 (Model ID)**: 填入 `isvik list` 查到的模型标识（如 `gemma-4-e2b-it-int4-ov`）
* **API Key**: 填入 `isvik api key show 1` 获取的 `isvk_...` 密钥

#### 方案 B：Anthropic Messages 协议格式
* **API 格式 / Provider**: `Anthropic`
* **请求地址 / Base URL**: `http://127.0.0.1:7317`
* **完整 URL 开关**: `关闭`（客户端自动拼接 `/v1/messages`）
* **模型名称 (Model ID)**: 填入模型标识
* **API Key**: 填入 `isvk_...` 密钥（支持 `Authorization: Bearer` 与 `x-api-key`）

---

### 标准 cURL 调用示例

#### 1. OpenAI 格式流式调用

```bash
curl -X POST http://127.0.0.1:7317/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_ISVIK_API_KEY>" \
  -d '{
    "model": "gemma-4-e2b-it-int4-ov",
    "messages": [
      {"role": "system", "content": "你是一个严谨的工程师助理。"},
      {"role": "user", "content": "请用一段话简述 Intel NPU 的计算特点。"}
    ],
    "stream": true,
    "temperature": 0.7
  }'
```

#### 2. Anthropic Messages 格式调用

```bash
curl -X POST http://127.0.0.1:7317/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: <YOUR_ISVIK_API_KEY>" \
  -H "anthropic-version: 2023-06-01" \
  -d '{
    "model": "gemma-4-e2b-it-int4-ov",
    "max_tokens": 1024,
    "messages": [
      {"role": "user", "content": "Hello! List 3 advantages of local LLMs."}
    ]
  }'
```

---

## 📈 基准测试 (Benchmark)

Isvik 拒绝虚假的基准指标。内置的 `isvik benchmark` 命令执行真实硬件压测，自动剔除冷启动与预热偏置，并以严格的最近秩法计算 P50 / P95 分位数：

```powershell
# 运行标准压测（5 次采样 + 1 次预热）
.\isvik.exe benchmark --runs 5 --warmup 1 --max-tokens 64

# 输出纯 JSON 结构化数据（便于 CI 与自动化分析）
.\isvik.exe --json benchmark gemma-4-e2b-it-int4-ov
```

**真机实测输出参考（Intel Core Ultra 7 270K Plus, Gemma 4 E2B INT4）：**

```text
================================================================================
Isvik Benchmark Report
Model:  gemma-4-e2b-it-int4-ov (INT4)
Device: CPU [Intel(R) Core(TM) Ultra 7 270K Plus]
================================================================================
Metric                    Mean     P50      P95      Min      Max      Samples
--------------------------------------------------------------------------------
Time to First Token (ms)  87.0     78.5     104.6    78.0     104.6    5/5
Decode Rate (tok/s)       18.56    19.05    19.71    16.92    19.71    5/5
End-to-End Rate (tok/s)   16.83    16.35    18.09    16.04    18.09    5/5
--------------------------------------------------------------------------------
```

---

## 🛡️ 架构约束与安全性设计

1. **绝对内存安全与零悬空指针**：上层不直接操作底层 OpenVINO C 原生指针，统一使用运行时分配的不可预测整数句柄（`ModelId`, `CompiledModelId`, `InferRequestId`）。在执行 `unloadModel` 时触发级联安全注销，重复使用失效句柄返回明确的 `INVALID_PARAMETER` 错误码。
2. **严苛的路径安全机制（Anti Path-Traversal）**：所有用户输入路径与模型标识必须通过 `safeJoin` 深度清洗，自动拦截 `..`、绝对路径、UNC 网络路径、Windows 保留设备名（`CON`, `NUL`, `COM1` 等）以及 NTFS 隐藏备用数据流（ADS `:stream`）。
3. **架构边界防腐检验**：通过 `tests/architecture/tarchitecture.nim` 静态代码分析器实时监督，确保业务与核心层严禁出现任何 `osproc`、Python 文件或未授权的底层 C 库引用。

---

## 📁 项目结构

```text
Isvik/
├── src/
│   ├── isvik.nim                  # 库入口
│   └── isvik/
│       ├── version.nim            # 权威版本号定义
│       ├── core/                  # Isvik Core (Runtime, DeviceManager, Tensor)
│       ├── backends/              # 推理后端 (openvino/, mock/)
│       ├── inference/             # 推理调度 (Tokenizer, Greedy/Sampling Decoder)
│       ├── models/                # 模型清单、存储与元数据管理
│       ├── cache/                 # 编译产物 Cache (.blob 管理与校验)
│       ├── protocol/              # 多协议适配层 (OpenAI, Anthropic, Native)
│       ├── services/              # 应用层服务 (ChatSession, ModelService)
│       ├── server/                # Local API HTTP 服务端
│       ├── cli/                   # 终端 CLI 与交互式工作台实现
│       ├── config/                # 路径配置与 settings.json
│       ├── logging/               # 多 Sink 结构化日志系统
│       └── i18n/                  # 中英文国际化文案
├── Resonance/                     # 底层 OpenVINO C API 纯 Nim 绑定库
├── tests/                         # 自动化测试套件 (38 个测试文件)
│   ├── unit/                      # 单元测试 (日志, 路径, 配置, 错误码)
│   ├── core/                      # 核心运行时生命周期与句柄安全
│   ├── backends/                  # 后端与 OpenVINO 接口测试
│   ├── inference/                 # 分词、解码与生成测试
│   ├── protocol/                  # 协议双向转换与 SSE 校验
│   └── architecture/              # 架构分层机械强制规则测试
├── scripts/                       # 依赖下载与环境辅助脚本
├── docs/                          # 详细安装与硬件调优指南
├── isvik.nimble                   # Nimble 软件包定义
└── nim.cfg                        # 全局构建与编译器约束配置
```

---

## 🤝 参与贡献

我们极其欢迎社区开发者参与共同建设 Isvik！无论是增加新的模型架构适配、优化 NPU / GPU 推理效率，还是完善前端生态集成：

1. 查阅 **[CONTRIBUTING.md](./CONTRIBUTING.md)** 了解详细的开发流程与代码规范。
2. 查阅 **[DEVLOG.md](./DEVLOG.md)** 了解架构决策背景与实测踩坑记录。
3. 遵循 **[CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md)** 共同维护良好的社区氛围。
4. 提交 Pull Request 前请确保本地运行 `nimble test` 全部通过。

---

## 📄 开源许可

本项目依据 **[Apache License 2.0](./LICENSE)** 许可证开源。

> *注：用户下载和导入的第三方模型权重（如 Gemma、Qwen 等）受各模型自身的开源许可协议约束，请在使用前仔细阅读对应模型的许可声明。*
