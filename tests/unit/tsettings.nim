## Task 4 测试:settings.json 读写与校验(§33)

import std/[unittest, os, json, strutils, options]

import isvik/core/errors
import isvik/logging/logger
import isvik/config/paths
import isvik/config/settings

var tmpCounter = 0

proc makeTempDir(): string =
  inc tmpCounter
  result = getTempDir() / ("isvik_test_settings_" & $tmpCounter)
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc expectInvalidParameter(body: proc ()) =
  ## 断言 body 抛出 IsvikError(INVALID_PARAMETER)。
  var caught = false
  var code: IsvikErrorCode
  try:
    body()
  except IsvikError as e:
    caught = true
    code = e.code
  check caught
  if caught:
    check code == ecInvalidParameter

suite "默认配置符合 §33 与 §21":

  test "包含 §33 要求的全部字段":
    let node = defaultSettings().toJsonNode()
    check node.hasKey("language")
    check node.hasKey("default_device")
    check node.hasKey("model_directory")
    check node.hasKey("cache_directory")
    check node.hasKey("server")
    check node.hasKey("logging")

  test "默认监听 127.0.0.1,不是 0.0.0.0(§21)":
    # §21 明确禁止默认监听 0.0.0.0。
    let d = defaultSettings()
    check d.server.host == "127.0.0.1"
    check d.server.host != "0.0.0.0"

  test "默认端口不复用 Ollama 的 11434(§81)":
    # Isvik 必须拥有自己的标识,复用他人端口会造成冲突与混淆。
    let d = defaultSettings()
    check d.server.port != 11434
    check d.server.port == DefaultServerPort
    check d.server.port >= MinPort
    check d.server.port <= MaxPort

  test "默认语言与设备取自受支持的取值集合":
    let d = defaultSettings()
    check d.language in SupportedLanguages
    check d.defaultDevice in SupportedDevices
    check d.defaultDevice == "AUTO"   # §12 默认 AUTO 策略

  test "受支持的语言恰为 zh-CN 与 en-US(§31)":
    check SupportedLanguages.len == 2
    check "zh-CN" in SupportedLanguages
    check "en-US" in SupportedLanguages

  test "受支持的设备为 AUTO/CPU/GPU/NPU(§11)":
    check SupportedDevices.len == 4
    check "AUTO" in SupportedDevices
    check "CPU" in SupportedDevices
    check "GPU" in SupportedDevices
    check "NPU" in SupportedDevices

  test "目录覆盖项默认为空,表示使用 ISVIK_HOME 下的默认位置":
    let d = defaultSettings()
    check d.modelDirectory == ""
    check d.cacheDirectory == ""

  test "默认日志级别为 INFO,Console 与 File 均开启(§34)":
    let d = defaultSettings()
    check d.logging.level == llInfo
    check d.logging.console
    check d.logging.file

  test "默认配置通过校验":
    check validate(defaultSettings()).isNone

suite "JSON 往返":

  test "序列化后反序列化得到相同配置":
    var s = defaultSettings()
    s.language = "en-US"
    s.defaultDevice = "NPU"
    s.modelDirectory = "D:/models"
    s.cacheDirectory = "D:/cache"
    s.server.host = "127.0.0.1"
    s.server.port = 8080
    s.logging.level = llDebug
    s.logging.console = false
    s.logging.file = true

    let restored = fromJsonNode(s.toJsonNode())

    check restored.language == s.language
    check restored.defaultDevice == s.defaultDevice
    check restored.modelDirectory == s.modelDirectory
    check restored.cacheDirectory == s.cacheDirectory
    check restored.server.host == s.server.host
    check restored.server.port == s.server.port
    check restored.logging.level == s.logging.level
    check restored.logging.console == s.logging.console
    check restored.logging.file == s.logging.file

  test "字段名采用 §33 的 snake_case":
    let text = $defaultSettings().toJsonNode()
    check text.contains("\"default_device\"")
    check text.contains("\"model_directory\"")
    check text.contains("\"cache_directory\"")
    # 不应出现 camelCase 形式
    check not text.contains("defaultDevice")
    check not text.contains("modelDirectory")

  test "日志级别以字符串形式存储":
    var s = defaultSettings()
    s.logging.level = llWarn
    check s.toJsonNode()["logging"]["level"].getStr == "WARN"

suite "缺失字段回落默认值(向前兼容)":

  test "空对象得到全部默认值":
    let s = fromJsonNode(parseJson("{}"))
    check s == defaultSettings()

  test "只提供部分字段时其余为默认值":
    let s = fromJsonNode(parseJson("""{"language": "en-US"}"""))
    check s.language == "en-US"
    check s.defaultDevice == DefaultDevice
    check s.server.host == DefaultServerHost
    check s.server.port == DefaultServerPort
    check s.logging.level == llInfo

  test "server 对象缺失时其子字段全部为默认值":
    let s = fromJsonNode(parseJson("""{"default_device": "CPU"}"""))
    check s.server.host == DefaultServerHost
    check s.server.port == DefaultServerPort

  test "server 对象只提供 port 时 host 为默认值":
    let s = fromJsonNode(parseJson("""{"server": {"port": 9000}}"""))
    check s.server.port == 9000
    check s.server.host == DefaultServerHost

  test "logging 对象只提供 level 时布尔项为默认值":
    let s = fromJsonNode(parseJson("""{"logging": {"level": "ERROR"}}"""))
    check s.logging.level == llError
    check s.logging.console
    check s.logging.file

  test "未知字段被忽略,不报错":
    # 向前兼容:新版本写入的字段不该让旧版本崩溃。
    let s = fromJsonNode(parseJson("""{"future_field": 123, "language": "zh-CN"}"""))
    check s.language == "zh-CN"

suite "类型错误必须报错,不得静默回落":

  test "language 为数字时报错":
    # 静默改成默认值会让程序行为与用户所写配置不符,且毫无提示。
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson("""{"language": 42}""")))

  test "port 为字符串时报错":
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson("""{"server": {"port": "8080"}}""")))

  test "port 为浮点数时报错":
    # 7317.5 是配置错误,不是可四舍五入的输入。
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson("""{"server": {"port": 7317.5}}""")))

  test "console 为字符串时报错":
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson("""{"logging": {"console": "yes"}}""")))

  test "server 为字符串时报错":
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson("""{"server": "127.0.0.1:8080"}""")))

  test "logging 为数组时报错":
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson("""{"logging": []}""")))

  test "顶层为数组时报错":
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson("""[]""")))

  test "顶层为字符串时报错":
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson(""""just a string"""")))

  test "错误信息指明字段名与期望类型":
    try:
      discard fromJsonNode(parseJson("""{"server": {"port": "abc"}}"""))
      check false
    except IsvikError as e:
      check e.detail.contains("server.port")
      check e.detail.contains("expected=integer")
      check e.detail.contains("got=string")

suite "取值非法必须报错":

  test "未知语言被拒绝":
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson("""{"language": "fr-FR"}""")))

  test "未知设备被拒绝":
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson("""{"default_device": "TPU"}""")))

  test "未知日志级别被拒绝":
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson("""{"logging": {"level": "TRACE"}}""")))

  test "日志级别大小写不敏感":
    # 这是便利性让步,取值集合本身仍然严格。
    check fromJsonNode(parseJson("""{"logging":{"level":"debug"}}""")).logging.level == llDebug
    check fromJsonNode(parseJson("""{"logging":{"level":"Warn"}}""")).logging.level == llWarn

  test "端口越界被拒绝":
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson("""{"server": {"port": 0}}""")))
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson("""{"server": {"port": 65536}}""")))
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson("""{"server": {"port": -1}}""")))

  test "端口边界值被接受":
    check fromJsonNode(parseJson("""{"server":{"port":1}}""")).server.port == 1
    check fromJsonNode(parseJson("""{"server":{"port":65535}}""")).server.port == 65535

  test "空 host 被拒绝":
    expectInvalidParameter(proc () =
      discard fromJsonNode(parseJson("""{"server": {"host": "   "}}""")))

  test "validate 的错误原因是可读文本":
    var s = defaultSettings()
    s.language = "de-DE"
    let problem = validate(s)
    check problem.isSome
    check problem.get.contains("language")
    check problem.get.contains("de-DE")

suite "文件读写":

  test "文件不存在时返回默认值,不报错":
    # 首次运行是正常路径。
    let dir = makeTempDir()
    let s = loadSettings(dir / "nonexistent.json")
    check s == defaultSettings()

  test "写入后能读回相同内容":
    let dir = makeTempDir()
    let path = dir / "settings.json"

    var s = defaultSettings()
    s.language = "en-US"
    s.server.port = 9999
    s.logging.level = llFatal
    saveSettings(path, s)

    check fileExists(path)
    let loaded = loadSettings(path)
    check loaded == s

  test "写入的文件是格式化的合法 JSON,便于人工编辑":
    let dir = makeTempDir()
    let path = dir / "settings.json"
    saveSettings(path, defaultSettings())

    let raw = readFile(path)
    check raw.endsWith("\n")           # 以换行结尾
    check raw.contains("\n")            # 多行(pretty)
    discard parseJson(raw)              # 合法 JSON

  test "父目录不存在时自动创建":
    let dir = makeTempDir()
    let path = dir / "config" / "deeper" / "settings.json"
    saveSettings(path, defaultSettings())
    check fileExists(path)

  test "JSON 语法错误时报错并指出文件路径":
    let dir = makeTempDir()
    let path = dir / "broken.json"
    writeFile(path, "{ this is not json")

    var caught = false
    try:
      discard loadSettings(path)
    except IsvikError as e:
      caught = true
      check e.code == ecInvalidParameter
      check e.detail.contains(path)
    check caught

  test "字段类型错误时报错并指出文件路径":
    let dir = makeTempDir()
    let path = dir / "badtype.json"
    writeFile(path, """{"server": {"port": "not a number"}}""")

    var caught = false
    try:
      discard loadSettings(path)
    except IsvikError as e:
      caught = true
      check e.detail.contains(path)
      check e.detail.contains("server.port")
    check caught

  test "拒绝保存非法配置":
    let dir = makeTempDir()
    var s = defaultSettings()
    s.server.port = 70000
    expectInvalidParameter(proc () =
      saveSettings(dir / "settings.json", s))

  test "保存失败时不产生损坏的目标文件":
    # 先写入一份合法配置,再尝试保存非法配置,原文件应保持完好。
    let dir = makeTempDir()
    let path = dir / "settings.json"
    saveSettings(path, defaultSettings())
    let before = readFile(path)

    var bad = defaultSettings()
    bad.language = "xx-XX"
    try:
      saveSettings(path, bad)
    except IsvikError:
      discard

    check readFile(path) == before

  test "覆盖写入不残留临时文件":
    let dir = makeTempDir()
    let path = dir / "settings.json"
    saveSettings(path, defaultSettings())
    var s = defaultSettings()
    s.server.port = 8888
    saveSettings(path, s)

    check not fileExists(path & ".tmp")
    check loadSettings(path).server.port == 8888

  test "loadOrCreateSettings 首次运行时创建文件":
    # 让用户在磁盘上看到完整可编辑的配置,而不是面对空目录猜配置项。
    let dir = makeTempDir()
    let path = dir / "settings.json"
    check not fileExists(path)

    let s = loadOrCreateSettings(path)

    check fileExists(path)
    check s == defaultSettings()
    check loadSettings(path) == defaultSettings()

  test "loadOrCreateSettings 已存在时不覆盖用户修改":
    let dir = makeTempDir()
    let path = dir / "settings.json"

    var custom = defaultSettings()
    custom.server.port = 12345
    saveSettings(path, custom)

    let s = loadOrCreateSettings(path)
    check s.server.port == 12345

suite "与目录布局协同":

  test "在 IsvikPaths 的 config 目录下完成初始化":
    let p = newIsvikPaths(makeTempDir() / "home")
    p.ensureDirectories()

    let s = loadOrCreateSettings(p.settingsFile)

    check fileExists(p.settingsFile)
    check s == defaultSettings()
    check isInsideDirectory(p.root, p.settingsFile)

  test "settings.json 未创建目录时也能落盘":
    # saveSettings 自行创建父目录,不强制先调 ensureDirectories。
    let p = newIsvikPaths(makeTempDir() / "lazy")
    check not dirExists(p.config)
    discard loadOrCreateSettings(p.settingsFile)
    check fileExists(p.settingsFile)
