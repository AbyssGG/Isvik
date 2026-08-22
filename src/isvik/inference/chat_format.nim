## 对话提示词格式化。
##
## 对应 Master Prompt §15(Inference Pipeline)、§13(禁止伪造能力)。
##
## ---
##
## ## 不实现 Jinja
##
## HuggingFace 的 `chat_template.jinja` 是完整 Jinja2 模板 —— Gemma 4 那份有
## 三百多行,含宏、命名空间、递归调用、工具声明序列化。在 Nim 里实现一个
## Jinja2 解释器不是本项目的目标,而实现一个**部分**兼容的解释器更糟:
## 它会在某些模型上静默产出错误的提示词,而错误提示词的表现是
## 「模型答得不好」,几乎不可能被归因到模板 bug。
##
## 所以这里的做法是:**识别已知格式,不解释模板**。从模板文件里找特征标记,
## 匹配上就用对应的内建格式化器;匹配不上就如实报 MODEL_UNSUPPORTED,
## 让调用方自己拼提示词。承认「这个模板我不认识」比猜一个格式安全。
##
## ---
##
## ## Gemma 4 回合格式(实测确认)
##
## 从真实模型的 `chat_template.jinja` 读出:
##
## ```text
## {bos}<|turn>user\n{内容}<turn|>\n<|turn>model\n
## ```
##
## 注意标记是 `<|turn>` / `<turn|>`,**不是** Gemma 3 的
## `<start_of_turn>` / `<end_of_turn>`。这个区别是实打实踩到的:
## 用 Gemma 3 的标记时 tokenizer 不认识它们,于是按普通文本切成
## `<`,`start`,`_`,`of`,`_`,`turn`,`>` 七个 token 送进模型 —— 模型仍然
## 答对了问题(它足够鲁棒),但随后把 `<end_of_turn>` 当普通文本又写了一遍。
## 也就是说**用错模板不会报错,只会让输出多出一段垃圾**。
##
## 与 Gemma 4 配套的回合结束 token 是 id 106(`<turn|>`),它正是
## `generation_config.json` 里 `eos_token_id` 的第二项。

import std/[os, strutils]

import isvik/core/errors

type
  ChatRole* = enum
    ## 对话角色。刻意不含 "tool" —— 工具调用的模板远比文本回合复杂,
    ## 没实现就不列出(§20.5.13:不得声明未实现的能力)。
    crSystem = "system"
    crUser = "user"
    crAssistant = "assistant"

  ChatMessage* = object
    role*: ChatRole
    content*: string

  ChatFormat* = enum
    ## 已识别的提示词格式。
    cfUnknown = "unknown"
      ## 模板文件缺失或不认识。调用方必须自己拼提示词。
    cfGemmaTurn = "gemma-turn"
      ## Gemma 4 的 `<|turn>role\n...<turn|>\n` 格式。
    cfPlain = "plain"
      ## 无模板,直接把内容当续写提示词。基座(非指令)模型用这个。

const
  ChatTemplateFile* = "chat_template.jinja"

  GemmaTurnBegin* = "<|turn>"
  GemmaTurnEnd* = "<turn|>"
    ## Gemma 4 的回合标记。**不是** `<start_of_turn>` / `<end_of_turn>`。

proc detectChatFormat*(templateText: string): ChatFormat =
  ## 从模板文本判断格式。
  ##
  ## 判据是特征标记而非模板结构:标记是模板**输出**的一部分,
  ## 而模板的控制流写法各家不同,靠结构匹配太脆。
  if templateText.len == 0:
    return cfUnknown
  if GemmaTurnBegin in templateText and GemmaTurnEnd in templateText:
    return cfGemmaTurn
  cfUnknown

proc loadChatFormat*(modelDir: string): tuple[format: ChatFormat, source: string] =
  ## 从模型目录识别提示词格式。
  ##
  ## 模板文件不存在时返回 `cfPlain`:那通常意味着这是个基座模型,直接续写
  ## 是正确行为。与「模板存在但不认识」(`cfUnknown`)必须区分开 ——
  ## 后者按 plain 处理会静默产出错误提示词。
  let path = modelDir / ChatTemplateFile
  if not fileExists(path):
    return (cfPlain, "")
  let raw =
    try:
      readFile(path)
    except IOError as e:
      raiseIsvikError(
        ecModelInvalid,
        "Failed to read the chat template",
        "path=" & path & " io=" & e.msg
      )
  result = (detectChatFormat(raw), path)

proc renderGemmaTurn*(messages: openArray[ChatMessage],
                     addGenerationPrompt: bool = true): string =
  ## 按 Gemma 4 回合格式拼提示词。
  ##
  ## 刻意**不**加 BOS:BOS 是 token 层面的事,由编排层按
  ## `generation_config.json` 的 `bos_token_id` 前置。在文本里写 `<bos>`
  ## 要求 tokenizer 恰好把它识别成特殊 token,而那一点在真实模型上
  ## 实测**不成立**(tokenizer IR 不自动加 BOS,也不保证识别字面量)。
  ##
  ## system 消息映射为 `<|turn>system`,与模板一致。
  result = ""
  for m in messages:
    let role = if m.role == crAssistant: "model" else: $m.role
    result.add(GemmaTurnBegin & role & "\n")
    result.add(m.content.strip())
    result.add(GemmaTurnEnd & "\n")
  if addGenerationPrompt:
    result.add(GemmaTurnBegin & "model\n")

proc renderPlain*(messages: openArray[ChatMessage]): string =
  ## 无模板格式:把各条内容按空行拼接。
  ##
  ## 只对基座模型有意义。不加任何角色标记 —— 编造标记会污染续写。
  var parts: seq[string] = @[]
  for m in messages:
    if m.content.len > 0:
      parts.add(m.content.strip())
  result = parts.join("\n\n")

proc renderPrompt*(format: ChatFormat, messages: openArray[ChatMessage],
                  addGenerationPrompt: bool = true): string =
  ## 按识别出的格式拼提示词。
  ##
  ## `cfUnknown` 抛 MODEL_UNSUPPORTED 而不是回落到 plain:模板存在却不被
  ## 识别时,按 plain 处理会产出结构错误的提示词,而症状只表现为
  ## 「模型答得不好」—— 那种失败几乎无法被归因到这里。
  case format
  of cfGemmaTurn:
    renderGemmaTurn(messages, addGenerationPrompt)
  of cfPlain:
    renderPlain(messages)
  of cfUnknown:
    raiseIsvikError(
      ecModelUnsupported,
      "The model's chat template is not recognized",
      "format=unknown reason=no-builtin-formatter-matches " &
        "hint=supply-a-pre-rendered-prompt"
    )
