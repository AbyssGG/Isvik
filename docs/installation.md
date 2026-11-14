# Installation and validation

This guide covers the repository's Windows x64 workflow. For the architecture and platform test results, see the [technical overview](../README.md) or its [Chinese translation](../README.zh-CN.md).

## Prerequisites

- Windows x64, Nim 2.2.4 or later, Nimble, Git, and a GCC-based MinGW toolchain. `nim.cfg` selects GCC for the Windows ABI shim.
- OpenVINO Runtime and Tokenizers compatible with the model and target device. The repository does not include these binaries.
- A compatible OpenVINO IR model and tokenizer files. Model architecture, precision, device support, and license must be checked for the selected model.
- Intel GPU or NPU drivers when using those devices. Availability and model compilation do not establish end-to-end generation support.

## Build and inspect

From the repository root in PowerShell:

```powershell
.\scripts\fetch-deps.ps1 -What Runtime
nimble build
nimble test
.\isvik.exe doctor
.\isvik.exe devices
```

The download script retrieves the Windows OpenVINO GenAI package, which includes Runtime and Tokenizers, and places runtime files under `runtime/openvino/`. Consult the script before running it for its current version, network and PATH behavior. If the runtime cannot be loaded, inspect `doctor` output and ensure the DLLs and their dependencies are discoverable by the process.

## Models

The optional download script supports named model selections. For example:

```powershell
.\scripts\fetch-deps.ps1 -What Model -Model small -TryHuggingFace
.\isvik.exe import <model-directory>
.\isvik.exe list
```

Check the script's supported selections and the model's own documentation before downloading. The `verify-model.ps1` script currently supports `gemma4-e2b`; its file checks do not prove that a model is compatible with every device or generation path. Models with multiple IR components, including multimodal architectures, require the corresponding orchestration to be implemented and validated. NPU models may require specific shapes and quantization. Start with a supported single-IR text model, then validate other model and device combinations independently.

## Linux status

Linux x86-64 can build with Nim 2.2.4 or later and GCC. Install a compatible OpenVINO runtime separately and make `libopenvino_c.so` and its dependencies discoverable through the dynamic loader (for example, using the distribution's library configuration or `LD_LIBRARY_PATH`). The exact setup depends on the runtime distribution; some provide only a versioned library and require the usual unversioned development symlink. For tokenizer-based generation, supply `libopenvino_tokenizers.so` in a searched directory or set `ISVIK_TOKENIZERS_DLL` to its full path.

```bash
nimble build
nimble test
./isvik doctor
./isvik devices
```

On 2026-11-15, CPU device discovery and inference with a synthetic embedding IR were verified using OpenVINO 2026.4.1. LLM generation and tokenizer integration have not yet been verified on Linux.

## Related material

- [Technical overview](../README.md) and [Chinese overview](../README.zh-CN.md)
- [Development history](../DEVLOG.md)
- [Contribution guide](../CONTRIBUTING.md)
