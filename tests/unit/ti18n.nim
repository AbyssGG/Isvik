## i18n 测试
##
## 最重要的一条是「两种语言的键集合完全相同」—— 那是漏译的唯一自动化防线。
## 其余用例覆盖解析优先级、占位符与缺键行为。

import std/[unittest, strutils, sets, sequtils]

import isvik/core/errors
import isvik/config/settings
import isvik/i18n/catalog
import isvik/i18n/locale_zh_cn
import isvik/i18n/locale_en_us

suite "语言标识是稳定契约":

  test "两种语言的字符串表示精确匹配 §31":
    check $langZhCn == "zh-CN"
    check $langEnUs == "en-US"

  test "语言总数为 2":
    var count = 0
    for _ in Language:
      inc count
    check count == 2
    check SupportedLanguageCodes.len == 2

  test "i18n 的语言集合与 settings 的不分叉":
    # 两处各自维护一份列表,分叉后果是「配置里能写的语言 i18n 不认」。
    for code in SupportedLanguageCodes:
      check code in SupportedLanguages
    for code in SupportedLanguages:
      check code in SupportedLanguageCodes

  test "默认语言与 settings 的默认值一致":
    check DefaultLanguageCode == DefaultLanguage
    check DefaultLanguageCode == "zh-CN"

  test "合法语言被识别,非法语言被拒绝":
    check isSupportedLanguage("zh-CN")
    check isSupportedLanguage("en-US")
    check not isSupportedLanguage("de-DE")
    check not isSupportedLanguage("zh-cn")     # 大小写敏感
    check not isSupportedLanguage("")

  test "parseLanguage 对未知取值抛 INVALID_PARAMETER":
    check parseLanguage("zh-CN") == langZhCn
    check parseLanguage("en-US") == langEnUs
    var code: IsvikErrorCode
    try:
      discard parseLanguage("fr-FR")
      check false
    except IsvikError as e:
      code = e.code
    check code == ecInvalidParameter

suite "两种语言的键集合必须完全相同":

  test "zh-CN 与 en-US 的键逐一对应":
    # 这是漏译的唯一自动化防线。失败时下面会打印具体缺了哪些键。
    let zh = catalogFor(langZhCn)
    let en = catalogFor(langEnUs)

    let zhKeys = zh.messageKeys.toHashSet
    let enKeys = en.messageKeys.toHashSet

    let missingInEn = zhKeys - enKeys
    let missingInZh = enKeys - zhKeys

    if missingInEn.len > 0:
      checkpoint("en-US 缺少:" & missingInEn.toSeq.join(", "))
    if missingInZh.len > 0:
      checkpoint("zh-CN 缺少:" & missingInZh.toSeq.join(", "))

    check missingInEn.len == 0
    check missingInZh.len == 0
    check zh.messageCount == en.messageCount

  test "文案表非空,防止空扫描导致上一条假通过":
    check catalogFor(langZhCn).messageCount >= 60
    check ZhCnMessages.len >= 60
    check EnUsMessages.len >= 60

  test "没有任何文案是空字符串":
    # 空文案在界面上表现为「什么都没显示」,比缺键更难发现。
    for cat in [catalogFor(langZhCn), catalogFor(langEnUs)]:
      for key in cat.messageKeys:
        check cat.t(key).len > 0

  test "两种语言的占位符数量一致":
    # 中文写了 $1$2、英文只写 $1,英文界面就会丢信息。
    let zh = catalogFor(langZhCn)
    let en = catalogFor(langEnUs)
    for key in zh.messageKeys:
      let zhText = zh.t(key)
      let enText = en.t(key)
      for n in 1 .. 3:
        let placeholder = "$" & $n
        if zhText.contains(placeholder) != enText.contains(placeholder):
          checkpoint("占位符不一致 key=" & key & " placeholder=" & placeholder)
          checkpoint("  zh: " & zhText)
          checkpoint("  en: " & enText)
        check zhText.contains(placeholder) == enText.contains(placeholder)

  test "重复键在构造时被拒绝":
    var raised = false
    try:
      discard newCatalog(langZhCn, [("a", "1"), ("a", "2")])
    except IsvikError as e:
      raised = true
      check e.code == ecInvalidParameter
    check raised

suite "取文案":

  test "存在的键返回对应语言的文案":
    check catalogFor(langZhCn).t("error.prefix") == "错误"
    check catalogFor(langEnUs).t("error.prefix") == "Error"

  test "缺键返回显眼的标记,而不是静默回落到键名":
    let cat = catalogFor(langZhCn)
    let missing = cat.t("no.such.key")
    check missing == "??no.such.key??"
    check missing.startsWith(MissingPrefix)
    check not cat.hasMessage("no.such.key")

  test "nil 目录不崩溃":
    let cat: Catalog = nil
    check cat.t("error.prefix") == "??error.prefix??"
    check not cat.hasMessage("error.prefix")
    check cat.messageCount == 0
    check cat.messageKeys.len == 0

  test "占位符被按顺序替换":
    let cat = catalogFor(langZhCn)
    check cat.t("error.unknownCommand", ["serv"]) == "未知命令:serv"
    check cat.t("error.unknownSubcommand", ["config", "pth"]) ==
      "未知的 config 子命令:pth"

  test "英文占位符同样生效":
    let cat = catalogFor(langEnUs)
    check cat.t("error.unknownCommand", ["serv"]) == "Unknown command: serv"

  test "不传参数时不做替换":
    # 这条防的是「文案里含字面 $ 就崩掉」。
    let cat = newCatalog(langZhCn, [("shell", "export PATH=$PATH:/opt")])
    check cat.t("shell") == "export PATH=$PATH:/opt"

  test "参数与占位符不匹配时抛 SERVER_ERROR 而不是 ValueError":
    let cat = newCatalog(langZhCn, [("two", "$1 与 $2")])
    var code: IsvikErrorCode
    try:
      discard cat.t("two", ["只有一个"])
      check false
    except IsvikError as e:
      code = e.code
    check code == ecServerError

  test "catalogFor 返回的目录带正确的语言标记":
    check catalogFor(langZhCn).language == langZhCn
    check catalogFor(langEnUs).language == langEnUs

suite "语言解析优先级":

  test "命令行优先于配置":
    check resolveLanguage("en-US", "zh-CN") == langEnUs
    check resolveLanguage("zh-CN", "en-US") == langZhCn

  test "命令行为空时用配置":
    check resolveLanguage("", "en-US") == langEnUs

  test "两者都为空时用默认 zh-CN":
    check resolveLanguage("", "") == langZhCn
    check resolveLanguage() == langZhCn

  test "首尾空白被忽略":
    check resolveLanguage("  en-US  ", "") == langEnUs
    check resolveLanguage("   ", "en-US") == langEnUs

  test "命令行传了非法值必须报错,不回落":
    # 静默回落会让用户以为 --lang 生效了。
    var code: IsvikErrorCode
    try:
      discard resolveLanguage("de-DE", "zh-CN")
      check false
    except IsvikError as e:
      code = e.code
    check code == ecInvalidParameter

  test "配置里的非法值同样报错":
    var raised = false
    try:
      discard resolveLanguage("", "klingon")
    except IsvikError:
      raised = true
    check raised
