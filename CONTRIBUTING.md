# Contributing to Isvik

Thank you for your interest in contributing to **Isvik**! We welcome contributions ranging from bug fixes, documentation enhancements, device acceleration features, to protocol integrations.

---

## 🧭 Development Principles

Isvik enforces strict architectural boundaries to maintain high performance, reliability, and security:

1. **Layering Integrity**:
   - `src/isvik/core/` must NEVER depend on CLI, HTTP Server, UI, or specific backend implementations.
   - The only place allowed to import `Resonance` or call OpenVINO C API is `src/isvik/backends/openvino/`.
   - Never introduce Python dependencies or spawn external Python processes (`osproc` is restricted).
   - These rules are mechanically enforced by `tests/architecture/tarchitecture.nim`.

2. **Resource & Memory Safety**:
   - Do not pass raw C pointers to higher layers. Always use opaque integer handles (`ModelId`, `CompiledModelId`, `InferRequestId`).
   - All input paths must be sanitized using `safeJoin` (`src/isvik/core/paths.nim`) to prevent path traversal.

3. **Compiler & Toolchain**:
   - Nim `>= 2.0.0` (with `--mm:orc`).
   - C Compiler must be **GCC (MinGW-w64)** on Windows x64. Do not use `--cc:vcc`.

---

## 🛠️ Getting Started

### 1. Fork and Clone

```bash
git clone https://github.com/AbyssGG/Isvik.git
cd Isvik
```

### 2. Fetch OpenVINO Dependencies

```powershell
.\scripts\fetch-deps.ps1 -What Runtime
```

### 3. Build & Test

Ensure all tests pass before making changes:

```powershell
nimble build
nimble test
```

---

## 🧪 Testing Guidelines

* **Unit Tests**: Place in `tests/unit/` for pure components (logging, paths, config, settings).
* **Core & Architecture**: Place in `tests/core/` and `tests/architecture/`.
* **MockBackend**: Use `MockBackend` for testing runtime lifecycle, failure injection, and memory cleanup without requiring physical hardware.
* All test files must start with `t` (e.g. `tpaths.nim`) to be automatically discovered by `nimble test`.

---

## 📦 Pull Request Process

1. Create a feature branch from `main` (`git checkout -b feature/your-feature-name`).
2. Implement your changes following standard Nim style conventions.
3. Add relevant test cases covering both success and error paths.
4. Run `nimble test` and `nimble tabcheck` locally.
5. Commit your changes with clear, descriptive commit messages.
6. Open a Pull Request on GitHub against `main`.

---

## 💬 Community & Code of Conduct

Please note that this project is released with a [Contributor Code of Conduct](./CODE_OF_CONDUCT.md). By participating in this project, you agree to abide by its terms.
