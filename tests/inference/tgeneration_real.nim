## 真机端到端生成测试。
##
## 需要一个真实的组合文本生成模型目录,由 `ISVIK_TEST_MODEL_DIR` 指定。
## 未设置时**跳过并打印跳过原因** —— 不假装通过(§13)。
##
## 已验证环境:`gemma-4-E2B-it-int4-ov`(CPU),OpenVINO 2026.2。
##
## 这个测试断言的是**管线正确性**,不是模型质量:
##
## * 「首都是巴黎」这类事实性断言刻意**不做**:那考的是模型,不是 Isvik,
##   且换模型必然失败,变成噪音。
## * 真正断言的是那些**只要编排错就一定不成立**的性质:
##   自然停止而非被截断、流式片段拼起来等于整体文本、贪心可复现、
##   连续两次生成互不污染、中文不产生半个 UTF-8 码点。
##
## 其中「自然停止」尤其关键:第一次跑通端到端时正是这一条不成立 ——
## 模型答完后输出了 EOS(id 106),但停止条件只比对了单个 eos,
## 于是又追加了 9 个重复 token。输出「看起来对,只是尾部有垃圾」。

import std/[unittest, os, strutils, unicode]

import isvik/backends/factory
import isvik/core/runtime
import isvik/inference/gen_defaults
import isvik/inference/chat_format
import isvik/inference/vocabulary
import isvik/inference/text_generator

const ModelDirEnv = "ISVIK_TEST_MODEL_DIR"

let modelDir = getEnv(ModelDirEnv)

proc isValidUtf8(s: string): bool =
  ## 是否为合法 UTF-8。用于证明流式输出没有吐出半个码点。
  ##
  ## `validateUtf8` 返回第一个非法字节的下标,合法时返回 -1。
  s.validateUtf8() < 0

if modelDir.len == 0:
  echo "跳过真机生成测试:未设置 " & ModelDirEnv
  echo "  设置为一个组合文本生成模型目录即可启用,例如:"
  echo "  $env:" & ModelDirEnv & "='D:\\Model\\gemma-4-E2B-it-int4-ov'"
elif not dirExists(modelDir):
  echo "跳过真机生成测试:" & ModelDirEnv & " 指向的目录不存在:" & modelDir
else:
  var backend = newInferenceBackend()
  var rt = newRuntime(backend)
  var gen: TextGenerator = nil
  var setupError = ""

  try:
    rt.initialize()
    gen = newTextGenerator(rt, modelDir, device = "CPU")
  except CatchableError as e:
    setupError = $e.name & ": " & e.msg

  if setupError.len > 0:
    echo "跳过真机生成测试:构建生成器失败 —— " & setupError
  else:
    suite "真机:模型自描述信息必须来自模型本身":

      test "hidden size 从实际前向问出,不是猜的":
        check gen.hiddenSize > 0

      test "per_layer_inputs 的使用由端口决定":
        # 是否需要该输入由端口决定；producer 既可能输出 E2B 的非空末维，
        # 也可能输出 26B 的合法零末维。两者都必须显式绑定真实输出。
        if gen.usesPerLayerInputs():
          let s = gen.perLayerShape()
          check s.layers > 0
          check s.dim >= 0
        else:
          check gen.perLayerShape() == (-1, -1)

      test "生成默认值来自 generation_config.json":
        let d = gen.generationDefaults()
        if d.isKnown:
          check d.source.endsWith(GenerationConfigFile)

      test "对话格式被识别(否则 chat 会抛错而不是猜)":
        check gen.chatFormat() in {cfGemmaTurn, cfPlain}

    suite "真机:tokenizer":

      test "词表已加载":
        check gen.vocabulary() != nil
        check gen.vocabulary().tokenCount > 0

      test "提示词被编码成非空 id 序列,且以 BOS 开头":
        let r = gen.generate("Hello", initGenerationOptions(maxNewTokens = 1))
        check r.promptTokenIds.len >= 2
        let d = gen.generationDefaults()
        if d.hasBos:
          check r.promptTokenIds[0] == d.bosTokenId

      test "解码能还原 ASCII 文本":
        # 往返:这同时验证了 STRING 张量写入的签名是对的 ——
        # 签名错了会得到垃圾 id,还原不回原文。
        let r = gen.generate("Hello", initGenerationOptions(maxNewTokens = 1))
        check r.promptTokenIds.len >= 1
        let restored = gen.decodeTokens(r.promptTokenIds)
        check "Hello" in restored

    suite "真机:生成编排":

      let question = @[ChatMessage(role: crUser,
                                   content: "What is the capital of France?")]

      test "生成非空文本":
        let r = gen.chat(question, initGenerationOptions(maxNewTokens = 48))
        check r.text.len > 0
        check r.generatedTokens > 0

      test "自然停止而非被长度截断":
        # 只认单个 EOS 时这一条会失败 —— 那正是第一次跑通时的 bug。
        let r = gen.chat(question, initGenerationOptions(maxNewTokens = 48))
        check r.stopReason == srEndOfSequence

      test "停止时不把 EOS 计入输出":
        let r = gen.chat(question, initGenerationOptions(maxNewTokens = 48))
        let d = gen.generationDefaults()
        for id in r.tokenIds:
          check not d.isEos(id)

      test "贪心解码可复现":
        # 相等时取较小 id + 跳过 NaN,共同保证这一条。
        let a = gen.chat(question, initGenerationOptions(maxNewTokens = 16))
        let b = gen.chat(question, initGenerationOptions(maxNewTokens = 16))
        check a.tokenIds == b.tokenIds
        check a.text == b.text

      test "连续两次生成互不污染":
        # KV-cache 是模型内部状态且**无法重置**(state API 在本机 DLL 缺失),
        # 所以每次生成必须用新的 InferRequest。复用会让第二次看到第一次的
        # cache,输出无声地变错。
        let first = gen.chat(question, initGenerationOptions(maxNewTokens = 24))
        let other = gen.chat(
          @[ChatMessage(role: crUser, content: "Name three primary colors.")],
          initGenerationOptions(maxNewTokens = 24))
        let again = gen.chat(question, initGenerationOptions(maxNewTokens = 24))
        check other.tokenIds != first.tokenIds
        check again.tokenIds == first.tokenIds

      test "流式片段拼接等于整体文本":
        var streamed = ""
        proc collect(s: GenerationStep): bool =
          streamed.add(s.textFragment)
          true
        let r = gen.chat(question, initGenerationOptions(maxNewTokens = 32),
                         collect)
        check streamed == r.text

      test "每个流式片段都是合法 UTF-8":
        # 中文在 Gemma 词表里是多个字节回退 token,不缓冲就会吐出半个码点,
        # 终端上表现为永久乱码。
        var allValid = true
        proc checkUtf8(s: GenerationStep): bool =
          if not isValidUtf8(s.textFragment):
            allValid = false
          true
        let r = gen.chat(
          @[ChatMessage(role: crUser, content: "用一句话解释什么是操作系统。")],
          initGenerationOptions(maxNewTokens = 48), checkUtf8)
        check allValid
        check isValidUtf8(r.text)
        check r.text.len > 0

      test "回调返回 false 时停止,原因为 cancelled":
        var seen = 0
        proc stopEarly(s: GenerationStep): bool =
          inc seen
          seen < 3
        let r = gen.chat(question, initGenerationOptions(maxNewTokens = 48),
                         stopEarly)
        check r.stopReason == srCancelled
        check r.generatedTokens == 3

      test "计时是真实测量,不是零":
        let r = gen.chat(question, initGenerationOptions(maxNewTokens = 16))
        check r.prefillMs > 0.0
        check r.totalMs >= r.prefillMs
        if r.generatedTokens > 1:
          check r.decodeMs > 0.0

      test "maxNewTokens=1 时只生成一个 token":
        let r = gen.chat(question, initGenerationOptions(maxNewTokens = 1))
        check r.generatedTokens <= 1

      test "maxNewTokens 非正数被拒绝":
        expect CatchableError:
          discard gen.chat(question, initGenerationOptions(maxNewTokens = 0))

    suite "真机:释放":

      test "release 可重复调用":
        gen.release()
        gen.release()
        check gen.isReleased()

      test "释放后再生成抛错而不是崩溃":
        expect CatchableError:
          discard gen.generate("x")

    rt.shutdown()
