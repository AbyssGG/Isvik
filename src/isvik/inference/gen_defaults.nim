## 模型自带的生成默认值(`generation_config.json`)。
##
## 对应 Master Prompt §15(Inference Pipeline)、§13(禁止伪造)。
##
## ---
##
## ## 为什么必须读这个文件,而不是把 EOS 写死
##
## 真实 Gemma 4 E2B 的 `generation_config.json`:
##
## ```json
## { "bos_token_id": 2, "eos_token_id": [1, 106, 50], "pad_token_id": 0 }
## ```
##
## **`eos_token_id` 是三个,不是一个。** 只认其中的 `1`(`<eos>`)会导致生成
## 永不停止 —— 实测第一次跑通端到端时正是这样:模型在正确回答完
## 「The capital of France is Paris.」之后输出了 id 106(`<turn|>`,回合结束),
## 但停止条件只比对了单个 eos,于是又追加了 9 个重复 token 才被 maxNewTokens
## 截断。输出「看起来像对的,只是末尾有垃圾」,这类 bug 很容易被当成模型质量
## 问题而不是编排 bug。
##
## 同理,把 EOS 硬编码成某个具体数字对换模型就一定是错的。
##
## ---
##
## ## 缺失即未知,不编造
##
## 文件不存在、字段缺失、类型不对 —— 一律表示为「未知」(空序列 / -1),
## 由调用方决定怎么处置。这里刻意**不**回落到某个「常见默认值」:
## 猜一个 EOS 比承认不知道更危险,因为前者会静默产出错误的停止行为。

import std/[json, os, sets, sequtils, algorithm]

import isvik/core/errors

const
  GenerationConfigFile* = "generation_config.json"

type
  GenerationDefaults* = object
    ## 模型自带的生成默认值。所有字段都可能「未知」。
    bosTokenId*: int
      ## 序列起始 token。`-1` 表示未声明。
    eosTokenIds*: seq[int]
      ## **全部**终止 token,升序去重。空表示未声明。
    padTokenId*: int
      ## 填充 token。`-1` 表示未声明。
    temperature*: float
      ## 模型建议的采样温度。`NaN` 表示未声明。
      ##
      ## Isvik 目前只实现贪心解码,所以这个值**仅作记录**,不参与解码。
      ## 保留它是为了在 API 里如实回报「模型建议了什么」,而不是让调用方
      ## 以为 Isvik 支持温度采样(§20.5.13:不得声明未实现的能力)。
    topK*: int
      ## 同上,仅记录。`-1` 表示未声明。
    topP*: float
      ## 同上,仅记录。`NaN` 表示未声明。
    source*: string
      ## 这些值来自哪个文件。空表示没有读到任何文件。

proc initGenerationDefaults*(): GenerationDefaults =
  ## 全部「未知」的默认值。
  GenerationDefaults(
    bosTokenId: -1,
    eosTokenIds: @[],
    padTokenId: -1,
    temperature: NaN,
    topK: -1,
    topP: NaN,
    source: ""
  )

proc hasBos*(d: GenerationDefaults): bool = d.bosTokenId >= 0
proc hasEos*(d: GenerationDefaults): bool = d.eosTokenIds.len > 0
proc hasPad*(d: GenerationDefaults): bool = d.padTokenId >= 0
proc isKnown*(d: GenerationDefaults): bool = d.source.len > 0

proc isEos*(d: GenerationDefaults, tokenId: int): bool =
  ## 该 token 是否为终止 token。
  ##
  ## 未声明任何 EOS 时恒为 false —— 那种情况下只能靠 maxNewTokens 收尾,
  ## 而调用方应当能通过 `hasEos` 察觉并如实上报截断原因。
  tokenId in d.eosTokenIds

proc readIntField(node: JsonNode, key: string): int =
  if not node.hasKey(key):
    return -1
  let v = node[key]
  if v.kind == JInt: v.getInt else: -1

proc readFloatField(node: JsonNode, key: string): float =
  if not node.hasKey(key):
    return NaN
  let v = node[key]
  case v.kind
  of JFloat: v.getFloat
  of JInt: float(v.getInt)
  else: NaN

proc readEosIds(node: JsonNode): seq[int] =
  ## `eos_token_id` 允许是单个整数,也允许是整数数组。两种都必须支持:
  ## 只处理数组会在单值模型上静默丢掉唯一的 EOS。
  result = @[]
  if not node.hasKey("eos_token_id"):
    return
  let v = node["eos_token_id"]
  case v.kind
  of JInt:
    result.add(v.getInt)
  of JArray:
    for item in v:
      if item.kind == JInt:
        result.add(item.getInt)
  else:
    discard
  # 去重并排序,让相等性可比较、日志可复现。
  result = toSeq(result.toHashSet.items)
  result.sort()

proc parseGenerationDefaults*(raw: string,
                             source: string = ""): GenerationDefaults =
  ## 从 JSON 文本解析。供测试直接使用,不必落盘。
  result = initGenerationDefaults()
  let node =
    try:
      parseJson(raw)
    except JsonParsingError as e:
      raiseIsvikError(
        ecModelInvalid,
        "Generation configuration is not valid JSON",
        "source=" & source & " parse=" & e.msg
      )
  if node.kind != JObject:
    raiseIsvikError(
      ecModelInvalid,
      "Generation configuration must be a JSON object",
      "source=" & source & " got=" & $node.kind
    )
  result.bosTokenId = readIntField(node, "bos_token_id")
  result.padTokenId = readIntField(node, "pad_token_id")
  result.eosTokenIds = readEosIds(node)
  result.temperature = readFloatField(node, "temperature")
  result.topK = readIntField(node, "top_k")
  result.topP = readFloatField(node, "top_p")
  result.source = source

proc loadGenerationDefaults*(modelDir: string): GenerationDefaults =
  ## 从模型目录读取 `generation_config.json`。
  ##
  ## 文件不存在时返回全「未知」而**不报错**:很多模型目录确实没有这个文件,
  ## 那不是错误,只是信息缺失。调用方用 `isKnown` 区分两者。
  let path = modelDir / GenerationConfigFile
  if not fileExists(path):
    return initGenerationDefaults()
  let raw =
    try:
      readFile(path)
    except IOError as e:
      raiseIsvikError(
        ecModelInvalid,
        "Failed to read the generation configuration",
        "path=" & path & " io=" & e.msg
      )
  result = parseGenerationDefaults(raw, path)
