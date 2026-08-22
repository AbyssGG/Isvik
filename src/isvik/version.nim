## Isvik 版本与产品标识的唯一来源。
##
## 该文件被 `isvik.nimble` 以 `include` 方式引用,因此版本号在整个项目中
## 只有一处定义:修改此处即同时改变 nimble 包版本、CLI 输出与运行时上报。
##
## 注意:此模块不得 import 任何 Isvik 内部模块,以免 nimble 的
## NimScript 求值环境被无法解析的依赖污染。

const
  IsvikProductName* = "Isvik"
    ## 正式产品名称。Master Prompt §1 规定统一使用 "Isvik",
    ## 禁止使用历史名称 OVResonance / ovr。

  IsvikCliName* = "isvik"
    ## 正式 CLI 可执行文件名称。

  IsvikVersion* = "0.1.0"
    ## Isvik 语义化版本号。

  IsvikDescription* = "Local AI Runtime Platform for Intel AI PCs"
    ## 英文一句话定位,用于 nimble 包描述与 CLI 输出。

  IsvikDescriptionZhCn* = "面向 Intel AI PC 的本地 AI 推理运行平台"
    ## 中文一句话定位。
