## 词表与 token ↔ 文本转换
##
## ---
##
## ## 为什么 detokenize 不走 OpenVINO 的 detokenizer IR
##
## 实测结论(见 DEVLOG 第九点五节):OpenVINO 的 C API **只能写 STRING 张量,
## 不能读**。
##
## ```text
## ov_tensor_set_string_data     FOUND
## ov_tensor_get_string_data     MISSING
## (其余读取候选全部 MISSING)
## ```
##
## detokenizer IR 的输出正是 STRING 张量。也就是说即使把它跑起来,结果也取不出来。
##
## 用 `ov_tensor_data` 拿裸指针再解析同样不行:OpenVINO 内部把字符串张量存为
## `std::string` 数组,而 `openvino_c.dll` 由 MSVC 编译、Nim 代码由 MinGW 编译。
## 跨这两种 ABI 解析 `std::string` 的内存布局不可靠 —— 这正是 DEVLOG 第六节
## 记录过的那类坑,不能再踩一次。
##
## 因此 token id → 文本改为**纯 Nim 实现**,直接读 `tokenizer.json` 的词表。
## 这不是绕过困难,而是当前 C API 下唯一能得到正确结果的做法。
##
## ---
##
## ## 实测的词表格式(Gemma 4 E2B)
##
## ```text
## model.type            BPE
## model.byte_fallback   true
## model.vocab           { token: id }
## added_tokens          含 <pad> / <eos> / <bos> / <unk> / <mask> 等
## ```
##
## SentencePiece 风格,两个关键约定:
##
## - `▁`(U+2581,不是下划线)表示**词首空格**
## - 字节回退 token 形如 `<0x0A>`,代表一个原始字节
##
## 反向解码只需 id → token → 拼接 → 还原空格与字节,**不需要 merges 表** ——
## merges 只在正向分词时决定合并顺序。
##
## ---
##
## ## 边界
##
## 本模块**不实现正向 BPE 分词**。正向分词需要 merges 表与完整的
## normalizer / pre-tokenizer 流水线,自己实现极易与官方结果产生细微差异,
## 而那种差异会让模型输出悄悄变差。正向分词走 OpenVINO 的 tokenizer IR
## (官方产物,注册扩展后可用)。
##
## 也就是说职责划分是:
##
## ```text
## 文本 → token id    OpenVINO tokenizer IR(官方实现)
## token id → 文本    本模块(C API 读不出 STRING,只能自己来)
## ```

import std/[json, tables, strutils, os, unicode]

import isvik/core/errors

type
  VocabularyEncoding* = enum
    veSentencePiece = "sentencepiece"
    veGpt2ByteLevel = "gpt2-byte-level"

  SpecialTokens* = object
    ## 特殊 token 的 id。`-1` 表示词表里没有这一个。
    ##
    ## 用 -1 而不是 0 表示缺失:0 是 `<pad>` 的合法 id,用它当哨兵会把
    ## 「没有 bos」误判成「bos 是 pad」。
    bos*: int
    eos*: int
    pad*: int
    unk*: int

  Vocabulary* = ref object
    ## token ↔ id 双向映射。
    idToToken: seq[string]
      ## 按 id 索引。词表 id 连续且从 0 开始,用序列比 Table 省内存也更快。
      ## 空洞(词表里不存在的 id)为空字符串。
    tokenToId: Table[string, int]
    specials*: SpecialTokens
    specialIds: Table[int, bool]
      ## 哪些 id 是特殊 token。解码时默认跳过它们。
    encoding: VocabularyEncoding
    byteDecoder: Table[int, int]
      ## GPT-2 bytes_to_unicode 的逆映射：Unicode code point → 原始 byte。

const
  SentencePieceSpace* = "\u2581"
    ## U+2581 LOWER ONE EIGHTH BLOCK。SentencePiece 用它表示词首空格。
    ##
    ## **不是** ASCII 下划线 —— 混淆这两个会让所有空格位置出错,而输出
    ## 看起来只是「单词粘在一起」,很容易被当成模型质量问题。

  ByteFallbackPrefix* = "<0x"
  ByteFallbackSuffix* = ">"
    ## 字节回退 token 的形状,如 `<0x0A>`。

  TokenizerConfigFile* = "tokenizer.json"
    ## HuggingFace tokenizers 格式的词表文件名。

  DefaultSpecialTokenNames*: array[5, string] = [
    "<pad>", "<eos>", "<bos>", "<unk>", "<mask>"
  ]

proc initSpecialTokens*(): SpecialTokens =
  SpecialTokens(bos: -1, eos: -1, pad: -1, unk: -1)

proc hasBos*(s: SpecialTokens): bool = s.bos >= 0
proc hasEos*(s: SpecialTokens): bool = s.eos >= 0

# ---------------------------------------------------------------------------
# 加载
# ---------------------------------------------------------------------------

proc newGpt2ByteDecoder(): Table[int, int] =
  ## GPT-2 `bytes_to_unicode()` 的精确逆映射。它把不可见 byte 映射到
  ## U+0100 以上字符，因此词表里的 `Ġ`/`Ċ` 必须先还原 byte 才是空格/换行。
  var bytes: seq[int] = @[]
  for value in 33 .. 126: bytes.add(value)
  for value in 161 .. 172: bytes.add(value)
  for value in 174 .. 255: bytes.add(value)
  var codepoints = bytes
  var present: array[256, bool]
  for value in bytes: present[value] = true
  var extra = 0
  for value in 0 .. 255:
    if not present[value]:
      bytes.add(value)
      codepoints.add(256 + extra)
      inc extra
  result = initTable[int, int]()
  for i in 0 ..< bytes.len:
    result[codepoints[i]] = bytes[i]

proc containsByteLevel(node: JsonNode): bool =
  if node == nil:
    return false
  case node.kind
  of JObject:
    if node.hasKey("type") and node["type"].kind == JString and
        node["type"].getStr == "ByteLevel":
      return true
    for _, child in node:
      if containsByteLevel(child):
        return true
  of JArray:
    for child in node:
      if containsByteLevel(child):
        return true
  else:
    discard
  false

proc newVocabulary*(entries: openArray[(string, int)],
                    specialTokens: openArray[string] = [],
                    encoding: VocabularyEncoding = veSentencePiece): Vocabulary =
  ## 从 token→id 条目构造词表。主要供测试使用。
  ##
  ## 重复 id 后者覆盖前者;重复 token 同理。这与 HuggingFace 的 JSON 语义
  ## 一致(后出现的键覆盖),不额外报错。
  new(result)
  result.tokenToId = initTable[string, int]()
  result.specialIds = initTable[int, bool]()
  result.specials = initSpecialTokens()
  result.encoding = encoding
  result.byteDecoder =
    if encoding == veGpt2ByteLevel: newGpt2ByteDecoder()
    else: initTable[int, int]()

  var maxId = -1
  for (_, id) in entries:
    if id > maxId:
      maxId = id
  result.idToToken = newSeq[string](maxId + 1)

  for (token, id) in entries:
    if id < 0:
      raiseIsvikError(
        ecModelInvalid,
        "Vocabulary token id must not be negative",
        "token=" & token & " id=" & $id
      )
    result.idToToken[id] = token
    result.tokenToId[token] = id

  for name in specialTokens:
    if result.tokenToId.hasKey(name):
      result.specialIds[result.tokenToId[name]] = true

  # 按约定名识别特殊 token。词表里没有就保持 -1,不猜。
  if result.tokenToId.hasKey("<bos>"):
    result.specials.bos = result.tokenToId["<bos>"]
  if result.tokenToId.hasKey("<eos>"):
    result.specials.eos = result.tokenToId["<eos>"]
  if result.tokenToId.hasKey("<pad>"):
    result.specials.pad = result.tokenToId["<pad>"]
  if result.tokenToId.hasKey("<unk>"):
    result.specials.unk = result.tokenToId["<unk>"]

proc loadVocabulary*(tokenizerJsonPath: string): Vocabulary =
  ## 从 `tokenizer.json` 加载词表。
  ##
  ## 只读 `model.vocab` 与 `added_tokens`,**不读 merges** —— 反向解码不需要
  ## (见模块顶部说明),而 merges 在 Gemma 上有几十万条,解析它纯属浪费。
  if not fileExists(tokenizerJsonPath):
    raiseIsvikError(
      ecModelNotFound,
      "Tokenizer configuration file was not found",
      "path=" & tokenizerJsonPath
    )

  let raw =
    try:
      readFile(tokenizerJsonPath)
    except IOError as e:
      raiseIsvikError(
        ecModelInvalid,
        "Failed to read the tokenizer configuration",
        "path=" & tokenizerJsonPath & " io=" & e.msg
      )

  let node =
    try:
      parseJson(raw)
    except JsonParsingError as e:
      raiseIsvikError(
        ecModelInvalid,
        "Tokenizer configuration is not valid JSON",
        "path=" & tokenizerJsonPath & " parse=" & e.msg
      )

  if node.kind != JObject or not node.hasKey("model"):
    raiseIsvikError(
      ecModelInvalid,
      "Tokenizer configuration has no 'model' section",
      "path=" & tokenizerJsonPath
    )

  let modelNode = node["model"]
  if modelNode.kind != JObject or not modelNode.hasKey("vocab"):
    raiseIsvikError(
      ecModelInvalid,
      "Tokenizer configuration has no 'model.vocab' table",
      "path=" & tokenizerJsonPath
    )

  let vocabNode = modelNode["vocab"]
  if vocabNode.kind != JObject:
    raiseIsvikError(
      ecModelInvalid,
      "'model.vocab' must be an object mapping token to id",
      "path=" & tokenizerJsonPath & " got=" & $vocabNode.kind
    )

  var entries: seq[(string, int)] = @[]
  for token, idNode in vocabNode:
    if idNode.kind != JInt:
      raiseIsvikError(
        ecModelInvalid,
        "Vocabulary id must be an integer",
        "token=" & token & " got=" & $idNode.kind
      )
    entries.add((token, idNode.getInt))

  if entries.len == 0:
    raiseIsvikError(
      ecModelInvalid,
      "Tokenizer vocabulary is empty",
      "path=" & tokenizerJsonPath
    )

  # added_tokens 里带 special=true 的都算特殊 token。它们的 content 通常也
  # 在 vocab 里,这里只是收集名字。
  var specialNames: seq[string] = @[]
  for name in DefaultSpecialTokenNames:
    specialNames.add(name)
  if node.hasKey("added_tokens") and node["added_tokens"].kind == JArray:
    for entry in node["added_tokens"]:
      if entry.kind != JObject:
        continue
      if entry.hasKey("special") and entry["special"].kind == JBool and
         entry["special"].getBool and
         entry.hasKey("content") and entry["content"].kind == JString:
        specialNames.add(entry["content"].getStr)

  let encoding =
    if node.hasKey("pre_tokenizer") and containsByteLevel(node["pre_tokenizer"]):
      veGpt2ByteLevel
    else:
      veSentencePiece
  result = newVocabulary(entries, specialNames, encoding)

# ---------------------------------------------------------------------------
# 查询
# ---------------------------------------------------------------------------

proc size*(v: Vocabulary): int =
  ## 词表容量(最大 id + 1)。含空洞。
  if v == nil: 0 else: v.idToToken.len

proc tokenCount*(v: Vocabulary): int =
  ## 实际登记的 token 数。
  if v == nil: 0 else: v.tokenToId.len

proc hasId*(v: Vocabulary, id: int): bool =
  v != nil and id >= 0 and id < v.idToToken.len and v.idToToken[id].len > 0

proc tokenOf*(v: Vocabulary, id: int): string =
  ## id 对应的 token 文本。id 不存在时返回空字符串。
  ##
  ## 返回空而不是抛错:解码一段 token 序列时遇到一个越界 id,更有用的行为是
  ## 跳过它并继续,而不是让整段输出失败。是否容忍由调用方决定。
  if v.hasId(id): v.idToToken[id] else: ""

proc idOf*(v: Vocabulary, token: string): int =
  ## token 对应的 id。不存在时返回 -1。
  if v == nil or not v.tokenToId.hasKey(token): -1 else: v.tokenToId[token]

proc isSpecial*(v: Vocabulary, id: int): bool =
  v != nil and v.specialIds.hasKey(id)

# ---------------------------------------------------------------------------
# 字节回退
# ---------------------------------------------------------------------------

proc byteFallbackValue*(token: string): int =
  ## 若 token 形如 `<0xNN>`,返回它代表的字节值;否则返回 -1。
  ##
  ## 字节回退是 BPE 处理词表外字符的机制:任何字节都能被表示,因此不会出现
  ## 「无法编码」。解码时必须把它还原成原始字节,否则输出里会出现字面的
  ## `<0xE4>` 这种垃圾。
  if not token.startsWith(ByteFallbackPrefix):
    return -1
  if not token.endsWith(ByteFallbackSuffix):
    return -1
  let hex = token[ByteFallbackPrefix.len ..< token.len - ByteFallbackSuffix.len]
  if hex.len != 2:
    return -1
  for c in hex:
    if c notin {'0' .. '9', 'a' .. 'f', 'A' .. 'F'}:
      return -1
  try:
    result = parseHexInt(hex)
  except ValueError:
    result = -1

# ---------------------------------------------------------------------------
# 解码
# ---------------------------------------------------------------------------

type
  DecodeOptions* = object
    ## 解码选项。
    skipSpecialTokens*: bool
      ## 跳过特殊 token(默认 true)。
      ##
      ## 关掉它对调试有用:能看到模型到底有没有生成 `<eos>`。
    keepUnknownIds*: bool
      ## 遇到词表里没有的 id 时,是否在输出里留一个可见标记。
      ##
      ## 默认 false(静默跳过)。开启后会插入 `<unk:ID>`,便于定位
      ## 「模型输出了越界 id」这类问题 —— 静默跳过会让这种 bug 完全隐形。

proc initDecodeOptions*(skipSpecialTokens: bool = true,
                        keepUnknownIds: bool = false): DecodeOptions =
  DecodeOptions(skipSpecialTokens: skipSpecialTokens,
                keepUnknownIds: keepUnknownIds)

proc decodeGpt2Token(v: Vocabulary, token: string): string =
  result = ""
  for rune in token.runes:
    let codepoint = int(rune)
    if v.byteDecoder.hasKey(codepoint):
      result.add(char(v.byteDecoder[codepoint]))
    else:
      # Added tokens may contain ordinary Unicode not produced by bytes_to_unicode.
      result.add(toUTF8(rune))

proc decode*(v: Vocabulary, ids: openArray[int],
             options: DecodeOptions = initDecodeOptions()): string =
  ## 把 token id 序列还原成文本。
  ##
  ## 处理顺序有讲究:
  ##
  ## 1. 先按 id 取 token 文本
  ## 2. 字节回退 token 直接还原为原始字节(必须在替换空格之前 ——
  ##    某些字节回退 token 的字节值恰好是空格,先替换会把它们弄错)
  ## 3. 最后把 `▁` 替换为空格
  ##
  ## 字节是逐个累积到 result 里的,因此多字节 UTF-8 字符能由多个字节回退
  ## token 拼回来。这是 byte_fallback 的关键:中文字符往往就是这样表示的。
  if v == nil:
    raiseIsvikError(
      ecModelInvalid,
      "Vocabulary is not loaded",
      "reason=nil-vocabulary"
    )

  result = ""
  for id in ids:
    if options.skipSpecialTokens and v.isSpecial(id):
      continue

    let token = v.tokenOf(id)
    if token.len == 0:
      if options.keepUnknownIds:
        result.add("<unk:" & $id & ">")
      continue

    let byteValue = byteFallbackValue(token)
    if byteValue >= 0:
      result.add(char(byteValue))
      continue

    case v.encoding
    of veSentencePiece:
      result.add(token.replace(SentencePieceSpace, " "))
    of veGpt2ByteLevel:
      result.add(v.decodeGpt2Token(token))

proc decodeToken*(v: Vocabulary, id: int,
                  options: DecodeOptions = initDecodeOptions()): string =
  ## 单个 token 的文本形式。
  ##
  ## 流式输出需要它:每生成一个 token 就发出对应的文本片段,而不是等整段
  ## 生成完再解码。
  ##
  ## **注意一个真实的局限**:单独解码一个字节回退 token 会得到一个不完整的
  ## UTF-8 字节。中文等多字节字符往往由多个字节回退 token 组成,逐个解码
  ## 得到的片段单独看是乱码。流式场景必须自己缓冲不完整的字节序列 ——
  ## 见 `PartialUtf8Buffer`。
  v.decode([id], options)

# ---------------------------------------------------------------------------
# 流式输出的不完整 UTF-8 缓冲
# ---------------------------------------------------------------------------

type
  PartialUtf8Buffer* = object
    ## 缓冲不完整的 UTF-8 字节序列。
    ##
    ## 存在的理由:字节回退 token 每个只带一个字节,而一个中文字符是 3 个字节。
    ## 流式输出若把每个 token 直接发出去,客户端会先收到两个残缺字节再收到
    ## 第三个 —— 多数 UI 会显示成替换字符 `?`,而且**永远不会自己恢复**。
    ##
    ## 因此流式路径必须先攒够一个完整字符再发。
    pending: string

proc initPartialUtf8Buffer*(): PartialUtf8Buffer =
  PartialUtf8Buffer(pending: "")

proc utf8SequenceLength(firstByte: char): int =
  ## 依据首字节判断这个 UTF-8 序列共有几个字节。非法首字节返回 1。
  let b = uint8(firstByte)
  if b < 0x80: 1
  elif (b and 0xE0) == 0xC0: 2
  elif (b and 0xF0) == 0xE0: 3
  elif (b and 0xF8) == 0xF0: 4
  else: 1        # 非法首字节:当作单字节处理,避免死等永不到来的续字节

proc push*(buf: var PartialUtf8Buffer, fragment: string): string =
  ## 追加一个片段,返回其中**已完整**的部分。
  ##
  ## 不完整的尾部留在缓冲里等下一次。返回空字符串是正常情况(说明这一个
  ## token 只贡献了半个字符)。
  buf.pending.add(fragment)
  result = ""

  var i = 0
  while i < buf.pending.len:
    let need = utf8SequenceLength(buf.pending[i])
    if i + need > buf.pending.len:
      break        # 尾部不完整,留着
    result.add(buf.pending[i ..< i + need])
    inc i, need

  buf.pending = buf.pending[i .. ^1]

proc flush*(buf: var PartialUtf8Buffer): string =
  ## 取出并清空残留字节。
  ##
  ## 生成结束时调用。残留说明最后一个字符没拼完 —— 原样交出而不是丢弃:
  ## 丢弃会静默吞掉内容,而交出至少让调用方能看到发生了什么。
  result = buf.pending
  buf.pending = ""

proc hasPending*(buf: PartialUtf8Buffer): bool =
  buf.pending.len > 0
