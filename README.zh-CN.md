# Isvik

**技术概览** | [English](README.md)

Isvik 是一个使用 Nim 编写的本地 AI 推理运行平台。它通过随仓库提供的 Resonance C API 绑定连接 Intel OpenVINO，并提供交互式命令行和本地 HTTP API。项目的主要目标平台是 Intel AI PC 上的 Windows x64。

本文说明当前实现的架构、使用方式和验证边界。本文是项目文档，与 Google 无关联。

## 摘要

本地推理在用户设备上执行模型，网络服务是可选组件。Isvik 将模型管理、设备选择、生成、协议适配和测量集中在一个应用中。OpenVINO 和兼容模型文件需要单独准备；推理运行时不依赖 Python。

## 设计与范围

Isvik 将用户界面与推理及硬件访问分层：命令行和 HTTP 服务调用应用服务；应用服务使用核心运行时和后端接口；OpenVINO 后端通过 Resonance 调用 OpenVINO C API。架构测试检查预期的依赖边界。

```text
命令行 / 交互式工作台 / HTTP API
                 │
              应用服务
                 │
          核心运行时与后端接口
                 │
          OpenVINO 后端
                 │
      Resonance → OpenVINO C API
                 │
        CPU / Intel GPU / NPU
```

运行时提供模型导入与管理、设备发现与选择、文本生成、流式输出、采样和编译模型缓存。API 适配器实现了 OpenAI Chat Completions、OpenAI Responses、Anthropic Messages 和 Isvik 原生协议的部分功能。兼容范围以项目实际实现为准，接入方应验证自己的请求。

`AUTO` 按 NPU、Intel GPU、CPU 的顺序选择，实际结果取决于设备与模型兼容性。能够发现设备或编译模型，并不代表所有模型都能在该设备上生成文本。模型格式、架构、精度、驱动和可用内存都会影响结果。

## 平台与验证

仓库的 CI 配置覆盖 Windows 和 Linux。历史记录描述了在 Windows x64、Intel Core Ultra 7 270K Plus 和 OpenVINO 2026.3 环境下的测试：已测试 CPU 文本生成和 Intel GPU 推理，以及 NPU 枚举和静态 IR 编译；这不代表 NPU 的通用文本生成功能已验证。历史细节见 [DEVLOG.md](DEVLOG.md)。

2026 年 11 月 15 日，在 Linux x86-64、Nim 2.2.4 和 GCC 环境完成构建与启动。38 个测试文件运行完成，其中依赖特定环境的用例按条件跳过。使用 OpenVINO 2026.4.1 验证了 CPU 设备发现和合成 embedding IR 推理，包括多属性编译及缓存导出、导入。尚未验证大语言模型生成与分词器集成。检测到 NVIDIA RTX 5080，但 `AUTO` 策略将其排除，未测试其推理能力。

## 快速开始

在 Windows x64 上安装 Nim 2.2.4 或更高版本、Nimble、Git 和基于 GCC 的 MinGW 工具链。项目配置为 Windows ABI 封装指定了 GCC。OpenVINO 运行库和兼容模型需要单独准备；前提条件及限制见[安装指南](docs/installation.md)。

```powershell
git clone https://github.com/AbyssGG/Isvik.git
cd Isvik
.\scripts\fetch-deps.ps1 -What Runtime
nimble build
nimble test
.\isvik.exe doctor
.\isvik.exe
```

最后一条命令进入交互式工作台。使用 `help` 查看 CLI 命令；工作台中可使用 `-ls` 列出已导入模型、`-import <dir>` 导入模型、`-use <index|id>` 加载模型，以及 `-exit` 退出。生成文本需要兼容的 OpenVINO IR 模型和分词器；仓库不包含模型权重。

## 本地 API

启动带认证的 API 服务并管理密钥：

```powershell
.\isvik.exe api serve --port 7317
.\isvik.exe api key create --name client
.\isvik.exe api key list
```

服务提供 `/v1/chat/completions`、`/v1/responses`、`/v1/messages` 和 `/api/chat`，以及健康状态、模型、设备和运行时端点。导入兼容模型并启动服务后，可以发送例如以下请求：

```bash
curl http://127.0.0.1:7317/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer <API_KEY>' \
  -d '{"model":"<MODEL_ID>","messages":[{"role":"user","content":"Hello"}]}'
```

需要时可通过 `isvik api key show <id>` 查看密钥。`isvik serve` 是面向回环地址的无认证兼容模式。应根据部署环境保护密钥和模型数据。

## 测量

基准测试将预热与正式采样分开，并报告延迟和吞吐量统计：

```powershell
.\isvik.exe benchmark --runs 5 --warmup 1 --max-tokens 64
```

结果受模型、提示词、硬件、驱动、运行库版本及测量设置影响，不能保证其他配置取得相同结果。本次 Linux 测试未进入推理阶段，因此没有性能测量结果。

## 安全与运行边界

实现使用受管理的不透明句柄、路径校验和架构测试来减少部分错误。这些措施不构成安全保证，也不能代替部署审查。模型权重遵循各自的许可证，Isvik 不包含权重文件。漏洞报告方式见 [SECURITY.md](SECURITY.md)。

## 仓库结构

| 路径 | 用途 |
| --- | --- |
| `src/isvik/` | 运行时、后端、推理、服务、CLI 和服务器 |
| `Resonance/` | 随仓库提供的底层 OpenVINO 绑定 |
| `tests/` | 单元、集成和架构测试 |
| `scripts/` | Windows 依赖下载与模型校验脚本 |
| `docs/installation.md` | 安装和模型前提条件 |
| `DEVLOG.md` | 开发历史及先前测试记录 |

贡献方式见 [CONTRIBUTING.md](CONTRIBUTING.md)。Isvik 采用 [Apache License 2.0](LICENSE)。
