## 词表与解码测试
##
## 纯逻辑,不依赖 OpenVINO。真实 Gemma 词表的加载在最后一个 suite 里验证,
## 通过 `ISVIK_TEST_TOKENIZER_JSON` 提供路径,未提供时跳过。

import std/[unittest, os, strutils]

import isvik/core/errors
import isvik/inference/vocabulary

let realTokenizerJson = getEnv("ISVIK_TEST_TOKENIZER_JSON")

proc tinyVocab(): Vocabulary =
  ## 一个足够小、能覆盖全部解码分支的词表。
  newVocabulary([
    ("<pad>", 0),
    ("<eos>", 1),
    ("<bos>", 2),
    ("<unk>", 3),
    ("\u2581Hello", 10),      # 词首空格 + Hello
    ("\u2581world", 11),
    ("!", 12),
    ("abc", 13),
    ("<0x41>", 20),           # 字节 'A'
    ("<0x20>", 21),           # 字节 空格
    ("<0xE4>", 30),           # 「中」的三个 UTF-8 字节
    ("<0xB8>", 31),
    ("<0xAD>", 32)
  ], ["<pad>", "<eos>", "<bos>", "<unk>"])

suite "词表构造与查询":

  test "id 与 token 双向映射":
    let v = tinyVocab()
    check v.tokenOf(13) == "abc"
    check v.idOf("abc") == 13
    check v.tokenOf(12) == "!"
    check v.idOf("!") == 12

  test "不存在的 id 返回空字符串而不是抛错":
    # 解码一段序列时遇到越界 id,跳过并继续比整段失败更有用。
    let v = tinyVocab()
    check v.tokenOf(9999) == ""
    check v.tokenOf(-1) == ""
    check not v.hasId(9999)

  test "不存在的 token 返回 -1":
    check tinyVocab().idOf("nosuchtoken") == -1

  test "特殊 token 被识别":
    let v = tinyVocab()
    check v.isSpecial(0)
    check v.isSpecial(1)
    check v.isSpecial(2)
    check v.isSpecial(3)
    check not v.isSpecial(13)

  test "特殊 token id 被记录,缺失时为 -1 而不是 0":
    # 0 是 <pad> 的合法 id,用它当哨兵会把「没有 bos」误判成「bos 是 pad」。
    let v = tinyVocab()
    check v.specials.pad == 0
    check v.specials.eos == 1
    check v.specials.bos == 2
    check v.specials.unk == 3
    check v.specials.hasBos
    check v.specials.hasEos

    let noSpecials = newVocabulary([("a", 0), ("b", 1)])
    check noSpecials.specials.bos == -1
    check noSpecials.specials.eos == -1
    check not noSpecials.specials.hasBos
    check not noSpecials.specials.hasEos

  test "容量与实际 token 数可区分":
    let v = tinyVocab()
    check v.size == 33          # 最大 id 32 + 1
    check v.tokenCount == 13    # 实际登记 13 个
    check v.size > v.tokenCount # 有空洞

  test "负数 id 被拒绝":
    var code: IsvikErrorCode
    try:
      discard newVocabulary([("bad", -1)])
      check false
    except IsvikError as e:
      code = e.code
    check code == ecModelInvalid

  test "nil 词表的查询不崩溃":
    let v: Vocabulary = nil
    check v.size == 0
    check v.tokenCount == 0
    check v.tokenOf(0) == ""
    check v.idOf("a") == -1
    check not v.isSpecial(0)
    check not v.hasId(0)

suite "字节回退 token":

  test "识别 <0xNN> 形式":
    check byteFallbackValue("<0x41>") == 0x41
    check byteFallbackValue("<0x0A>") == 10
    check byteFallbackValue("<0xff>") == 255
    check byteFallbackValue("<0xFF>") == 255

  test "非字节回退 token 返回 -1":
    for token in ["abc", "<0x>", "<0x123>", "<41>", "0x41", "<0xZZ>",
                  "<0x4>", "", "\u2581Hello"]:
      check byteFallbackValue(token) == -1

suite "解码":

  test "普通 token 拼接,词首空格被还原":
    let v = tinyVocab()
    # ▁Hello ▁world !  ->  " Hello world!"
    check v.decode([10, 11, 12]) == " Hello world!"

  test "SentencePiece 空格标记不是下划线":
    # 混淆 U+2581 与 ASCII 下划线会让所有空格位置出错,而输出看起来只是
    # 「单词粘在一起」,很容易被误判成模型质量问题。
    check SentencePieceSpace == "\u2581"
    check SentencePieceSpace != "_"
    let v = newVocabulary([("_underscore", 5)])
    # 字面下划线不该被当成空格。
    check v.decode([5]) == "_underscore"

  test "字节回退 token 被还原为原始字节":
    let v = tinyVocab()
    check v.decode([20]) == "A"
    check v.decode([20, 20]) == "AA"

  test "多个字节回退 token 拼出多字节 UTF-8 字符":
    # 这是 byte_fallback 的关键:中文字符往往就是这样表示的。
    let v = tinyVocab()
    check v.decode([30, 31, 32]) == "中"

  test "字节回退在空格替换之前处理":
    # <0x20> 的字节值就是空格。若先替换 ▁ 再处理字节,顺序无碍;
    # 但若把字节 token 当普通 token 做 ▁ 替换,就会漏掉它。
    let v = tinyVocab()
    check v.decode([13, 21, 13]) == "abc abc"

  test "特殊 token 默认被跳过":
    let v = tinyVocab()
    check v.decode([2, 10, 11, 12, 1]) == " Hello world!"

  test "关闭跳过后特殊 token 出现在输出里":
    # 调试时需要看到模型到底有没有生成 <eos>。
    let v = tinyVocab()
    let text = v.decode([2, 13, 1], initDecodeOptions(skipSpecialTokens = false))
    check text.contains("<bos>")
    check text.contains("<eos>")
    check text.contains("abc")

  test "未知 id 默认静默跳过":
    let v = tinyVocab()
    check v.decode([13, 9999, 13]) == "abcabc"

  test "开启 keepUnknownIds 后未知 id 可见":
    # 静默跳过会让「模型输出了越界 id」这类 bug 完全隐形。
    let v = tinyVocab()
    let text = v.decode([13, 9999], initDecodeOptions(keepUnknownIds = true))
    check text == "abc<unk:9999>"

  test "空序列解码为空字符串":
    check tinyVocab().decode([]) == ""

  test "nil 词表解码抛 MODEL_INVALID":
    let v: Vocabulary = nil
    var code: IsvikErrorCode
    try:
      discard v.decode([1])
      check false
    except IsvikError as e:
      code = e.code
    check code == ecModelInvalid

  test "单 token 解码与整段解码一致":
    let v = tinyVocab()
    check v.decodeToken(13) == "abc"
    check v.decodeToken(10) == " Hello"

suite "流式输出的不完整 UTF-8 缓冲":

  test "完整的 ASCII 片段立即通过":
    var buf = initPartialUtf8Buffer()
    check buf.push("abc") == "abc"
    check not buf.hasPending

  test "多字节字符被攒够才输出":
    # 「中」是 3 个字节。逐字节喂进去,前两次应当什么都不输出。
    var buf = initPartialUtf8Buffer()
    check buf.push("\xE4") == ""
    check buf.hasPending
    check buf.push("\xB8") == ""
    check buf.hasPending
    check buf.push("\xAD") == "中"
    check not buf.hasPending

  test "混合内容:完整部分先出,残缺部分留下":
    var buf = initPartialUtf8Buffer()
    check buf.push("ok\xE4\xB8") == "ok"
    check buf.hasPending
    check buf.push("\xAD!") == "中!"
    check not buf.hasPending

  test "flush 交出残留而不是丢弃":
    # 丢弃会静默吞掉内容;交出至少让调用方能看到发生了什么。
    var buf = initPartialUtf8Buffer()
    discard buf.push("\xE4\xB8")
    let leftover = buf.flush()
    check leftover.len == 2
    check not buf.hasPending
    check buf.flush() == ""

  test "非法首字节不会导致死等":
    # 0x80 是续字节,不能作为首字节。若按「等续字节」处理会永远卡住。
    var buf = initPartialUtf8Buffer()
    check buf.push("\x80").len == 1
    check not buf.hasPending

  test "四字节字符(emoji 范围)同样正确":
    var buf = initPartialUtf8Buffer()
    check buf.push("\xF0\x9F\x98") == ""
    check buf.push("\x80") == "\xF0\x9F\x98\x80"

  test "逐 token 流式解码与整段解码结果相同":
    # 这是流式路径的正确性判据:客户端逐块拼起来必须等于一次性解码。
    let v = tinyVocab()
    let ids = [10, 11, 12, 30, 31, 32, 13]
    let whole = v.decode(ids)

    var buf = initPartialUtf8Buffer()
    var streamed = ""
    for id in ids:
      streamed.add(buf.push(v.decodeToken(id)))
    streamed.add(buf.flush())
    check streamed == whole

suite "从 tokenizer.json 加载":

  test "缺失文件抛 MODEL_NOT_FOUND":
    var code: IsvikErrorCode
    try:
      discard loadVocabulary(getTempDir() / "isvik_no_such_tokenizer.json")
      check false
    except IsvikError as e:
      code = e.code
    check code == ecModelNotFound

  test "非法 JSON 抛 MODEL_INVALID":
    let path = getTempDir() / "isvik_bad_tokenizer.json"
    writeFile(path, "{ not json")
    var code: IsvikErrorCode
    try:
      discard loadVocabulary(path)
      check false
    except IsvikError as e:
      code = e.code
    check code == ecModelInvalid
    removeFile(path)

  test "缺少 model.vocab 抛 MODEL_INVALID":
    let path = getTempDir() / "isvik_novocab_tokenizer.json"
    writeFile(path, """{"model": {"type": "BPE"}}""")
    expect IsvikError:
      discard loadVocabulary(path)
    removeFile(path)

  test "空词表被拒绝":
    let path = getTempDir() / "isvik_emptyvocab_tokenizer.json"
    writeFile(path, """{"model": {"type": "BPE", "vocab": {}}}""")
    expect IsvikError:
      discard loadVocabulary(path)
    removeFile(path)

  test "GPT-2 ByteLevel 逆映射还原空格与换行":
    let path = getTempDir() / "isvik_gpt2_bytelevel_tokenizer.json"
    writeFile(path, """{
      "pre_tokenizer": {"type": "ByteLevel"},
      "model": {
        "type": "BPE",
        "vocab": {"ĠHello": 0, "Ċ": 1}
      }
    }""")
    let v = loadVocabulary(path)
    check v.decode([0, 1]) == " Hello\n"
    removeFile(path)

  test "最小合法文件可加载,并识别 added_tokens 里的特殊 token":
    let path = getTempDir() / "isvik_min_tokenizer.json"
    writeFile(path, """{
      "added_tokens": [
        {"id": 1, "content": "<eos>", "special": true},
        {"id": 5, "content": "<|custom|>", "special": true},
        {"id": 6, "content": "notspecial", "special": false}
      ],
      "model": {
        "type": "BPE",
        "vocab": {"<pad>": 0, "<eos>": 1, "abc": 2,
                  "<|custom|>": 5, "notspecial": 6}
      }
    }""")
    let v = loadVocabulary(path)
    check v.tokenCount == 5
    check v.specials.eos == 1
    check v.isSpecial(1)
    check v.isSpecial(5)        # 来自 added_tokens
    check not v.isSpecial(6)    # special=false
    check not v.isSpecial(2)
    check v.decode([1, 2, 5]) == "abc"   # 特殊 token 被跳过
    removeFile(path)

  test "id 类型错误被拒绝":
    let path = getTempDir() / "isvik_badid_tokenizer.json"
    writeFile(path, """{"model": {"vocab": {"abc": "notanumber"}}}""")
    expect IsvikError:
      discard loadVocabulary(path)
    removeFile(path)

suite "真实 Gemma 词表(需要 ISVIK_TEST_TOKENIZER_JSON)":

  test "报告探测结果(信息性,不判定成败)":
    if realTokenizerJson.len == 0:
      checkpoint("未设置 ISVIK_TEST_TOKENIZER_JSON,本 suite 将全部跳过")
    elif not fileExists(realTokenizerJson):
      checkpoint("路径不存在:" & realTokenizerJson)
    else:
      checkpoint("词表文件:" & realTokenizerJson)
    check true

  test "真实词表能加载,且规模与 Gemma 相符":
    if realTokenizerJson.len == 0 or not fileExists(realTokenizerJson):
      skip()
    else:
      let v = loadVocabulary(realTokenizerJson)
      checkpoint("size=" & $v.size & " tokenCount=" & $v.tokenCount)
      # Gemma 的词表是二十几万量级。这里只断言「远大于玩具词表」,
      # 不写死具体数字 —— 那会让换模型时无故失败。
      check v.tokenCount > 10000
      check v.size >= v.tokenCount

  test "真实词表里的特殊 token 与实测一致":
    if realTokenizerJson.len == 0 or not fileExists(realTokenizerJson):
      skip()
    else:
      let v = loadVocabulary(realTokenizerJson)
      # 实测值(见 DEVLOG 第九点五节第 6 条)。
      check v.specials.pad == 0
      check v.specials.eos == 1
      check v.specials.bos == 2
      check v.specials.unk == 3
      check v.isSpecial(v.specials.eos)

  test "真实词表包含字节回退 token":
    # byte_fallback: true 的直接后果。缺了它就无法表示词表外字符。
    if realTokenizerJson.len == 0 or not fileExists(realTokenizerJson):
      skip()
    else:
      let v = loadVocabulary(realTokenizerJson)
      var found = 0
      for hex in ["<0x00>", "<0x0A>", "<0x20>", "<0xFF>"]:
        if v.idOf(hex) >= 0:
          inc found
      checkpoint("找到 " & $found & " / 4 个探测用字节回退 token")
      check found > 0

  test "真实词表能还原多字节字符":
    if realTokenizerJson.len == 0 or not fileExists(realTokenizerJson):
      skip()
    else:
      let v = loadVocabulary(realTokenizerJson)
      # 用字节回退把「中」拼出来。若词表里有这三个字节 token,
      # 解码结果必须是那个字符本身,而不是字面的 <0xE4>。
      let a = v.idOf("<0xE4>")
      let b = v.idOf("<0xB8>")
      let c = v.idOf("<0xAD>")
      if a < 0 or b < 0 or c < 0:
        checkpoint("词表缺少所需的字节回退 token,跳过该断言")
        check true
      else:
        check v.decode([a, b, c]) == "中"
