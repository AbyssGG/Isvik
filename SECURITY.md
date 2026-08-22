# Security Policy

## Supported Versions

We actively support the latest release branch of **Isvik** with security fixes.

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |
| < 0.1   | :x:                |

---

## Reporting a Vulnerability

The security of Isvik and the protection of user systems running local AI workloads is of utmost importance.

If you believe you have found a security vulnerability in Isvik (such as path traversal, memory corruption, unauthorized API escalation, or remote execution flaws):

1. **Please do NOT open a public GitHub issue.**
2. Report the vulnerability privately via **GitHub Security Advisories** on the repository, or email the maintainers directly.
3. Include detailed steps to reproduce the issue, environment information (OS, Nim version, OpenVINO version, hardware specifications), and a minimal proof-of-concept if possible.

---

## Security Practices in Isvik

* **Path Traversal Defense**: All file and directory operations passing through user or API parameters are checked via `safeJoin` to mitigate directory traversal, NTFS alternate data streams, UNC network paths, and Windows reserved filenames.
* **Opaque Handle Model**: Resource handles are managed via internal lookup tables to prevent use-after-free or memory corruption from invalid API caller pointers.
* **API Key Isolation**: Local API server keys are hashed with SHA-256 for validation.
