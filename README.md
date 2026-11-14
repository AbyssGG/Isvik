# Isvik

**Technical overview** | [简体中文](README.zh-CN.md)

Isvik is a local AI inference runtime written in Nim. It connects an interactive command line and a local HTTP API to Intel OpenVINO through the bundled Resonance C API binding. Its primary target is Windows x64 on Intel AI PCs.

This document describes the architecture, operational model, and validation boundaries of the current implementation. It is a project document and is not affiliated with Google.

## Abstract

Local inference keeps model execution on the user's machine and makes a network service optional. Isvik provides model management, device selection, generation, protocol adapters, and measurement in one application. OpenVINO and compatible model files are external dependencies. The project does not require Python at inference runtime.

## Design and scope

Isvik separates user interfaces from inference and hardware access. The command line and HTTP server call application services; services use the core runtime and backend interface; the OpenVINO backend uses Resonance to call the OpenVINO C API. Architecture tests check the intended dependency boundaries.

```text
CLI / interactive workbench / HTTP API
                  │
          Application services
                  │
       Core runtime and backend interface
                  │
           OpenVINO backend
                  │
        Resonance → OpenVINO C API
                  │
          CPU / Intel GPU / NPU
```

The runtime provides model import and management, device discovery and selection, text generation, streaming, sampling, and compiled-model caching. Its API adapters implement portions of OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, and a native Isvik protocol. Compatibility is limited to the features implemented by this project; clients should validate their specific requests.

`AUTO` prioritizes NPU, Intel GPU, and CPU subject to device and model compatibility. Device discovery or compilation does not establish that every model can generate on that device. Model format, architecture, precision, drivers, and available memory affect results.

## Platform and validation

The repository's CI targets Windows. Prior project records describe tests on Windows x64 with Intel Core Ultra 7 270K Plus and OpenVINO 2026.3: CPU text generation and Intel GPU inference were exercised; NPU enumeration and static IR compilation were exercised, but this does not establish general NPU text-generation support. See [DEVLOG.md](DEVLOG.md) for the historical context.

On 2026-11-15, this revision was tested on Linux x86-64 with Nim 2.2.4 and GCC. `nimble build` failed because the bundled `Resonance/src/resonance/perf_count_wrapper.c` uses Windows-only declarations unconditionally. `nimble test` passed its initial suites but stopped at the same compilation error in `tests/backends/tdevice_real.nim`. The application and end-to-end inference were therefore **not run on this Linux system**. An NVIDIA RTX 5080 was present; it was not tested for inference. These observations are specific to this environment.

## Getting started

For Windows x64, install Nim 2.0 or later, Nimble, Git, and a GCC-based MinGW toolchain. The project configuration selects GCC for the Windows ABI shim. Obtain the OpenVINO runtime and a compatible model separately; see the [installation guide](docs/installation.md) for prerequisites and limitations.

```powershell
git clone https://github.com/AbyssGG/Isvik.git
cd Isvik
.\scripts\fetch-deps.ps1 -What Runtime
nimble build
nimble test
.\isvik.exe doctor
.\isvik.exe
```

The final command opens the interactive workbench. Use `help` for the available CLI commands. In the workbench, `-ls` lists imported models, `-import <dir>` imports a model, `-use <index|id>` loads one, and `-exit` leaves the session. A compatible OpenVINO IR model and tokenizer are needed for generation; the repository does not contain model weights.

## Local API

Start the authenticated API service and manage keys with:

```powershell
.\isvik.exe api serve --port 7317
.\isvik.exe api key create --name client
.\isvik.exe api key list
```

The service exposes `/v1/chat/completions`, `/v1/responses`, `/v1/messages`, and `/api/chat`, together with health, model, device, and runtime endpoints. For example, after importing a compatible model and starting the service:

```bash
curl http://127.0.0.1:7317/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <API_KEY>' \
  -d '{"model":"<MODEL_ID>","messages":[{"role":"user","content":"Hello"}]}'
```

Use `isvik api key show <id>` to retrieve a key when needed. `isvik serve` is the unauthenticated compatibility mode intended for loopback use. Protect keys and model data according to the environment in which the service runs.

## Measurement

The benchmark command separates warmup from measured runs and reports latency and throughput statistics:

```powershell
.\isvik.exe benchmark --runs 5 --warmup 1 --max-tokens 64
```

Results depend on the model, prompt, hardware, drivers, runtime version, and measurement settings. They are not a guarantee for another configuration. The current Linux test did not reach inference and produced no performance measurements.

## Security and operational boundaries

The implementation uses managed opaque handles, path validation, and architecture tests to reduce classes of errors. These measures do not constitute a security guarantee or replace deployment review. Model weights are governed by their own licenses and are not included with Isvik. Report vulnerabilities using [SECURITY.md](SECURITY.md).

## Repository guide

| Path | Purpose |
| --- | --- |
| `src/isvik/` | Runtime, backend, inference, services, CLI, and server |
| `Resonance/` | Bundled low-level OpenVINO binding |
| `tests/` | Unit, integration, and architecture tests |
| `scripts/` | Windows dependency and model verification scripts |
| `docs/installation.md` | Installation and model prerequisites |
| `DEVLOG.md` | Development history and prior observations |

Contributions are described in [CONTRIBUTING.md](CONTRIBUTING.md). Isvik is distributed under the [Apache License 2.0](LICENSE).
