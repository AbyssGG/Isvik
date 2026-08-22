## i18n 文案目录(Master Prompt §31 / §62)
##
## ---
##
## ## 为什么不做「取不到就用键名」的静默回落
##
## 最常见的 i18n 实现在缺键时返回键名本身,于是界面上出现
## `usage.cmd.version` 这种字符串 —— 看起来像 bug,但不会让任何测试失败,
## 于是能一直活到发布。
##
## 这里用两条并行的机制:
##
## 1. `t()` 缺键时返回 `??key??`,**刻意难看**,肉眼一眼能看出不对;
## 2. 更重要的是 `tests/unit/ti18n.nim` 断言 zh-CN 与 en-US 的键集合
##    **完全相同**。漏译一条就让测试失败,而不是等用户切到英文才发现。
##
## 第 2 条才是真正的保障;第 1 条只是兜底。
##
## ---
##
## ## 占位符
##
## 使用 `strutils` 的 `%`,即 `$1` / `$2` 风格:
##
## ```text
## "未知命令:$1"  →  t(cat, "error.unknownCommand", ["serv"])
## ```
##
## **只有传了参数时才做替换。** 否则一条含字面 `$` 的文案(例如 shell 示例)
## 会在没有参数时被 `%` 当成占位符而抛异常。这个坑很隐蔽:往文案里加一个
## `$` 就会让原本正常的命令崩掉。
##
## ---
##
## ## 边界
##
## 本模块属于产品层,依赖方向是 CLI / Server / GUI → i18n。
## Core **不得** import 它:Core 只产生稳定的错误码与事件,
## 本地化是展示层的事(§22「GUI 根据 Error Code 本地化」)。

import std/[tables, strutils, algorithm, sequtils]

import isvik/core/errors
import isvik/i18n/locale_zh_cn
import isvik/i18n/locale_en_us

type
  Language* = enum
    ## §31 要求支持的两种语言。字符串值是稳定契约,与 `settings.json` 的
    ## `language` 字段、CLI 的 `--lang` 取值完全一致。
    langZhCn = "zh-CN"
    langEnUs = "en-US"

  Catalog* = ref object
    ## 某一语言的完整文案表。
    language: Language
    entries: Table[string, string]

const
  SupportedLanguageCodes*: array[2, string] = ["zh-CN", "en-US"]
    ## 必须与 `config/settings.nim` 的 `SupportedLanguages` 一致,
    ## 由 `tests/unit/ti18n.nim` 断言两者不分叉。

  DefaultLanguageCode* = "zh-CN"
    ## 默认语言。项目文档与交付以中文为先。

  MissingPrefix* = "??"
  MissingSuffix* = "??"
    ## 缺键标记。刻意难看,见模块顶部说明。

proc `$`*(lang: Language): string =
  case lang
  of langZhCn: "zh-CN"
  of langEnUs: "en-US"

proc isSupportedLanguage*(code: string): bool =
  ## 该语言代码是否受支持。大小写敏感,与配置文件取值一致。
  code in SupportedLanguageCodes

proc parseLanguage*(code: string): Language =
  ## 解析语言代码。未知取值抛 INVALID_PARAMETER。
  ##
  ## 不回落到默认语言:用户显式传了 `--lang de-DE` 却得到中文界面,
  ## 会让人以为参数生效了。明确报错更有用。
  case code
  of "zh-CN": langZhCn
  of "en-US": langEnUs
  else:
    raiseIsvikError(
      ecInvalidParameter,
      "Unsupported language code",
      "language=" & code & " supported=" & SupportedLanguageCodes.join(",")
    )

proc newCatalog*(language: Language,
                 entries: openArray[(string, string)]): Catalog =
  ## 从条目数组构造文案表。重复键抛 INVALID_PARAMETER。
  ##
  ## 拒绝重复键而不是让后者覆盖前者:重复通常意味着合并冲突或复制粘贴,
  ## 静默覆盖会让「实际生效的是哪一条」变得不可预测。
  new(result)
  result.language = language
  result.entries = initTable[string, string]()
  for (key, value) in entries:
    if result.entries.hasKey(key):
      raiseIsvikError(
        ecInvalidParameter,
        "Duplicate i18n key in catalog",
        "language=" & $language & " key=" & key
      )
    result.entries[key] = value

proc language*(cat: Catalog): Language = cat.language

proc hasMessage*(cat: Catalog, key: string): bool =
  cat != nil and cat.entries.hasKey(key)

proc messageKeys*(cat: Catalog): seq[string] =
  ## 全部键,已排序。供测试比较两种语言的键集合。
  if cat == nil:
    return @[]
  result = cat.entries.keys.toSeq
  sort(result)

proc messageCount*(cat: Catalog): int =
  if cat == nil: 0 else: cat.entries.len

proc t*(cat: Catalog, key: string): string =
  ## 取文案,不做占位符替换(见模块顶部关于字面 `$` 的说明)。
  if cat == nil or not cat.entries.hasKey(key):
    return MissingPrefix & key & MissingSuffix
  result = cat.entries[key]

proc t*(cat: Catalog, key: string, args: openArray[string]): string =
  ## 取文案并替换 `$1` / `$2` 等占位符。
  ##
  ## 参数个数与占位符不匹配时 `%` 抛 ValueError。这里转成 IsvikError,
  ## 以免一处文案笔误让进程带着看不懂的异常退出。
  let raw = cat.t(key)
  if args.len == 0:
    return raw
  try:
    result = raw % args.toSeq
  except ValueError as e:
    raiseIsvikError(
      ecServerError,
      "i18n message placeholder mismatch",
      "key=" & key & " args=" & $args.len & " reason=" & e.msg
    )

proc catalogFor*(language: Language): Catalog =
  ## 取指定语言的文案表。
  case language
  of langZhCn: newCatalog(langZhCn, ZhCnMessages)
  of langEnUs: newCatalog(langEnUs, EnUsMessages)

proc resolveLanguage*(explicit: string = "",
                      fromSettings: string = ""): Language =
  ## 按优先级解析生效语言:`--lang` > `settings.json` > 默认 zh-CN。
  ##
  ## 命令行优先于配置,因为它用于临时覆盖;两者都为空才用默认值。
  ## 任一非空但非法的取值都会报错,不会被悄悄忽略。
  if explicit.strip().len > 0:
    return parseLanguage(explicit.strip())
  if fromSettings.strip().len > 0:
    return parseLanguage(fromSettings.strip())
  result = parseLanguage(DefaultLanguageCode)
