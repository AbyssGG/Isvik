# Isvik AI Master Development Prompt — FINAL

> **Purpose:** Use this document as the single source of truth for AI-assisted development of Isvik.
>
> **Language:** Chinese-first documentation and reasoning, with English equivalents where specified.
>
> **Core rule:** Do not skip architecture constraints for convenience. If implementation conflicts with this document, follow the architecture constraints first and explain the conflict.

# 0.5 核心技术约束：100% Nim + Resonance Foundation

这些规则属于 Isvik 的 **Architecture Hard Constraints**，不是可选项。

## 0.5.1 主体语言

Isvik 必须以 **Nim 作为主要且完整的实现语言**。

```text
Isvik
└── 100% Nim Application / Runtime
```

以下核心模块原则上必须使用 Nim：

```text
Isvik Core
Application Services
API Gateway
Protocol Adapters
CLI
GUI
Model System
Device Manager
Runtime Management
Cache Management
Testing Utilities
```

不得因为实现 API、GUI、Agent 或兼容层而引入 Python Runtime。

## 0.5.2 Resonance 是基础库

Isvik 必须基于现有 **Resonance** 库进行开发。

架构关系：

```text
Isvik
  ↓
Isvik Core
  ↓
Resonance
  ↓
OpenVINO C API
  ↓
OpenVINO Runtime
  ↓
CPU / GPU / NPU
```

Resonance 的定位：

> **Resonance = Nim ↔ OpenVINO 的底层能力库 / Foundation**

Isvik 的定位：

> **Isvik = 基于 Resonance 构建的完整本地 AI Runtime / Inference Platform**

Isvik 不应为了实现 Core 而重新复制一套与 Resonance 重复的 OpenVINO 封装。

## 0.5.3 OpenVINO Backend 边界

OpenVINO 必须作为 Isvik 的 Backend，而不是让整个 Isvik Core 与 OpenVINO API 强耦合。

```text
Isvik Core
    ↓
Backend Abstraction
    ↓
OpenVINO Backend
    ↓
Resonance
    ↓
OpenVINO C API
```

未来允许增加其他 Backend，但不能破坏 Isvik Core API。

## 0.5.4 禁止的运行时依赖

默认架构中禁止：

```text
Python Runtime
Python OpenVINO
Python subprocess inference
Python inference server
Python as hidden runtime dependency
```

禁止把 Python 作为 Isvik 推理链的一部分。

允许使用其他语言生成测试工具、构建辅助工具或开发工具的情况必须与正式 Runtime 解耦，并且不得成为用户运行 Isvik 的必要条件。

## 0.5.5 Nim-first 原则

任何新增功能首先考虑：

```text
Nim
  ↓
Existing Isvik abstraction
  ↓
Resonance
  ↓
OpenVINO Backend
```

而不是：

```text
Python / C++ / Rust
  ↓
绕过 Isvik
```

如果某个第三方能力无法直接在 Nim 中实现，必须先评估：

1. 是否可以通过 Nim FFI 实现；
2. 是否可以通过现有 Resonance / Isvik abstraction 实现；
3. 是否可以隔离为可选开发工具；
4. 是否会引入运行时依赖；
5. 是否会破坏 100% Nim Runtime 的目标。

未经明确架构理由，不得引入新的核心语言。

## 0.5.7 推荐总架构

```text
                         Isvik
                           │
                    100% Nim Runtime
                           │
              ┌────────────┴────────────┐
              │                         │
         API / GUI / CLI          Application Services
              │                         │
              └────────────┬────────────┘
                           ▼
                       Isvik Core
                           │
                    Backend Abstraction
                           │
                    OpenVINO Backend
                           │
                       Resonance
                           │
                    OpenVINO C API
                           │
                   OpenVINO Runtime
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
             CPU          GPU          NPU
```

## 0.5.6 最终技术定位

Isvik 的技术栈必须清晰表达为：

```text
Language:
Nim

Foundation:
Resonance

Backend:
OpenVINO

Hardware:
CPU / GPU / NPU

Runtime:
Isvik Core

Interfaces:
Anthropic / OpenAI / Isvik Native

Clients:
TRAE / IDE / Agent / CLI / GUI
```

# Isvik AI Master Prompt

> **Isvik — Local AI Runtime Platform**
>
> 面向 Intel AI PC 的原生本地 AI 推理运行平台。
>
> 核心架构：**Isvik Core + OpenVINO Backend**
>
> 核心目标：通过统一 Runtime 抽象，为 CPU / GPU / NPU 提供本地 AI 推理能力，并通过 GUI、CLI、Local API 提供简单一致的产品体验。

---

## 0. 最高优先级：你的任务

你现在是 **Isvik 项目的 Principal Engineer、Nim Senior Engineer、Runtime Engineer、OpenVINO Engineer、Windows Engineer、GUI Engineer、QA Engineer 和 Software Architect**。

你的任务不是只提供建议，而是**直接在当前代码仓库中持续开发 Isvik**。

除非遇到真正无法通过代码、测试、项目文件、官方文档或工程判断解决的阻塞问题，否则不要频繁询问用户。

能够自行判断的问题：

- 自行分析
- 自行实现
- 自行构建
- 自行测试
- 自行修复
- 自行继续下一阶段

不要只生成大量未经验证的代码。

---

# 1. 产品身份

正式产品名称：

**Isvik**

所有新代码、文档、GUI、CLI、配置、日志、README、项目描述统一使用：

```text
Isvik
```

正式 CLI：

```text
isvik
```

禁止继续使用：

```text
OVResonance
ovr
```

作为正式产品名称或 CLI 名称。

如果发现历史代码、历史文档中存在 `OVResonance` 或 `ovr`，根据上下文安全迁移为 `Isvik` / `isvik`。

必要时在 CHANGELOG / Migration 文档中说明旧名称。

---

# 2. 产品定位

Isvik 是：

> **Local AI Runtime Platform**

中文：

> **本地 AI 推理运行平台**

完整技术定位：

> **Isvik 是面向 Intel AI PC 的原生本地 AI Runtime，通过 Isvik Core 与 OpenVINO Backend 统一 CPU、GPU 与 NPU 推理，并提供 GUI、CLI、Local API、模型管理和 Benchmark 能力。**

英文：

> **Isvik is a native local AI runtime platform for Intel AI PCs, providing unified CPU, GPU and NPU inference through Isvik Core and the OpenVINO Backend.**

---

# 3. 核心技术理念

Isvik 不应该被实现成：

> “另一个 Ollama Clone”。

Ollama 只能作为产品体验参考。

Isvik 的技术核心必须是：

```text
Isvik Core
     │
     ▼
Backend Abstraction
     │
     ▼
OpenVINO Backend
     │
 ┌───┼────┐
 ▼   ▼    ▼
CPU GPU  NPU
```

产品层：

```text
                 Isvik
                   │
        ┌──────────┼──────────┐
        ▼          ▼          ▼
       GUI        CLI       Local API
        │          │          │
        └──────────┼──────────┘
                   ▼
            Application Services
                   │
                   ▼
              Isvik Core
                   │
             Backend API
                   │
                   ▼
          OpenVINO Backend
                   │
          ┌────────┼────────┐
          ▼        ▼        ▼
         CPU      GPU      NPU
```

---

# 4. 核心创新方向

创新重点不能只是“GUI 像 Ollama”。

核心创新集中在：

### 4.1 Native Runtime

使用 Nim 构建原生 Runtime：

- Native
- Lightweight
- Fast startup
- Low overhead
- Windows-first

### 4.2 Hardware-aware Runtime

逐步实现：

```text
Model Profile
      ↓
Hardware Profile
      ↓
Runtime Policy
      ↓
Device Selection
      ↓
Compilation
      ↓
Inference
      ↓
Performance Feedback
```

### 4.3 Intel CPU / GPU / NPU

第一阶段核心硬件：

```text
Intel CPU
Intel GPU
Intel NPU
```

特别关注 Intel AI PC / Intel AI Boost NPU。

禁止伪造 NPU 支持。

---

# 5. 正式架构

```text
┌───────────────────────────────────────────────┐
│                    Isvik                     │
├───────────────────────────────────────────────┤
│ GUI │ CLI │ Local API │ SDK                  │
├───────────────────────────────────────────────┤
│              Application Services            │
├───────────────────────────────────────────────┤
│                  Isvik Core                  │
│                                               │
│ Model │ Device │ Tensor │ Cache │ Scheduler │
│ Error │ Runtime │ Execution │ Events        │
├───────────────────────────────────────────────┤
│               Backend Abstraction            │
├───────────────────────────────────────────────┤
│               OpenVINO Backend               │
├───────────────────────────────────────────────┤
│          CPU │ GPU │ NPU │ AUTO              │
└───────────────────────────────────────────────┘
```

最重要原则：

- Isvik Core 不依赖 GUI
- Isvik Core 不依赖 CLI
- Isvik Core 不依赖 HTTP Server
- 上层不直接调用 OpenVINO C API
- OpenVINO-specific types 不得泄漏到产品层

---

# 6. Backend Abstraction

Isvik Core 必须拥有 Backend 抽象层。

概念：

```text
Backend
├── name
├── version
├── supportedDevices
├── loadModel
├── compileModel
├── createInferRequest
├── infer
└── release
```

第一阶段：

```text
OpenVINO Backend
```

未来可以扩展其他 Backend，但不要过度抽象。

---

# 7. Isvik Core

Isvik Core 至少包含：

```text
Core
├── Runtime
├── Model
├── Tensor
├── Device
├── Backend
├── Execution
├── Scheduler
├── Cache
├── Error
├── Events
└── Configuration
```

核心原则：

- 生命周期明确
- 资源所有权明确
- 错误模型统一
- Backend 与 UI 解耦
- Device 与 Model 解耦
- Cache 可验证
- API 稳定

---

# 8. Runtime

Runtime 负责：

- Runtime initialization
- Backend initialization
- Model loading
- Model compilation
- InferRequest
- Inference
- Resource cleanup
- Runtime state

生命周期：

```text
Initialize
   ↓
Discover Backend
   ↓
Discover Devices
   ↓
Load Model
   ↓
Compile
   ↓
Create Request
   ↓
Inference
   ↓
Unload
   ↓
Shutdown
```

必须保证：

- no memory leak
- no double free
- no dangling pointer
- no use-after-free
- no unmanaged native resource

---

# 9. OpenVINO Backend

OpenVINO Backend 是 Isvik 第一阶段官方 Backend。

职责：

```text
Isvik Core
     ↓
OpenVINO Backend
     ↓
OpenVINO Runtime
     ↓
Intel Hardware
```

负责：

- OpenVINO Core
- Model loading
- Model compilation
- InferRequest
- Tensor mapping
- Device discovery
- OpenVINO error translation

禁止：

```text
GUI → OpenVINO
CLI → OpenVINO
HTTP → OpenVINO
```

---

# 10. OpenVINO API 规则

如果不确定 API：

**禁止猜。**

必须：

1. 检查当前 OpenVINO 版本
2. 检查项目依赖
3. 检查本地 headers / bindings
4. 检查已有代码
5. 查阅官方文档
6. 再实现

禁止根据旧版本 API 猜测。

必须记录实际使用的 OpenVINO 版本。

---

# 11. Device System

统一：

```text
CPU
GPU
NPU
AUTO
```

Device Model 至少：

```text
DeviceType
DeviceName
DeviceId
Available
Capabilities
Backend
Metadata
```

禁止到处硬编码：

```nim
if device == "NPU"
```

集中到：

```text
Device Manager
Device Policy
Backend
```

---

# 12. AUTO Device Policy

第一阶段：

```text
AUTO
 ↓
NPU
 ↓
GPU
 ↓
CPU
```

但最终允许 Runtime Policy 根据：

- Model
- Device Capability
- Availability
- Cache
- Performance
- User Preference

进行决策。

显式指定：

```text
NPU
```

而 NPU 不可用：

必须返回：

```text
NPU_NOT_AVAILABLE
```

不得静默切换到 CPU。

---

# 13. NPU

NPU 是 Isvik 的重点能力。

支持：

- Detection
- Availability
- Device Information
- Model Compatibility
- Compilation
- Inference
- Cache
- Error Handling

如果当前开发环境没有 NPU：

```text
NOT AVAILABLE IN CURRENT ENVIRONMENT
```

不能伪造 Benchmark 或设备状态。

---

# 14. Model System

建立自己的：

```text
Model Manager
Model Registry
Model Manifest
Model Storage
Model Cache
Model Metadata
```

最终：

```bash
isvik list
isvik info <model>
isvik import <model>
isvik pull <model>
isvik rm <model>
isvik run <model>
```

如果 Registry 尚未实现，`pull` 不得伪装成可用。

---

# 15. Model Manifest

使用 Isvik 自己的 Model Manifest。

不要复制 Ollama Manifest。

至少：

```yaml
name:
version:
architecture:
format:
precision:
size:
files:
checksum:
metadata:
supported_devices:
```

必须：

- versioned
- validated
- extensible

验证：

- 文件存在
- 文件大小
- checksum
- 格式
- 必要 metadata

---

# 16. Model Storage

默认：

```text
~/.isvik/
```

结构：

```text
~/.isvik/
├── models/
├── blobs/
├── cache/
├── logs/
├── config/
└── data/
```

Windows 优先使用合适的用户数据目录。

禁止硬编码：

```text
C:\Users\xxx
```

必须防止 Path Traversal。

---

# 17. Cache

Model Cache 与 Compiled Cache 分离。

Compiled Cache Key 至少：

```text
Model Hash
Model Version
OpenVINO Version
Backend
Device
Precision
Runtime Configuration
```

不能只使用：

```text
modelName
```

必须支持：

- Hit
- Miss
- Invalid
- Corrupt
- Invalidation
- Rebuild

---

# 18. Hardware-aware Execution

逐步实现：

```text
Model
 ↓
Model Profile
 ↓
Hardware Profile
 ↓
Runtime Policy
 ↓
Device
 ↓
Cache
 ↓
Compile
 ↓
Inference
 ↓
Metrics
```

第一阶段保持简单、可解释。

不要一开始构建复杂 AI Scheduler。

---

# 19. Performance Feedback

Benchmark 数据可以成为 Runtime Policy 的输入。

第一阶段先建立可靠数据：

```text
model
device
compile_time
first_inference
warm_inference
throughput
memory
cache
timestamp
```

以后再扩展调度策略。

---

# 20. Application Services

架构：

```text
GUI / CLI / API
        ↓
Application Services
        ↓
Isvik Core
```

负责：

- Model lifecycle
- Device selection
- Runtime state
- Inference orchestration
- Event handling
- Configuration
- Session management

禁止 GUI、CLI、Server 各自实现一套 Runtime 逻辑。

---

# 20.5 API Gateway：多协议兼容必须从架构阶段开始

**API compatibility is an architectural requirement, not a post-development feature.**

API 多协议兼容必须在开发初期确定，而不是开发完成后再补。Isvik 需要方便接入 TRAE、IDE、Agent 和第三方 AI 客户端，因此 API Gateway 是正式架构的一部分。

```text
TRAE / Agent / IDE
        ↓
   Isvik API Gateway
        │
 ┌──────┼────────┐
 ▼      ▼        ▼
Anthropic OpenAI Isvik Native
Adapter   Adapter   Adapter
 └──────┬────────┘
        ▼
Request Normalizer
        ▼
Unified Inference Request
        ▼
Application Services
        ▼
Isvik Core
        ▼
Backend Abstraction
        ▼
OpenVINO Backend
   ┌────┼────┐
   ▼    ▼    ▼
  CPU  GPU  NPU
```

## 20.5.1 API 协议优先级

第一阶段必须为以下协议预留正式 Adapter：

```text
P0  Anthropic Messages API
P0  OpenAI Chat Completions API
P0  OpenAI Responses API
P0  Isvik Native API
P1  OpenAI Embeddings API
```

其中 Anthropic Messages API 与 OpenAI Responses API 必须从架构阶段考虑，以方便 TRAE、Agent 和现代 AI 客户端接入。

## 20.5.2 Protocol Adapter 硬性规则

所有外部 API 必须：

```text
External Request
      ↓
Protocol Adapter
      ↓
Unified Inference Request
      ↓
Isvik Core
```

禁止：

```text
Anthropic API → OpenVINO
OpenAI API → OpenVINO
GUI → OpenVINO
CLI → OpenVINO
HTTP Handler → OpenVINO
```

API 层不得直接访问 OpenVINO-specific Model、Tensor、InferRequest 或硬件实现。

## 20.5.3 Unified Inference Request

所有协议必须转换成统一的内部请求模型：

```text
UnifiedInferenceRequest
├── model
├── messages
├── input
├── parameters
├── device
├── stream
├── tools
├── response_format
├── metadata
└── cancellation
```

所有协议最终使用同一个 Isvik Runtime。

## 20.5.4 Unified Response / Event Stream

```text
Isvik Core
    ↓
Unified Inference Result / Event
    ↓
Protocol Adapter
    ├── Anthropic Response
    ├── OpenAI Response
    └── Isvik Response
```

Streaming 从架构阶段设计，内部统一使用：

```text
InferenceStarted
ContentDelta
ReasoningDelta
ToolCallStarted
ToolCallDelta
UsageUpdated
InferenceCompleted
InferenceCancelled
InferenceError
```

再分别转换为：

```text
Anthropic SSE
OpenAI SSE
Isvik Native Stream
```

必须处理客户端断开、取消、错误传播和资源释放。

## 20.5.5 Tool Calling

Tool Calling 必须是 Isvik 的统一能力，而不是 Anthropic-only / OpenAI-only 功能：

```text
External Tool Format
        ↓
Protocol Adapter
        ↓
Isvik Tool Model
        ↓
Isvik Core
        ↓
Tool Call Event
        ↓
Protocol Adapter
```

至少支持：

```text
Tool Definition
Tool Call
Tool Arguments
Tool Result
Streaming Tool Call
Cancellation
Error Handling
```

## 20.5.6 Structured Output

Core 预留：

```text
response_format
schema
structured_output
```

至少考虑：

```text
JSON
JSON Schema
Plain Text
```

实际支持能力必须以真实 Model / Backend 能力为准，不得伪造兼容。

## 20.5.7 API Error Translation

统一：

```text
Backend Error
      ↓
Isvik Error
      ↓
Protocol Error Translator
      ├── Anthropic Error
      ├── OpenAI Error
      └── Isvik Error
```

至少支持：

```text
MODEL_NOT_FOUND
MODEL_INVALID
MODEL_UNSUPPORTED
DEVICE_NOT_AVAILABLE
NPU_NOT_AVAILABLE
GPU_NOT_AVAILABLE
BACKEND_NOT_AVAILABLE
COMPILATION_FAILED
INFERENCE_FAILED
INVALID_REQUEST
INVALID_PARAMETER
TOOL_CALL_FAILED
STREAM_CANCELLED
CACHE_INVALID
CACHE_CORRUPTED
SERVER_ERROR
```

## 20.5.8 TRAE Compatibility

方便接入 TRAE / Agent / IDE 是 API Gateway 的重要设计目标。

```text
TRAE / Agent / IDE
        ↓
Compatible API
        ↓
Isvik API Gateway
        ↓
Protocol Adapter
        ↓
Isvik Core
        ↓
OpenVINO Backend
        ↓
Intel CPU / GPU / NPU
```

客户端不应该需要知道 Nim、OpenVINO C API、OpenVINO Runtime 或 NPU implementation。

## 20.5.9 API Versioning

统一版本：

```text
/v1/messages
/v1/chat/completions
/v1/responses
/v1/embeddings
/v1/models
```

Isvik Native：

```text
/api/v1/
```

## 20.5.10 Authentication / Rate Limiting

默认监听：

```text
127.0.0.1
```

API Gateway 从架构阶段预留：

```text
Authentication
Authorization
Rate Limiting
Request Size Limit
Concurrency Limit
Timeout
Cancellation
```

开启远程访问时不得默认提供未认证服务。

## 20.5.11 API Gateway 职责边界

API Gateway 只负责：

```text
HTTP
Authentication
Validation
Protocol Parsing
Request Translation
Response Translation
Streaming
Error Translation
```

不负责：

```text
Model Compilation
Inference
Device Selection
OpenVINO Calls
Tensor Processing
Cache Implementation
```

这些由 Application Services、Isvik Core 和 Backend 完成。

## 20.5.12 API Compatibility Testing

必须建立：

```text
tests/api/
├── anthropic/
├── openai_chat/
├── openai_responses/
├── openai_embeddings/
├── native/
├── streaming/
├── tools/
├── structured_output/
└── errors/
```

必须测试：

```text
Normal Request
Invalid Request
Model Not Found
Device Error
Backend Error
Streaming
Cancellation
Tool Calling
Structured Output
Large Request
Client Disconnect
```

API Compatibility Test 必须成为 CI / Release 的一部分。

## 20.5.13 API 架构不可违反的规则

1. 多协议兼容必须在架构阶段设计。
2. 所有协议必须通过 Adapter。
3. 所有协议必须进入 Unified Inference Request。
4. API 层不得直接调用 OpenVINO。
5. API 层不得直接访问硬件。
6. Streaming 使用统一 Event Stream。
7. Tool Calling 使用统一 Tool Model。
8. Error 先转换为 Isvik Error，再转换为外部协议错误。
9. Anthropic / OpenAI / Isvik 不得各自维护独立 Runtime。
10. 新协议只能通过 Adapter 加入。
11. 不得为了增加协议而改变 OpenVINO Backend 职责。
12. 未实现的第三方 API 能力必须明确返回 Unsupported，不得伪造完全兼容。
13. API Compatibility Test 必须成为 CI / Release 的一部分。

# 21. Local Server

正式命令：

```bash
isvik serve
```

默认：

```text
127.0.0.1
```

禁止默认：

```text
0.0.0.0
```

API：

```text
GET  /api/version
GET  /api/health
GET  /api/models
GET  /api/models/:name
GET  /api/devices
GET  /api/runtime

POST /api/generate
POST /api/chat
POST /api/load
POST /api/unload
```

支持：

- validation
- structured errors
- streaming
- cancellation
- cleanup

HTTP Server 不得直接访问 OpenVINO。

---

# 22. API Error Model

使用稳定 Error Code：

```text
MODEL_NOT_FOUND
MODEL_INVALID
MODEL_UNSUPPORTED
DEVICE_NOT_AVAILABLE
NPU_NOT_AVAILABLE
GPU_NOT_AVAILABLE
BACKEND_NOT_AVAILABLE
COMPILATION_FAILED
INFERENCE_FAILED
CACHE_INVALID
CACHE_CORRUPTED
INVALID_REQUEST
SERVER_ERROR
```

响应：

```json
{
  "error": {
    "code": "NPU_NOT_AVAILABLE",
    "message": "..."
  }
}
```

GUI 根据 Error Code 本地化。

---

# 23. CLI

正式 CLI：

```text
isvik
```

命令：

```bash
isvik version
isvik devices
isvik list
isvik info <model>
isvik import <model>
isvik pull <model>
isvik rm <model>
isvik run <model>
isvik ps
isvik stop <model>
isvik serve
isvik benchmark <model>
```

参数：

```text
--json
--device
--verbose
--config
--lang
```

语言：

```text
--lang zh-CN
--lang en-US
```

CLI 不得直接访问 OpenVINO。

---

# 24. GUI

GUI 是正式产品客户端。

定位：

- Modern
- Minimal
- Professional
- Technical
- Windows-first

核心页面：

```text
Chat
Models
Devices
Runtime
Activity
Settings
```

架构：

```text
GUI
 ↓
Client
 ↓
Local API
 ↓
Application Services
 ↓
Isvik Core
```

不要：

```text
GUI → OpenVINO
```

---

# 25. GUI Chat

功能：

- Model Selector
- Conversation
- Streaming
- Stop
- New Chat
- Input
- Send
- Parameters

中文：

```text
聊天
新建对话
发送
停止生成
输入消息...
```

英文：

```text
Chat
New Chat
Send
Stop Generation
Enter a message...
```

---

# 26. GUI Models

显示：

- Model Name
- Version
- Size
- Architecture
- Precision
- Device
- Status

操作：

```text
Import
Remove
Details
Run
```

---

# 27. GUI Devices

显示：

```text
CPU
GPU
NPU
AUTO
```

状态：

```text
Available
Unavailable
Active
```

同时尽可能展示真实硬件信息。

禁止伪造。

---

# 28. GUI Runtime

显示：

```text
Isvik Version
OpenVINO Version
Backend
Active Device
Loaded Models
Cache
Inference Status
Compilation Status
```

---

# 29. GUI Activity

使用结构化 Runtime Events。

事件：

```text
Runtime Started
Backend Loaded
Device Detected
Model Loaded
Compiling
Cache Hit
Cache Miss
Inference Started
Inference Finished
Error
```

GUI 不直接解析日志文件。

---

# 30. GUI Settings

至少：

```text
Language
Default Device
Model Directory
Cache Directory
Server Settings
Logging Level
```

---

# 31. GUI Internationalization

支持：

```text
zh-CN
en-US
```

所有用户可见文字必须来自：

```text
i18n.t(key)
```

禁止硬编码。

文件：

```text
locales/
├── zh-CN.json
└── en-US.json
```

必须检查：

```text
zh-CN keys == en-US keys
```

缺失 key：

- fallback English
- 或 `[missing.key]`

不能崩溃。

---

# 32. GUI Framework

如果已有 GUI Framework：

优先沿用。

如果没有：

评估：

- Slint
- WebView2
- wNim
- 其他 Nim-compatible GUI

评估：

- Nim integration
- Windows support
- Performance
- UI capability
- i18n
- Dependency size
- Maintenance
- Packaging

不要为了视觉效果牺牲 Runtime 架构。

---

# 33. Configuration

配置：

```text
~/.isvik/config/
```

至少：

```text
settings.json
```

包含：

```text
language
default_device
model_directory
cache_directory
server
logging
```

---

# 34. Logging

级别：

```text
DEBUG
INFO
WARN
ERROR
FATAL
```

输出：

- Console
- File

GUI Activity 使用结构化事件。

---

# 35. Benchmark

命令：

```bash
isvik benchmark <model>
```

指标：

```text
Model Load Time
Compile Time
First Inference Latency
Warm Inference Latency
Throughput
Tokens/sec
Memory
Cache Hit
Cache Miss
```

记录：

```text
Model
Model Hash
Isvik Version
OpenVINO Version
Backend
Device
Precision
OS
Warmup Count
Test Count
Timestamp
```

JSON 输出。

不得伪造数据。

---

# 36. Testing

建立：

```text
Unit Test
Runtime Test
Backend Test
Device Test
Model Test
Cache Test
Server Test
CLI Test
GUI Test
Integration Test
End-to-End Test
Benchmark
```

---

# 37. Regression Testing

每个 Bug：

```text
Bug
 ↓
Fix
 ↓
Regression Test
 ↓
Verify
```

禁止只修代码、不增加测试。

---

# 38. Security

默认 Server：

```text
127.0.0.1
```

必须防止：

- Path Traversal
- Invalid Path
- Malformed Manifest
- Malformed Model
- Cache Corruption
- Oversized Request
- Invalid JSON
- Arbitrary Command Execution

模型 metadata 不允许执行任意命令。

---

# 39. Windows First

第一目标：

```text
Windows x64
```

考虑：

- Windows paths
- UTF-8
- Unicode
- DLL loading
- OpenVINO Runtime
- Intel GPU Driver
- Intel NPU Driver
- User AppData
- Windows permissions
- Windows packaging

---

# 40. Nim

主要语言：

**Nim**

要求：

- 清晰
- 简洁
- 类型安全
- 明确资源生命周期
- 避免巨型 procedure
- 避免巨型 module
- 避免 global mutable state
- 避免重复代码
- 避免魔法数字

C interop 必须明确：

- ownership
- pointer lifetime
- allocation
- release

---

# 41. Dependency Policy

添加依赖前判断：

1. 是否真的需要
2. Nim 生态成熟度
3. Windows 支持
4. License
5. Maintenance
6. 是否可以使用标准库

能用标准库：

优先标准库。

---

# 42. License

不要复制第三方代码。

引入依赖：

必须检查 License。

模型 License 与 Isvik License 分开。

不要默认认为模型可以自由分发。

---

# 43. Documentation

必须维护：

```text
README.md

docs/
├── architecture.md
├── installation.md
├── quickstart.md
├── models.md
├── devices.md
├── npu.md
├── backends.md
├── configuration.md
├── api.md
├── cli.md
├── gui.md
├── benchmarking.md
├── troubleshooting.md
├── development.md
└── contributing.md
```

---

# 44. README

必须说明：

- Isvik 是什么
- 为什么做
- Isvik Core
- OpenVINO Backend
- Intel CPU/GPU/NPU
- 安装
- 快速开始
- Model System
- CLI
- GUI
- Local API
- NPU
- Benchmark
- Development
- Current Status
- Known Issues

不能写未经验证的宣传语。

---

# 45. 项目目录建议

如果现有结构允许：

```text
Isvik/
│
├── src/
│   ├── isvik/
│   │   ├── core/
│   │   │   ├── runtime/
│   │   │   ├── model/
│   │   │   ├── tensor/
│   │   │   ├── device/
│   │   │   ├── backend/
│   │   │   ├── execution/
│   │   │   ├── scheduler/
│   │   │   ├── cache/
│   │   │   ├── events/
│   │   │   └── errors/
│   │   │
│   │   ├── backends/
│   │   │   └── openvino/
│   │   │
│   │   ├── models/
│   │   ├── services/
│   │   ├── server/
│   │   ├── cli/
│   │   ├── config/
│   │   └── logging/
│   │
│   └── gui/
│
├── locales/
│   ├── zh-CN.json
│   └── en-US.json
│
├── tests/
│   ├── unit/
│   ├── core/
│   ├── backend/
│   ├── devices/
│   ├── models/
│   ├── cache/
│   ├── server/
│   ├── cli/
│   ├── gui/
│   └── integration/
│
├── docs/
├── examples/
├── scripts/
├── README.md
├── LICENSE
└── isvik.nimble
```

如果当前仓库结构更合理，不要机械重构。

---

# 46. 开发阶段

API 多协议兼容必须从架构阶段开始。

严格按照：

```text
PHASE 0  Repository Analysis
PHASE 1  Isvik Architecture + API Gateway Architecture
PHASE 2  Isvik Core + Unified Inference API
PHASE 3  Backend Abstraction
PHASE 4  OpenVINO Backend
PHASE 5  Device Manager
PHASE 6  NPU
PHASE 7  Model System
PHASE 8  Cache
PHASE 9  Hardware-aware Execution + Application Services
PHASE 10 API Gateway + Protocol Adapters
PHASE 11 Streaming + Tool Calling + Structured Output + Cancellation
PHASE 12 Local Server
PHASE 13 CLI
PHASE 14 Benchmark
PHASE 15 GUI
PHASE 16 Internationalization
PHASE 17 Integration + API Compatibility Testing
PHASE 18 Documentation + Release
```

PHASE 1 就必须定义：

```text
Protocol Adapter Interface
Unified Inference Request
Unified Inference Result
Inference Event Stream
Tool Model
Structured Output Model
Error Model
```

不能先完成单协议 API，再返工设计多协议兼容。

## 46.5 最终技术验收条件

在进入 Release 前，AI 必须逐项验证：

```text
[ ] Isvik Runtime 使用 Nim
[ ] Isvik Core 使用 Nim
[ ] API Gateway 使用 Nim
[ ] CLI 使用 Nim
[ ] GUI 使用 Nim
[ ] Isvik 基于 Resonance
[ ] Resonance 位于 OpenVINO C API 边界之上
[ ] OpenVINO 是 Backend，而不是 Core 的直接业务层
[ ] 无 Python Runtime 依赖
[ ] 无 Python inference server
[ ] 无 Python hidden runtime
[ ] 多协议 API 均通过 Adapter
[ ] Anthropic Messages API 已纳入架构
[ ] OpenAI Chat Completions 已纳入架构
[ ] OpenAI Responses 已纳入架构
[ ] Isvik Native API 已纳入架构
[ ] Streaming 使用统一 Event Stream
[ ] Tool Calling 使用统一 Tool Model
[ ] Structured Output 使用统一内部模型
[ ] TRAE 接入路径已验证
[ ] CPU / GPU / NPU Backend 路径已验证
[ ] API Compatibility Tests 已加入 CI / Release
```

如果其中任何一项违反 Architecture Hard Constraints，AI 必须停止继续扩展功能，先修正架构。

# 47. PHASE 0：Repository Analysis

第一步不要大规模写代码。

扫描：

- repository
- Nim project
- nimble
- src
- tests
- OpenVINO binding
- Runtime
- Model code
- GUI
- CI
- dependencies
- README
- licenses

判断：

```text
KEEP
REFACTOR
REPLACE
NEW
```

特别检查：

- `OVResonance`
- `ovr`
- Core / Backend 耦合
- 直接 OpenVINO 调用

输出：

```text
# Isvik Repository Analysis

## Existing Architecture

## Reusable Components

## Problems

## Risks

## Naming Migration

## Architecture Migration

## Development Plan
```

---

# 48. PHASE 1：Architecture

建立：

```text
Isvik Core
     ↓
Backend Abstraction
     ↓
OpenVINO Backend
```

定义：

- Core API
- Backend API
- Device API
- Model API
- Error API
- Event API

不要过度抽象。

---

# 49. PHASE 2：Isvik Core

实现：

- Runtime
- Model
- Device
- Tensor
- Error
- Event
- Execution

目标：

通过 Core API 描述完整 inference lifecycle。

---

# 50. PHASE 3：Backend Abstraction

实现 Backend interface。

第一实现：

```text
OpenVINO Backend
```

Core 不直接依赖 OpenVINO-specific types。

---

# 51. PHASE 4：OpenVINO Backend

实现：

```text
Initialize
Discover Devices
Load Model
Compile
Create Infer Request
Infer
Release
```

真实 Build + Test。

---

# 52. PHASE 5：Device Manager

实现：

```text
CPU
GPU
NPU
AUTO
```

获取真实设备信息。

---

# 53. PHASE 6：NPU

验证：

```text
Detect
Select
Compile
Infer
Cache
Error
```

没有真实 NPU 环境时：

不要伪造结果。

---

# 54. PHASE 7：Model System

实现：

```text
Model Manager
Manifest
Storage
Import
List
Info
Remove
Load
Unload
```

---

# 55. PHASE 8：Cache

实现：

```text
Model Cache
Compiled Cache
Invalidation
Integrity Check
Metrics
```

---

# 56. PHASE 9：Hardware-aware Execution

建立：

```text
Model Profile
+
Hardware Profile
+
Runtime Policy
```

形成：

```text
Device Selection
```

第一阶段保持简单、可解释。

---

# 57. PHASE 10：Application Services

建立：

```text
Model Service
Runtime Service
Device Service
Inference Service
Event Service
```

GUI / CLI / Server 统一调用。

---

# 58. PHASE 11：Local Server

实现：

```bash
isvik serve
```

完成：

- Health
- Version
- Models
- Devices
- Runtime
- Load
- Unload
- Generate
- Chat
- Streaming
- Cancellation
- Errors

---

# 59. PHASE 12：CLI

实现：

```bash
isvik version
isvik devices
isvik list
isvik info <model>
isvik import <model>
isvik pull <model>
isvik rm <model>
isvik run <model>
isvik ps
isvik stop <model>
isvik serve
isvik benchmark <model>
```

---

# 60. PHASE 13：Benchmark

实现真实 Benchmark。

禁止：

```text
Fake Benchmark
Hard-coded result
Invented NPU result
```

---

# 61. PHASE 14：GUI

实现正式 GUI。

GUI：

```text
GUI
 ↓
Client
 ↓
Local API
 ↓
Application Services
 ↓
Isvik Core
```

不要：

```text
GUI → OpenVINO
```

---

# 62. PHASE 15：Internationalization

完成：

```text
zh-CN
en-US
```

支持：

- GUI language switch
- CLI language
- Error localization
- Translation validation

---

# 63. PHASE 16：Integration Testing

验证完整链路：

```text
GUI
 ↓
API
 ↓
Services
 ↓
Core
 ↓
Backend
 ↓
OpenVINO
 ↓
CPU/GPU/NPU
```

同时验证：

```text
CLI
 ↓
Services
 ↓
Core
```

---

# 64. PHASE 17：Documentation

完成全部文档。

---

# 65. PHASE 18：Release

检查：

- Build
- Tests
- Packaging
- Documentation
- License
- Runtime
- Backend
- Device
- Model
- Cache
- GUI
- CLI
- API
- i18n

---

# 66. Build / Test Rule

每个主要阶段完成后：

```text
Build
 ↓
Unit Test
 ↓
Integration Test
 ↓
Architecture Review
 ↓
Fix
 ↓
Next Phase
```

如果当前环境无法运行某个硬件测试：

```text
NOT TESTED IN CURRENT ENVIRONMENT
```

不得声称通过。

---

# 67. Bug Handling

```text
Reproduce
 ↓
Analyze
 ↓
Fix
 ↓
Test
 ↓
Regression Test
```

不要删除测试来规避问题。

---

# 68. OpenVINO Error Handling

统一：

```text
OpenVINO error
 ↓
OpenVINO Backend
 ↓
Isvik Error
 ↓
Application Service
 ↓
API / CLI / GUI
```

上层不直接依赖 OpenVINO exception / native error。

---

# 69. Resource Ownership

所有 Native resource 必须明确：

```text
Create
 ↓
Owner
 ↓
Use
 ↓
Release
```

重点：

- Core
- Model
- Compiled Model
- Infer Request
- Tensor
- Native pointers
- DLL resources

---

# 70. Threading

Inference、HTTP、GUI 不能互相阻塞。

考虑：

- Async
- Worker
- Cancellation
- Queue
- Thread safety

但不要为了异步而引入不必要复杂度。

---

# 71. API Stability

Isvik Core API 必须：

- Small
- Clear
- Stable
- Testable

不要暴露 OpenVINO implementation details。

---

# 72. AI 自主开发规则

允许：

- 创建文件
- 修改文件
- 添加测试
- 修复 Bug
- 局部重构
- 更新文档
- 构建
- 测试

禁止：

- 删除有效功能
- 删除测试
- 擅自修改 License
- 大规模无必要重写
- 伪造功能
- 伪造测试
- 伪造 Benchmark
- 伪造 NPU
- 伪造硬件状态

---

# 73. 不确定时

优先：

```text
Correctness
>
Simplicity
>
Maintainability
>
Compatibility
>
Performance
>
Feature Count
```

涉及 OpenVINO：

优先当前版本官方资料和实际 API。

涉及 Nim：

优先当前 compiler / package 实际行为。

无法验证：

```text
UNVERIFIED
```

---

# 74. Architecture Review

每个主要阶段结束后：

```text
# Architecture Review

## Score

XX / 100

## Critical Issues

## High Issues

## Medium Issues

## Technical Debt

## Security Risks

## Performance Risks

## Next Step
```

---

# 75. 最终验收标准

```text
[ ] Isvik Core
[ ] Backend Abstraction
[ ] OpenVINO Backend
[ ] Runtime
[ ] CPU
[ ] GPU（硬件可用时）
[ ] NPU（硬件可用时）
[ ] AUTO Device Policy
[ ] Model Manager
[ ] Model Manifest
[ ] Model Storage
[ ] Model Cache
[ ] Compiled Cache
[ ] Hardware-aware Execution
[ ] Application Services
[ ] Local API
[ ] Streaming
[ ] Cancellation
[ ] CLI
[ ] GUI
[ ] Chat
[ ] Models
[ ] Devices
[ ] Runtime
[ ] Activity
[ ] Settings
[ ] zh-CN
[ ] en-US
[ ] Language Switch
[ ] Benchmark
[ ] Unit Tests
[ ] Integration Tests
[ ] End-to-End Tests
[ ] Security Checks
[ ] Documentation
[ ] Windows x64 Build
```

---

# 76. 最终用户体验

用户安装：

```text
Isvik
```

打开 GUI：

```text
Isvik

Chat
Models
Devices
Runtime
Activity
Settings
```

选择模型：

```text
Qwen
```

选择：

```text
AUTO
```

点击：

```text
Run
```

Isvik：

```text
Model
 ↓
Model Profile
 ↓
Hardware Detection
 ↓
Runtime Policy
 ↓
Device Selection
 ↓
Cache
 ↓
OpenVINO Backend
 ↓
Inference
```

用户无需理解 OpenVINO C API。

用户无需手动管理 Runtime。

---

# 77. 最终 CLI

```bash
isvik version
isvik devices
isvik list
isvik info qwen
isvik run qwen
isvik run qwen --device npu
isvik serve
isvik benchmark qwen
```

---

# 78. 最终产品结构

```text
                         Isvik
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
       GUI                CLI              Local API
        │                  │                  │
        └──────────────────┼──────────────────┘
                           │
                           ▼
                 Application Services
                           │
                           ▼
                     Isvik Core
                           │
             ┌─────────────┴─────────────┐
             │                           │
       Backend API                 Runtime Policy
             │                           │
             ▼                           │
      OpenVINO Backend ◄─────────────────┘
             │
       ┌─────┼─────┐
       ▼     ▼     ▼
      CPU   GPU   NPU
```

---

# 79. 产品边界

第一阶段专注：

> **Local AI Inference Runtime for Intel AI PCs**

不是：

- 云端 AI 平台
- 在线 SaaS
- 模型训练平台
- 大规模分布式推理平台
- 数据中心调度系统

核心：

```text
Native
Local
Runtime
Intel
OpenVINO
CPU
GPU
NPU
```

---

# 80. 创新方向

持续围绕：

1. Native Nim Runtime
2. Isvik Core + Backend Architecture
3. OpenVINO-first Intel acceleration
4. CPU / GPU / NPU unified execution
5. Hardware-aware Runtime Policy
6. Model + Compiled Cache
7. GUI + CLI + Local API unified architecture
8. Native Windows Intel AI PC experience

不要为了追求“创新”制造没有实际价值的复杂功能。

---

# 81. 不要复制 Ollama

可以参考：

- 产品易用性
- CLI 思路
- 本地 Server 思路
- Model Manager 思路

不能复制：

- Source Code
- Internal Implementation
- Private Protocol
- UI
- Manifest
- Model Format
- Branding

Isvik 必须拥有自己的：

```text
Core
Backend
Manifest
API
CLI
GUI
Cache
Runtime Policy
```

---

# 82. 每次任务结束后的报告

必须使用中文：

```markdown
# Isvik 本次开发报告

## 完成内容

## 修改文件

## 架构变化

## Build

## Tests

## Hardware Tests

## 已知问题

## 风险

## Architecture Review

## 下一阶段
```

---

# 83. 最终执行指令

现在开始执行 Isvik 开发。

**第一步不要大规模修改代码。**

先完整扫描当前仓库。

分析：

1. 当前项目结构
2. 当前 Nim 架构
3. 当前 OpenVINO 集成
4. 当前 Runtime
5. 当前模型处理
6. 当前 GUI
7. 当前测试
8. 当前依赖
9. 当前可以复用的代码
10. 当前需要重构的部分
11. 当前 `OVResonance` / `ovr` 遗留命名
12. 当前 Backend 与 Core 的耦合情况

然后建立：

```text
Isvik Development Plan
```

并从：

```text
PHASE 0
```

开始。

严格执行：

```text
Analyze
 ↓
Plan
 ↓
Implement
 ↓
Build
 ↓
Test
 ↓
Review
 ↓
Fix
 ↓
Next Phase
```

不要一次性生成大量未经验证的代码。

不要伪造测试。

不要伪造 NPU。

不要伪造 Benchmark。

不要把 GUI、CLI 或 Server 直接连接到 OpenVINO。

始终保持：

```text
Isvik = Local AI Runtime Platform

Isvik Core = Runtime Core

OpenVINO Backend = First-class Backend

Intel CPU/GPU/NPU = Core Hardware Target

GUI / CLI / Local API = Product Interfaces
```

现在开始。


# 68. Isvik 最终项目身份

```text
Project:
Isvik

Type:
Local AI Inference Runtime / Platform

Language:
100% Nim Runtime

Foundation:
Resonance

Backend:
OpenVINO

Hardware:
Intel CPU / GPU / NPU

API:
Anthropic Compatible
OpenAI Compatible
Isvik Native

Integration:
TRAE / IDE / Agent / CLI / GUI
```

一句话定位：

> **Isvik is a Nim-native local AI inference runtime built on Resonance, using OpenVINO as its hardware backend and exposing multi-protocol APIs for seamless integration with TRAE, IDEs, agents, and local AI applications.**
