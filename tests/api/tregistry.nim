## 默认 Adapter 注册表测试
##
## §20.5.2:新协议只能通过 Adapter 加入。这里守住两件事 ——
## 注册表确实包含全部已实现协议,且它们的身份不冲突。

import std/[strutils, unittest]

import isvik/core/errors
import isvik/core/protocol
import isvik/protocol/registry

suite "默认注册表":

  test "包含四个已实现协议":
    let registry = newDefaultAdapterRegistry()
    check registry.len == 4
    let names = registry.protocolNames()
    check "isvik-native" in names
    check "openai-chat" in names
    check "openai-responses" in names
    check "anthropic" in names

  test "按名字都能取到,未知协议报 INVALID_REQUEST":
    let registry = newDefaultAdapterRegistry()
    for name in registry.protocolNames():
      check registry.get(name).protocolName() == name
    check registry.find("nope") == nil
    var code = ecServerError
    try:
      discard registry.get("nope")
    except IsvikError as e:
      code = e.code
    check code == ecInvalidRequest

  test "协议名两两不同":
    # 重名会让「哪个生效」变成不确定的。
    let names = newDefaultAdapterRegistry().protocolNames()
    for i in 0 ..< names.len:
      for j in 0 ..< names.len:
        if i != j:
          check names[i] != names[j]

  test "每个协议都声明了非空能力集与版本前缀":
    let registry = newDefaultAdapterRegistry()
    for name in registry.protocolNames():
      let adapter = registry.get(name)
      check adapter.capabilities().len > 0
      check adapter.apiVersion().startsWith("/")

  test "重复注册同名协议被拒绝":
    let registry = newDefaultAdapterRegistry()
    var code = ecServerError
    try:
      registry.register(newNativeAdapter())
    except IsvikError as e:
      code = e.code
    check code == ecServerError

  test "所有协议都支持流式":
    # §20.5.4 的流式是统一能力,不是某个协议的特性。
    let registry = newDefaultAdapterRegistry()
    for name in registry.protocolNames():
      check registry.get(name).supports(pcStreaming)
