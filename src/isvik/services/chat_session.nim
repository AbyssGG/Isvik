## 常驻文本对话会话服务
##
## 该模块位于 CLI / GUI 与 Core Runtime 之间，统一持有一次会话所需的
## Runtime、已编译 TextGenerator 和多轮历史。产品前端只负责输入输出，
## 不复制模型编译、历史组装和资源释放逻辑。
##
## 重要事实：同一 TextGenerator 可以跨轮复用已加载/已编译模型，但每轮生成
## 仍由 text_generator 创建新的 InferRequest，并重新 prefill 完整历史。
## 当前 OpenVINO C API 环境缺少可靠的 state reset，跨轮复用 KV cache 会污染输出。

import isvik/core/errors
import isvik/core/runtime
import isvik/backends/factory
import isvik/inference/chat_format
import isvik/inference/gen_defaults
import isvik/inference/text_generator

type
  ChatSession* = ref object
    runtime: Runtime
    generator: TextGenerator
    modelLabel: string
    modelDirectory: string
    format: ChatFormat
    maxTokens: int
    systemPrompt: string
    messages: seq[ChatMessage]
    closed: bool

proc buildMessages(session: ChatSession): seq[ChatMessage] =
  result = @[]
  if session.systemPrompt.len > 0:
    result.add(ChatMessage(role: crSystem, content: session.systemPrompt))
  for message in session.messages:
    result.add(message)

proc openChatSession*(modelDirectory, modelLabel, device, extensionPath: string,
                      maxTokens: int, systemPrompt: string = "",
                      plain: bool = false): ChatSession =
  ## 创建并编译一个常驻会话。
  ##
  ## 构造采用候选 Runtime：任何一步失败都会关闭候选资源，调用方可以安全地
  ## 保留原会话。这使 `-use` 切换模型具备“成功后再替换”的事务语义。
  if maxTokens <= 0:
    raiseIsvikError(ecInvalidParameter, "maxTokens must be positive",
                    "maxTokens=" & $maxTokens)

  let runtime = newRuntime(newInferenceBackend())
  runtime.initialize()
  var generator: TextGenerator = nil
  try:
    generator = newTextGenerator(runtime, modelDirectory, extensionPath, device)
    new(result)
    result.runtime = runtime
    result.generator = generator
    result.modelLabel = modelLabel
    result.modelDirectory = modelDirectory
    result.format = if plain: cfPlain else: generator.chatFormat()
    result.maxTokens = maxTokens
    result.systemPrompt = systemPrompt
    result.messages = @[]
    result.closed = false
  except CatchableError:
    if generator != nil:
      generator.release()
    runtime.shutdown()
    raise

proc close*(session: ChatSession) =
  ## 释放会话。可重复调用。
  if session == nil or session.closed:
    return
  session.closed = true
  if session.generator != nil:
    session.generator.release()
  if session.runtime != nil:
    session.runtime.shutdown()

proc requireOpen(session: ChatSession, operation: string) =
  if session == nil or session.closed or session.generator == nil:
    raiseIsvikError(ecInvalidParameter, "Chat session is closed",
                    "operation=" & operation)

proc send*(session: ChatSession, prompt: string,
           onStep: StepCallback = nil): GenerationResult =
  ## 发送一轮消息并在成功后记录回答。
  ##
  ## 失败时撤回尚未得到回答的 user 消息，保证下一轮历史仍是合法的
  ## user/assistant 交替结构。
  session.requireOpen("send")
  if prompt.len == 0:
    raiseIsvikError(ecInvalidParameter, "Prompt must not be empty")

  session.messages.add(ChatMessage(role: crUser, content: prompt))
  try:
    let options = initGenerationOptions(maxNewTokens = session.maxTokens)
    result =
      if session.format == cfPlain:
        session.generator.generate(prompt, options, onStep)
      else:
        session.generator.chat(session.buildMessages(), options, onStep)
    session.messages.add(ChatMessage(role: crAssistant, content: result.text))
  except CatchableError:
    if session.messages.len > 0 and session.messages[^1].role == crUser:
      session.messages.setLen(session.messages.len - 1)
    raise

proc clearHistory*(session: ChatSession) =
  session.requireOpen("clearHistory")
  session.messages = @[]

proc history*(session: ChatSession): seq[ChatMessage] =
  if session == nil:
    return @[]
  result = session.messages

proc setSystemPrompt*(session: ChatSession, value: string) =
  session.requireOpen("setSystemPrompt")
  session.systemPrompt = value

proc systemPrompt*(session: ChatSession): string =
  if session == nil: "" else: session.systemPrompt

proc model*(session: ChatSession): string =
  if session == nil: "" else: session.modelLabel

proc directory*(session: ChatSession): string =
  if session == nil: "" else: session.modelDirectory

proc device*(session: ChatSession): string =
  if session == nil or session.generator == nil: ""
  else: session.generator.device()

proc chatFormat*(session: ChatSession): ChatFormat =
  if session == nil: cfUnknown else: session.format

proc generationDefaults*(session: ChatSession): GenerationDefaults =
  if session == nil or session.generator == nil: initGenerationDefaults()
  else: session.generator.generationDefaults()

proc hiddenSize*(session: ChatSession): int =
  if session == nil or session.generator == nil: -1
  else: session.generator.hiddenSize()

proc perLayerShape*(session: ChatSession): tuple[layers, dim: int] =
  if session == nil or session.generator == nil: (-1, -1)
  else: session.generator.perLayerShape()

proc usesPerLayerInputs*(session: ChatSession): bool =
  session != nil and session.generator != nil and
    session.generator.usesPerLayerInputs()

proc maxNewTokens*(session: ChatSession): int =
  if session == nil: 0 else: session.maxTokens
