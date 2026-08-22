## Isvik 库入口
##
## Isvik 是面向 Intel AI PC 的本地 AI 推理运行平台,采用 100% Nim 实现,
## 以 Resonance 作为基础库,以 OpenVINO 作为 Backend。
##
## 分层(Master Prompt §5):
##
## ```text
## GUI / CLI / Local API
##          ↓
## Application Services
##          ↓
##     Isvik Core
##          ↓
## Backend Abstraction
##          ↓
##  OpenVINO Backend
##          ↓
##     Resonance
##          ↓
##   OpenVINO C API
## ```
##
## 该入口只重导出稳定的公共类型与常量,不重导出任何 Backend 实现,
## 以确保上层无法经由 `import isvik` 间接触及 OpenVINO 相关类型。

import isvik/version

export version
