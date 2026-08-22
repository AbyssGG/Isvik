## 默认 Protocol Adapter 注册表
##
## §20.5.2 要求新协议**只能**通过 Adapter 加入。这个模块是那条规则的落点:
## 想让一个协议对外可用,必须在这里注册,而不是在 HTTP 层写一段特判。
##
## 注册表按协议名索引;重名会在构造时报错,避免出现「哪个生效」的不确定性。

import isvik/core/protocol
import isvik/protocol/native
import isvik/protocol/openai_chat
import isvik/protocol/openai_responses
import isvik/protocol/anthropic

export protocol, native, openai_chat, openai_responses, anthropic

proc newDefaultAdapterRegistry*(): AdapterRegistry =
  ## 构造包含全部已实现协议的注册表。
  ##
  ## 顺序不影响查找(按名字索引),但保持「自有协议在前」便于阅读:
  ## Isvik Native 是统一模型的直接映射,另外两个是兼容层。
  result = newAdapterRegistry()
  result.register(newNativeAdapter())
  result.register(newOpenAiChatAdapter())
  result.register(newOpenAiResponsesAdapter())
  result.register(newAnthropicAdapter())
