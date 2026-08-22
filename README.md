# Isvik

<p align="center">
  <strong style="font-size: 1.5em;">High-Performance Native Local AI Inference Runtime for Intel AI PCs</strong>
  <br>
  <i>100% Pure Nim · Zero Python Runtime Dependency · Built on Intel OpenVINO C API · Tailored for CPU / iGPU / NPU</i>
</p>

<p align="center">
  <a href="https://github.com/AbyssGG/Isvik/releases"><img src="https://img.shields.io/badge/version-0.1.0-blue.svg?style=flat-square" alt="Version"></a>
  <a href="https://nim-lang.org/"><img src="https://img.shields.io/badge/Nim-2.0+-orange.svg?style=flat-square&logo=nim" alt="Nim"></a>
  <a href="https://www.intel.com/content/www/us/en/developer/tools/openvino-toolkit/overview.html"><img src="https://img.shields.io/badge/Backend-OpenVINO_2026.3-0071C5.svg?style=flat-square&logo=intel" alt="Intel OpenVINO"></a>
  <a href="https://github.com/AbyssGG/Isvik/blob/main/LICENSE"><img src="https://img.shields.io/badge/License-Apache_2.0-green.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/AbyssGG/Isvik/actions"><img src="https://img.shields.io/badge/CI-Passing-brightgreen.svg?style=flat-square" alt="CI"></a>
</p>

<p align="center">
  <a href="./README.md"><b>English</b></a> | <a href="./README.zh-CN.md"><b>简体中文</b></a>
</p>

---

## 🌟 What is Isvik?

**Isvik** is a high-performance, ultra-lightweight, single-binary local AI inference runtime platform built 100% in **Nim**.

Leveraging the low-level library **[Resonance](https://github.com/AbyssGG/Resonance)** to interface directly with the OpenVINO C API, Isvik is engineered specifically for **Intel AI PCs (Intel Core / Core Ultra)** to provide unified, deeply optimized local AI inference across **CPU, iGPU (Arc, Iris Xe), and NPU (Intel AI Boost)**.

### Key Highlights

* ⚡ **100% Native Pure Compiled Binary**: No bulky Python virtual environments, no Node.js/Electron overhead. Sub-100ms cold starts with minimal memory and system footprint.
* 🎯 **Intel Hardware Auto-Scheduling**: Intelligent `AUTO` device pipeline (`NPU → Intel GPU → CPU`), precise vendor discrimination (`0x8086` Intel only, excluding discrete NVIDIA GPUs from Intel targets), with automated CPU fallback on iGPU single memory allocation limits (4 GiB).
* 🖥️ **Interactive Terminal Workbench & REPL**: Modern interactive shell with numbered model selector (`[1] [2]`), one-click model swapping, bilingual interface (`zh-CN` / `en-US`), session memory, and streaming generation.
* 🔌 **Unified Multi-Protocol Local API Server**: Built-in HTTP server with native compatibility for **OpenAI Chat Completions**, **OpenAI Responses**, and **Anthropic Messages** protocols. Drop-in ready for **TRAE IDE**, **Continue.dev**, **Open WebUI**, **Cherry Studio**, and custom clients.
* 🛡️ **Industrial-Grade Safety**: Safe opaque integer handles (zero use-after-free, double free, or dangling pointers), strict path traversal defenses against UNC injection, NTFS alternate data streams, and Windows reserved device names.
* 📊 **Zero-BS Benchmark Suite**: Honest real-world benchmarking engine distinguishing warmup cycles from statistically sound p50/p95 latency and token decoding rates.

---

## 📑 Table of Contents

- [Hardware & Feature Matrix](#-hardware--feature-matrix)
- [System Architecture](#-system-architecture)
- [Quick Start](#-quick-start)
  - [Prerequisites](#1-prerequisites)
  - [Fetch Dependencies & OpenVINO Runtime](#2-fetch-dependencies--openvino-runtime)
  - [Build & Run](#3-build--run)
- [Interactive Workbench (REPL)](#-interactive-workbench-repl)
- [Local API Server & Client Integration](#-local-api-server--client-integration)
  - [Start Server & API Key Management](#start-server--api-key-management)
  - [API Endpoints](#api-endpoints)
  - [Client Integration (e.g. TRAE IDE)](#client-integration-eg-trae-ide)
  - [cURL Examples](#curl-examples)
- [Benchmarks](#-benchmarks)
- [Safety & Architecture Guarantees](#-safety--architecture-guarantees)
- [Project Layout](#-project-layout)
- [Contributing](#-contributing)
- [License](#-license)

---

## 📊 Hardware & Feature Matrix

### 1. Hardware Verification (Tested on Intel Core Ultra 7 270K Plus)

| Hardware Device | Detected Name / Architecture | Driver Version | Inference & Generation Status |
| :--- | :--- | :--- | :--- |
| **Intel CPU** | `Intel(R) Core(TM) Ultra 7 270K Plus (intel64)` | System Native | ✅ **Verified (End-to-end text generation, streaming, API server)** |
| **Intel iGPU** | `Intel(R) Graphics (GPU: vendor=0x8086 arch=v12.70.4)` | `32.0.101.8864` | ✅ **Verified (AUTO scheduling, compilation, & inference)** |
| **Intel NPU** | `Intel(R) AI Boost (3720)` | `32.0.100.4841` | 🔄 **Connected (Device enumeration & static IR compilation supported)** |
| **OpenVINO** | `2026.3.0-22451` | C API Binding | ✅ **Verified (Runtime dynamic loading; graceful error without crashing)** |

### 2. Core Feature Matrix

| Feature | Status | Description |
| :--- | :---: | :--- |
| **End-to-End LLM Generation** | ✅ | Tokenizer IR, Embeddings, Transformer decoding loop, and pure Nim detokenization |
| **Interactive Terminal Workbench** | ✅ | `-ls`, `-use`, `-stop`, `-devices`, `-info`, bilingual interface switcher |
| **OpenAI Chat Completions** | ✅ | `/v1/chat/completions` (streaming SSE with `stream: true` & non-streaming) |
| **OpenAI Responses API** | ✅ | `/v1/responses` |
| **Anthropic Messages API** | ✅ | `/v1/messages` (supports Anthropic SSE blocks, tool_use schema, 529 status) |
| **Isvik Native Protocol** | ✅ | `/api/chat` lossless unified format |
| **Sampling Methods** | ✅ | Deterministic Greedy, Temperature, Top-P, Top-K sampling with reproducible seeds |
| **Tool Calling** | ✅ | Structured prompt injection with safe envelope parsing (OpenAI & Anthropic formats) |
| **Compiled Cache** | ✅ | Automatic `.blob` model cache with hardware signatures & SHA-256 integrity verification |
| **API Key Authentication** | ✅ | Local secure key generation, retrieval, revocation, and automated provisioning |

---

## 🏗️ System Architecture

Isvik strictly adheres to layered boundaries mechanically enforced by automated architecture tests:

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
│     (src/isvik/backends/openvino/ - Sole importer of Resonance)│
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

## 🚀 Quick Start

### 1. Prerequisites

Isvik is optimized for Windows x64. The required toolchain:

* **Nim**: `>= 2.0.0` (2.2+ recommended)
* **C Compiler**: **GCC (MinGW-w64)** (`tdm64-1 10.3.0` or higher recommended).
  > ⚠️ **Note**: Due to Windows x64 variadic ABI differences between MSVC and MinGW, GCC is strictly required for the OpenVINO C ABI shim. Do not use `--cc:vcc`.
* **Git**: Installed and available in PATH.

### 2. Fetch Dependencies & OpenVINO Runtime

Isvik provides an automated PowerShell script to retrieve the official OpenVINO 2026.3 Runtime & Tokenizers package:

```powershell
# Downloads and extracts OpenVINO Runtime + Tokenizers into runtime/
.\scripts\fetch-deps.ps1 -What Runtime
```

> 💡 **Tip**: The script safely adds the extracted `runtime/openvino/` path to your user-level PATH. Please restart your terminal window afterwards.

### 3. Build & Run

From the repository root:

```powershell
# 1. Build isvik.exe
nimble build

# 2. Run test suites (38 test suites covering architecture, safety, protocols)
nimble test

# 3. Launch Isvik Workbench
.\isvik.exe
```

---

## 💬 Interactive Workbench (REPL)

Run `isvik.exe` without arguments to enter the interactive workbench:

```powershell
.\isvik.exe
```

```text
  ___          _ _
 |_ _|_____   _(_) | __
  | |/ __\ \ / / | |/ /
  | |\__ \\ V /| |   <
 |___|___/ \_/ |_|_|\_\   Local AI Runtime for Intel AI PC

isvik[No Model@AUTO]> -ls
Imported Models:
  Index  Model ID                       Size       Supported Devices
  [1]    gemma-4-e2b-it-int4-ov         1.8 GB     CPU, GPU.0, NPU
  [2]    qwen2.5-1.5b-instruct-ov       1.1 GB     CPU, GPU.0

isvik[No Model@AUTO]> 1
[INFO] Compiling model to CPU ... Done (870ms)
isvik[gemma-4-e2b-it-int4-ov@CPU]> What is local AI inference?

Local AI inference is running machine learning models directly on the user's
endpoint device (such as an Intel AI PC with CPU, iGPU, or NPU), without
sending sensitive prompts or data to external cloud servers.

isvik[gemma-4-e2b-it-int4-ov@CPU]>
```

### Key Workbench Commands

| Command | Alias / Note | Description |
| :--- | :--- | :--- |
| `-ls` | `-models` | List imported models with `[1]` `[2]` index numbers |
| `-use <index\|id>` | `1`, `2` | Load a model (just enter the number when idle) |
| `-stop` | `-unload` | Unload active model to release RAM / VRAM |
| `-devices` | `-doctor` | Inspect available hardware devices & OpenVINO runtime status |
| `-info [id]` | - | View current session context or model details |
| `-import <dir>` | - | Import an OpenVINO IR model directory |
| `-rm <id>` | - | Remove model metadata from storage |
| `-new` | `/new` | Reset conversation context for a new session |
| `-history` | `/history` | View multi-turn conversation history |
| `-system [text]`| `/system` | View, set, or clear system prompt |
| `-key <action>` | - | Manage API Keys (`create`, `list`, `show`, `revoke`) |
| `-serve` | - | Launch the Local API Server in the foreground |
| `-lang <zh\|en>`| - | Switch language and persist to `settings.json` |
| `-exit` | `/exit`, `quit` | Exit the workbench |

---

## 🔌 Local API Server & Client Integration

Isvik includes a built-in Local API Server providing standard HTTP/REST and SSE streaming endpoints.

### Start Server & API Key Management

```powershell
# Start with API Key authentication on port 7317 (auto-generates a key if none exist)
.\isvik.exe api serve --port 7317

# Create named API Keys
.\isvik.exe api key create --name trae-client
.\isvik.exe api key list
.\isvik.exe api key show 1

# Start in compatible mode without auth (loopback only)
.\isvik.exe serve --port 7317
```

### API Endpoints

| Protocol | Method | Path | Description |
| :--- | :---: | :--- | :--- |
| **OpenAI Compatible** | `POST` | `/v1/chat/completions` | Standard chat completions (streaming & non-streaming) |
| **OpenAI Alias** | `POST` | `/chat/completions` | Alias for clients omitting `/v1` prefix |
| **OpenAI Responses** | `POST` | `/v1/responses` | OpenAI Responses API endpoint |
| **Anthropic Compatible**| `POST` | `/v1/messages` | Messages API endpoint (supports tool calling & SSE) |
| **Isvik Native** | `POST` | `/api/chat` | Native unified inference interface |
| **System & Health** | `GET` | `/api/health` | Service health and active model status |
| **System & Health** | `GET` | `/api/version` | Runtime version & protocol capability declarations |
| **Model Management** | `GET` | `/api/models` | List all imported models |
| **Model Management** | `POST` | `/api/load` | Dynamically load a model |
| **Model Management** | `POST` | `/api/unload` | Unload active model to free resources |
| **Hardware Monitor** | `GET` | `/api/devices` | Enumerate hardware devices & status |
| **Runtime Status** | `GET` | `/api/runtime` | Active model and physical execution device |

---

### Client Integration (e.g. TRAE IDE)

In **TRAE IDE** (or Continue.dev / Cherry Studio), go to `Settings > Models > Add Custom Model`:

#### Option A: OpenAI Chat Completions Format (Recommended)
* **Provider / Format**: `OpenAI`
* **Base URL**: `http://127.0.0.1:7317/v1`
* **Full URL switch**: `Disabled` (client automatically appends `/chat/completions`)
* **Model ID**: Enter the model ID from `isvik list` (e.g. `gemma-4-e2b-it-int4-ov`)
* **API Key**: Enter the `isvk_...` key from `isvik api key show 1`

#### Option B: Anthropic Messages Format
* **Provider / Format**: `Anthropic`
* **Base URL**: `http://127.0.0.1:7317`
* **Full URL switch**: `Disabled` (client automatically appends `/v1/messages`)
* **Model ID**: Enter the model ID
* **API Key**: Enter the `isvk_...` key (`Authorization: Bearer` and `x-api-key` supported)

---

### cURL Examples

#### 1. OpenAI Format Streaming Request

```bash
curl -X POST http://127.0.0.1:7317/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_ISVIK_API_KEY>" \
  -d '{
    "model": "gemma-4-e2b-it-int4-ov",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Explain the architecture of Intel NPUs."}
    ],
    "stream": true,
    "temperature": 0.7
  }'
```

#### 2. Anthropic Messages Request

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

## 📈 Benchmarks

Isvik provides a built-in benchmark tool that reports statistically sound p50/p95 latency and token decoding rates with warmup isolation:

```powershell
# Run benchmark (5 runs + 1 warmup)
.\isvik.exe benchmark --runs 5 --warmup 1 --max-tokens 64

# Output structured JSON for automation
.\isvik.exe --json benchmark gemma-4-e2b-it-int4-ov
```

**Measured Performance (Intel Core Ultra 7 270K Plus, Gemma 4 E2B INT4):**

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

## 🛡️ Safety & Architecture Guarantees

1. **Opaque Handles & Memory Safety**: Higher layers do not touch raw C pointers directly. Opaque IDs (`ModelId`, `CompiledModelId`, `InferRequestId`) are managed by the runtime with cascading cleanup on unloads.
2. **Anti Path-Traversal Protection**: All paths pass through `safeJoin` validation to eliminate directory climbing (`..`), UNC injection, NTFS Alternate Data Streams (`:stream`), and Windows reserved device names (`CON`, `NUL`, `COM1`).
3. **Automated Architectural Linter**: Verified continuously by `tests/architecture/tarchitecture.nim` to ensure zero illegal dependencies across internal boundaries.

---

## 📁 Project Layout

```text
Isvik/
├── src/
│   ├── isvik.nim                  # Library root entry
│   └── isvik/
│       ├── version.nim            # Single source of truth for versioning
│       ├── core/                  # Isvik Core (Runtime, DeviceManager, Tensor)
│       ├── backends/              # Backends (openvino/, mock/)
│       ├── inference/             # Inference orchestration (Tokenizer, Decoders)
│       ├── models/                # Model Manifest & Storage
│       ├── cache/                 # Compiled Model Cache (.blob)
│       ├── protocol/              # Multi-protocol adapters (OpenAI, Anthropic, Native)
│       ├── services/              # Application services (ChatSession, ModelService)
│       ├── server/                # Local API HTTP server
│       ├── cli/                   # CLI & Interactive Workbench
│       ├── config/                # Settings & path management
│       ├── logging/               # Multi-sink structured logging
│       └── i18n/                  # Localization (zh-CN, en-US)
├── Resonance/                     # Low-level OpenVINO C API Nim binding
├── tests/                         # Automated test suites (38 test files)
├── scripts/                       # Dependency automation scripts
├── docs/                          # Installation & deep-dive guides
├── isvik.nimble                   # Package definition
└── nim.cfg                        # Compiler configuration & paths
```

---

## 🤝 Contributing

Contributions to Isvik are warmly welcomed!

1. Please read [CONTRIBUTING.md](./CONTRIBUTING.md) for contribution guidelines.
2. Check [DEVLOG.md](./DEVLOG.md) for design decisions and verified hardware behavior.
3. Review our [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md).
4. Run `nimble test` locally before submitting a Pull Request.

---

## 📄 License

Isvik is licensed under the **[Apache License 2.0](./LICENSE)**.

> *Note: Model weights (Gemma, Qwen, etc.) are governed by their respective author licenses.*
