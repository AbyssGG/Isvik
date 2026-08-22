## 生成编排相关测试。
##
## 分两层:
##
## 1. **纯单元测试** —— `gen_defaults` 与 `chat_format` 不碰模型,始终运行。
## 2. **真机集成测试** —— 需要真实组合模型,由环境变量
##    `ISVIK_TEST_MODEL_DIR` 开启。未设置时跳过并**明确说明跳过原因**,
##    不假装通过(§13)。

import std/[unittest, os, strutils, math]

import isvik/core/errors
import isvik/inference/gen_defaults
import isvik/inference/chat_format

suite "生成默认值:eos_token_id 必须支持多值":

  test "数组形式的 eos 全部读出":
    # 真实 Gemma 4 E2B 的值。只认其中一个会导致生成永不停止。
    let d = parseGenerationDefaults("""
      {"bos_token_id": 2, "eos_token_id": [1, 106, 50], "pad_token_id": 0}
    """, "test")
    check d.eosTokenIds == @[1, 50, 106]   # 去重后升序
    check d.bosTokenId == 2
    check d.padTokenId == 0
    check d.hasEos
    check d.hasBos
    check d.hasPad

  test "单值形式的 eos 也要读出":
    # 只处理数组会在单值模型上静默丢掉唯一的 EOS。
    let d = parseGenerationDefaults("""{"eos_token_id": 2}""", "test")
    check d.eosTokenIds == @[2]

  test "eos 去重并排序,使相等性可比较":
    let d = parseGenerationDefaults("""{"eos_token_id": [7, 1, 7, 3]}""", "test")
    check d.eosTokenIds == @[1, 3, 7]

  test "isEos 对每一个声明的 id 都成立":
    let d = parseGenerationDefaults("""{"eos_token_id": [1, 106, 50]}""", "test")
    for id in [1, 50, 106]:
      check d.isEos(id)
    check not d.isEos(0)
    check not d.isEos(105)

  test "未声明 eos 时 isEos 恒假,且 hasEos 为假":
    # 这两件事必须能被调用方区分:「没声明 EOS」与「声明了但没命中」
    # 是不同的事实,停止原因也不同。
    let d = parseGenerationDefaults("""{"bos_token_id": 1}""", "test")
    check not d.hasEos
    check not d.isEos(1)

  test "缺失字段表示未知,而不是回落到某个默认值":
    let d = parseGenerationDefaults("{}", "test")
    check d.bosTokenId == -1
    check d.padTokenId == -1
    check d.eosTokenIds.len == 0
    check d.temperature.isNaN
    check d.topP.isNaN
    check d.topK == -1

  test "采样参数被读出但仅作记录":
    # Isvik 只实现贪心。读出这些值是为了如实回报「模型建议了什么」,
    # 不是为了声称支持温度采样。
    let d = parseGenerationDefaults("""
      {"temperature": 1.0, "top_k": 64, "top_p": 0.95}
    """, "test")
    check d.temperature == 1.0
    check d.topK == 64
    check abs(d.topP - 0.95) < 1e-9

  test "非法 JSON 抛 MODEL_INVALID":
    expect IsvikError:
      discard parseGenerationDefaults("{ not json", "test")

  test "顶层不是对象时抛 MODEL_INVALID":
    expect IsvikError:
      discard parseGenerationDefaults("[1,2,3]", "test")

  test "目录里没有 generation_config.json 时返回未知而不报错":
    let dir = getTempDir() / "isvik-gendefaults-empty"
    createDir(dir)
    defer: removeDir(dir)
    let d = loadGenerationDefaults(dir)
    check not d.isKnown
    check not d.hasEos

  test "读到文件时 source 记录来源路径":
    let dir = getTempDir() / "isvik-gendefaults-real"
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / GenerationConfigFile, """{"eos_token_id": [1, 106]}""")
    let d = loadGenerationDefaults(dir)
    check d.isKnown
    check d.source.endsWith(GenerationConfigFile)
    check d.eosTokenIds == @[1, 106]

suite "对话格式:识别已知格式,不解释 Jinja":

  test "识别 Gemma 4 的 turn 标记":
    check detectChatFormat("{{- '<|turn>' + role }} ... {{- '<turn|>\\n' -}}") ==
      cfGemmaTurn

  test "Gemma 3 的标记不算 Gemma 4 格式":
    # 这个区别是实打实踩到的:用 <start_of_turn> / <end_of_turn> 时
    # tokenizer 不认识它们,会按普通文本切碎,输出多出一段垃圾且不报错。
    check detectChatFormat(
      "<start_of_turn>user\n{{ content }}<end_of_turn>") == cfUnknown

  test "空模板算未知":
    check detectChatFormat("") == cfUnknown

  test "Gemma turn 渲染结构正确":
    let out1 = renderGemmaTurn(
      [ChatMessage(role: crUser, content: "hi")], addGenerationPrompt = true)
    check out1 == "<|turn>user\nhi<turn|>\n<|turn>model\n"

  test "assistant 角色渲染为 model":
    let out1 = renderGemmaTurn([
      ChatMessage(role: crUser, content: "a"),
      ChatMessage(role: crAssistant, content: "b")
    ], addGenerationPrompt = false)
    check out1 == "<|turn>user\na<turn|>\n<|turn>model\nb<turn|>\n"

  test "system 角色保留原名":
    let out1 = renderGemmaTurn(
      [ChatMessage(role: crSystem, content: "s")], addGenerationPrompt = false)
    check out1 == "<|turn>system\ns<turn|>\n"

  test "渲染结果不含 BOS 字面量":
    # BOS 是 token 层面的事,由编排层按 bos_token_id 前置。
    # 在文本里写 <bos> 要求 tokenizer 恰好识别它,而实测并不保证。
    let out1 = renderGemmaTurn([ChatMessage(role: crUser, content: "x")])
    check "<bos>" notin out1

  test "内容首尾空白被裁掉":
    let out1 = renderGemmaTurn(
      [ChatMessage(role: crUser, content: "  hi  ")],
      addGenerationPrompt = false)
    check out1 == "<|turn>user\nhi<turn|>\n"

  test "未识别格式抛 MODEL_UNSUPPORTED 而不是猜一个":
    expect IsvikError:
      discard renderPrompt(cfUnknown, [ChatMessage(role: crUser, content: "x")])

  test "plain 格式不添加任何角色标记":
    let out1 = renderPrompt(
      cfPlain, [ChatMessage(role: crUser, content: "continue this")])
    check out1 == "continue this"

  test "没有模板文件时按 plain 处理":
    let dir = getTempDir() / "isvik-chatfmt-none"
    createDir(dir)
    defer: removeDir(dir)
    let r = loadChatFormat(dir)
    check r.format == cfPlain
    check r.source == ""

  test "模板文件存在但不认识时是 unknown,不是 plain":
    # 两者必须区分:unknown 按 plain 处理会静默产出结构错误的提示词。
    let dir = getTempDir() / "isvik-chatfmt-weird"
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / ChatTemplateFile, "{{ messages }}")
    let r = loadChatFormat(dir)
    check r.format == cfUnknown
    check r.source.endsWith(ChatTemplateFile)
