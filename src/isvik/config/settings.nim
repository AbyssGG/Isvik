## Isvik 配置(settings.json)
##
## 对应 Master Prompt §33。文件位置:`<ISVIK_HOME>/config/settings.json`。
##
## ---
##
## ## 缺失字段与类型错误的区别(有意的设计)
##
## | 情况 | 处理 | 理由 |
## | --- | --- | --- |
## | 配置文件不存在 | 返回全部默认值 | 首次运行是正常情况,不该报错 |
## | 字段缺失 | 该字段用默认值 | 向前兼容:旧配置文件遇到新字段仍可用 |
## | 字段存在但类型错 | **报错** | 用户显式写了 `"port": "abc"`,静默忽略等于篡改其意图 |
## | 字段存在但取值非法 | **报错** | 同上,例如 `"language": "fr-FR"` |
## | JSON 语法错误 | **报错** | 文件损坏必须让人知道 |
##
## 静默把非法配置改成默认值是最糟的选择:程序看似正常运行,
## 但行为与用户所写的配置不符,且没有任何提示。
##
## ---
##
## 字段命名采用 snake_case,与 §33 给出的字段名一致
## (`default_device`、`model_directory` 等)。

import std/[json, os, strutils, options]

import isvik/core/errors
import isvik/logging/logger

type
  ServerSettings* = object
    ## Local Server 配置(§21)。
    host*: string
      ## 监听地址。默认 127.0.0.1;§21 明确禁止默认监听 0.0.0.0。
    port*: int

  LoggingSettings* = object
    ## 日志配置(§34)。
    level*: LogLevel
    console*: bool
    file*: bool

  Settings* = object
    ## §33 规定的配置项全集。
    language*: string
      ## 界面语言,取值见 SupportedLanguages(§31)。
      ## 暂用 string;Task 11 引入 i18n 后可考虑升级为枚举。
    defaultDevice*: string
      ## 默认设备,取值见 SupportedDevices(§12)。
      ## 暂用 string;Task 10 引入 DeviceType 后可考虑升级为枚举。
    modelDirectory*: string
      ## 模型目录覆盖。空字符串表示使用 `<ISVIK_HOME>/models`。
    cacheDirectory*: string
      ## 缓存目录覆盖。空字符串表示使用 `<ISVIK_HOME>/cache`。
    server*: ServerSettings
    logging*: LoggingSettings

const
  SupportedLanguages*: array[2, string] = ["zh-CN", "en-US"]
    ## §31 要求支持的两种语言。

  SupportedDevices*: array[4, string] = ["AUTO", "CPU", "GPU", "NPU"]
    ## §11 / §12 的统一设备标识。

  DefaultLanguage* = "zh-CN"
    ## 默认语言。项目文档以中文为先(Master Prompt 的 Language 约定)。

  DefaultDevice* = "AUTO"
    ## 默认设备策略(§12:AUTO → NPU → GPU → CPU)。

  DefaultServerHost* = "127.0.0.1"
    ## §21:默认只监听本机回环地址,禁止默认 0.0.0.0。

  DefaultServerPort* = 7317
    ## Isvik 自己的默认端口。
    ##
    ## 有意**不使用** 11434(Ollama 的端口):§81 要求 Isvik 拥有自己的
    ## API 与标识,复用他人端口既会造成冲突,也会让用户误以为是同一产品。

  MinPort* = 1
  MaxPort* = 65535

# ---------------------------------------------------------------------------
# 默认值
# ---------------------------------------------------------------------------

proc defaultSettings*(): Settings =
  ## 全部字段的默认值。
  Settings(
    language: DefaultLanguage,
    defaultDevice: DefaultDevice,
    modelDirectory: "",
    cacheDirectory: "",
    server: ServerSettings(
      host: DefaultServerHost,
      port: DefaultServerPort
    ),
    logging: LoggingSettings(
      level: llInfo,
      console: true,
      file: true
    )
  )

# ---------------------------------------------------------------------------
# 校验
# ---------------------------------------------------------------------------

proc validate*(s: Settings): Option[string] =
  ## 校验配置取值。返回 none 表示合法,some(reason) 说明问题所在。
  if s.language notin SupportedLanguages:
    return some("language must be one of " & SupportedLanguages.join(", ") &
                ", got: " & s.language)

  if s.defaultDevice notin SupportedDevices:
    return some("default_device must be one of " & SupportedDevices.join(", ") &
                ", got: " & s.defaultDevice)

  if s.server.host.strip().len == 0:
    return some("server.host must not be empty")

  if s.server.port < MinPort or s.server.port > MaxPort:
    return some("server.port must be in " & $MinPort & ".." & $MaxPort &
                ", got: " & $s.server.port)

  result = none(string)

# ---------------------------------------------------------------------------
# JSON 读取辅助
# ---------------------------------------------------------------------------

proc typeErrorName(kind: JsonNodeKind): string =
  case kind
  of JString: "string"
  of JInt: "integer"
  of JFloat: "float"
  of JBool: "boolean"
  of JObject: "object"
  of JArray: "array"
  of JNull: "null"

proc rejectFieldType(fieldPath, expected: string, got: JsonNodeKind) {.noreturn.} =
  raiseIsvikError(
    ecInvalidParameter,
    "Invalid type in settings file",
    "field=" & fieldPath & " expected=" & expected &
      " got=" & typeErrorName(got)
  )

proc readString(node: JsonNode, key, fieldPath, fallback: string): string =
  ## 读取字符串字段。缺失用默认值,类型错报错。
  if node == nil or not node.hasKey(key):
    return fallback
  let v = node[key]
  if v.kind != JString:
    rejectFieldType(fieldPath, "string", v.kind)
  result = v.getStr

proc readBool(node: JsonNode, key, fieldPath: string, fallback: bool): bool =
  if node == nil or not node.hasKey(key):
    return fallback
  let v = node[key]
  if v.kind != JBool:
    rejectFieldType(fieldPath, "boolean", v.kind)
  result = v.getBool

proc readInt(node: JsonNode, key, fieldPath: string, fallback: int): int =
  if node == nil or not node.hasKey(key):
    return fallback
  let v = node[key]
  # 明确不接受 JFloat:`"port": 7317.5` 是配置错误,不是可四舍五入的输入。
  if v.kind != JInt:
    rejectFieldType(fieldPath, "integer", v.kind)
  result = v.getInt

proc readObject(node: JsonNode, key, fieldPath: string): JsonNode =
  ## 读取对象字段。缺失返回 nil(调用方随后对每个子字段回落默认值)。
  if node == nil or not node.hasKey(key):
    return nil
  let v = node[key]
  if v.kind != JObject:
    rejectFieldType(fieldPath, "object", v.kind)
  result = v

proc readLogLevel(node: JsonNode, key, fieldPath: string,
                  fallback: LogLevel): LogLevel =
  ## 读取日志级别。取值必须是 §34 的五个级别之一(大小写不敏感)。
  if node == nil or not node.hasKey(key):
    return fallback
  let v = node[key]
  if v.kind != JString:
    rejectFieldType(fieldPath, "string", v.kind)
  let wanted = v.getStr.strip().toUpperAscii
  for level in LogLevel:
    if $level == wanted:
      return level
  var allowed: seq[string] = @[]
  for level in LogLevel:
    allowed.add($level)
  raiseIsvikError(
    ecInvalidParameter,
    "Invalid log level in settings file",
    "field=" & fieldPath & " allowed=" & allowed.join(",") & " got=" & v.getStr
  )

# ---------------------------------------------------------------------------
# 序列化
# ---------------------------------------------------------------------------

proc toJsonNode*(s: Settings): JsonNode =
  ## 转为 §33 字段名(snake_case)的 JSON。
  %*{
    "language": s.language,
    "default_device": s.defaultDevice,
    "model_directory": s.modelDirectory,
    "cache_directory": s.cacheDirectory,
    "server": {
      "host": s.server.host,
      "port": s.server.port
    },
    "logging": {
      "level": $s.logging.level,
      "console": s.logging.console,
      "file": s.logging.file
    }
  }

proc fromJsonNode*(node: JsonNode): Settings =
  ## 从 JSON 构造配置。缺失字段回落默认值,类型或取值错误抛 IsvikError。
  if node == nil or node.kind != JObject:
    raiseIsvikError(
      ecInvalidParameter,
      "Settings file must contain a JSON object",
      "got=" & (if node == nil: "nothing" else: typeErrorName(node.kind))
    )

  let d = defaultSettings()
  let serverNode = readObject(node, "server", "server")
  let loggingNode = readObject(node, "logging", "logging")

  result = Settings(
    language: readString(node, "language", "language", d.language),
    defaultDevice: readString(node, "default_device", "default_device",
                              d.defaultDevice),
    modelDirectory: readString(node, "model_directory", "model_directory",
                               d.modelDirectory),
    cacheDirectory: readString(node, "cache_directory", "cache_directory",
                               d.cacheDirectory),
    server: ServerSettings(
      host: readString(serverNode, "host", "server.host", d.server.host),
      port: readInt(serverNode, "port", "server.port", d.server.port)
    ),
    logging: LoggingSettings(
      level: readLogLevel(loggingNode, "level", "logging.level", d.logging.level),
      console: readBool(loggingNode, "console", "logging.console",
                        d.logging.console),
      file: readBool(loggingNode, "file", "logging.file", d.logging.file)
    )
  )

  let problem = validate(result)
  if problem.isSome:
    raiseIsvikError(
      ecInvalidParameter,
      "Invalid value in settings file",
      problem.get
    )

# ---------------------------------------------------------------------------
# 读写文件
# ---------------------------------------------------------------------------

proc loadSettings*(path: string): Settings =
  ## 从文件加载配置。
  ##
  ## 文件不存在时返回默认值(首次运行的正常路径,不报错)。
  ## JSON 语法错误、字段类型错误、取值非法时抛 IsvikError(INVALID_PARAMETER)。
  if not fileExists(path):
    return defaultSettings()

  let raw =
    try:
      readFile(path)
    except IOError as e:
      raiseIsvikError(
        ecServerError,
        "Failed to read settings file",
        "path=" & path & " io=" & e.msg
      )

  let node =
    try:
      parseJson(raw)
    except JsonParsingError as e:
      raiseIsvikError(
        ecInvalidParameter,
        "Settings file is not valid JSON",
        "path=" & path & " parse=" & e.msg
      )

  try:
    result = fromJsonNode(node)
  except IsvikError as e:
    # 补上文件路径,使错误可定位到具体文件。
    raiseIsvikError(e.code, e.msg, "path=" & path & " " & e.detail)

proc saveSettings*(path: string, s: Settings) =
  ## 将配置写入文件。
  ##
  ## 先写同目录下的临时文件,再替换目标文件。这样中途失败不会留下
  ## 被截断的 settings.json。
  ##
  ## 需要如实说明的局限:这**不是**完全原子的操作 —— Windows 上
  ## `moveFile` 要求目标不存在,因此存在「删除旧文件」与「移入新文件」
  ## 之间的窗口。若在该窗口内进程被杀,配置会丢失,但临时文件仍在,
  ## 内容可恢复。要做到真正原子需要调用 `ReplaceFileW`,
  ## 待配置规模增长或出现实际问题时再引入。
  let problem = validate(s)
  if problem.isSome:
    raiseIsvikError(
      ecInvalidParameter,
      "Refusing to save invalid settings",
      problem.get
    )

  let parent = path.parentDir
  if parent.len > 0 and not dirExists(parent):
    try:
      createDir(parent)
    except OSError as e:
      raiseIsvikError(
        ecServerError,
        "Failed to create settings directory",
        "path=" & parent & " os=" & e.msg
      )

  let tmpPath = path & ".tmp"
  let content = s.toJsonNode().pretty() & "\n"

  try:
    writeFile(tmpPath, content)
  except IOError as e:
    raiseIsvikError(
      ecServerError,
      "Failed to write temporary settings file",
      "path=" & tmpPath & " io=" & e.msg
    )

  try:
    if fileExists(path):
      removeFile(path)
    moveFile(tmpPath, path)
  except OSError as e:
    raiseIsvikError(
      ecServerError,
      "Failed to replace settings file",
      "path=" & path & " temp=" & tmpPath & " os=" & e.msg
    )

proc loadOrCreateSettings*(path: string): Settings =
  ## 加载配置;文件不存在时以默认值创建它。
  ##
  ## 用于首次运行:让用户在磁盘上看到一份完整的、可编辑的配置文件,
  ## 而不是面对一个空目录去猜有哪些可配置项。
  if fileExists(path):
    return loadSettings(path)
  result = defaultSettings()
  saveSettings(path, result)
