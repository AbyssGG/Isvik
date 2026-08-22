## Isvik 数据目录与路径安全
##
## 对应 Master Prompt §16(Model Storage)与 §38(Security)。
##
## ---
##
## ## 目录根的解析顺序
##
## 1. 环境变量 `ISVIK_HOME`(非空时优先,支持 `~` 展开)
## 2. `~/.isvik`(§16 规定的默认值)
##
## §16 明确禁止硬编码 `C:\Users\xxx`。这里使用 `getHomeDir()`,
## 它在 Windows 上解析为 `%USERPROFILE%`,不含任何字面用户名。
##
## ---
##
## ## 为什么路径校验比「拒绝 ..」复杂得多
##
## Windows 上的路径攻击面远不止 `../`:
##
## | 输入 | 危害 |
## | --- | --- |
## | `../../etc/passwd` | 经典目录穿越 |
## | `C:\Windows\System32\x` | 绝对路径逃逸 |
## | `\\server\share\x` | UNC 路径,访问远程主机 |
## | `C:foo` | 盘符相对路径,解析到该盘当前目录 |
## | `CON` / `NUL` / `COM1` | **写入 Windows 设备而非文件** |
## | `CON.txt` | 同上 —— 保留名的判定发生在扩展名之前 |
## | `file:stream` | NTFS 备用数据流(ADS),内容对普通读取不可见 |
## | `foo.` / `foo ` | Windows 静默剥离尾部点与空格,`foo.` 实际写入 `foo` |
##
## 最后一项尤其隐蔽:校验时看到的名字与实际落盘的名字不同,
## 可被用来绕过基于名字的白名单。因此这些形式一律拒绝,而不是尝试规范化 ——
## 拒绝可疑输入比猜测用户意图安全。

import std/[os, strutils, options]

import isvik/core/errors

type
  IsvikPaths* = object
    ## Isvik 的数据目录布局(§16)。所有字段均为绝对路径。
    root*: string     ## 数据根目录
    models*: string   ## 模型清单与元数据
    blobs*: string    ## 模型权重等大文件
    cache*: string    ## 编译缓存(.blob)
    logs*: string     ## 日志
    config*: string   ## 配置
    data*: string     ## 其它运行时数据

const
  IsvikHomeEnvVar* = "ISVIK_HOME"
    ## 覆盖数据根目录的环境变量名。

  DefaultHomeDirName* = ".isvik"
    ## 默认数据目录名,置于用户主目录下(§16)。

  IsvikSubdirectories*: array[6, string] = [
    ## §16 规定的子目录集合。顺序固定,便于测试断言。
    "models", "blobs", "cache", "logs", "config", "data"
  ]

  WindowsReservedNames*: array[22, string] = [
    ## Windows 保留设备名。以这些名字创建文件会写入设备而非磁盘。
    ## 判定时需忽略大小写并去掉扩展名(`CON.txt` 同样被保留)。
    "CON", "PRN", "AUX", "NUL",
    "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
    "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9"
  ]

# ---------------------------------------------------------------------------
# 根目录解析
# ---------------------------------------------------------------------------

proc resolveIsvikHome*(): string =
  ## 解析 Isvik 数据根目录。
  ##
  ## `ISVIK_HOME` 非空(去除首尾空白后)时优先使用,否则回落到 `~/.isvik`。
  ## 支持 `~` 展开,结果为规范化的绝对路径。
  let fromEnv = getEnv(IsvikHomeEnvVar).strip()
  if fromEnv.len > 0:
    return normalizedPath(absolutePath(expandTilde(fromEnv)))
  result = normalizedPath(getHomeDir() / DefaultHomeDirName)

proc newIsvikPaths*(root: string = ""): IsvikPaths =
  ## 构造目录布局。`root` 为空时调用 `resolveIsvikHome()`。
  ##
  ## 只计算路径,不创建任何目录 —— 创建由 `ensureDirectories` 显式完成,
  ## 使「读取路径」成为无副作用操作。
  let base =
    if root.strip().len > 0:
      normalizedPath(absolutePath(expandTilde(root.strip())))
    else:
      resolveIsvikHome()
  result = IsvikPaths(
    root: base,
    models: base / "models",
    blobs: base / "blobs",
    cache: base / "cache",
    logs: base / "logs",
    config: base / "config",
    data: base / "data"
  )

proc allDirectories*(paths: IsvikPaths): seq[string] =
  ## 全部目录(含 root),顺序与 `IsvikSubdirectories` 一致。
  result = @[paths.root]
  for name in IsvikSubdirectories:
    result.add(paths.root / name)

proc ensureDirectories*(paths: IsvikPaths) =
  ## 创建全部目录。幂等:已存在时不报错。
  ##
  ## 创建失败抛 IsvikError(SERVER_ERROR),而不是让后续操作在更深处
  ## 以更难理解的方式失败。
  for dir in paths.allDirectories():
    if dirExists(dir):
      continue
    try:
      createDir(dir)
    except OSError as e:
      raiseIsvikError(
        ecServerError,
        "Failed to create Isvik data directory",
        "path=" & dir & " os=" & e.msg
      )

proc directoriesExist*(paths: IsvikPaths): bool =
  ## 全部目录是否都已存在。
  for dir in paths.allDirectories():
    if not dirExists(dir):
      return false
  result = true

proc settingsFile*(paths: IsvikPaths): string =
  ## settings.json 的完整路径(§33:`~/.isvik/config/settings.json`)。
  paths.config / "settings.json"

proc apiKeysFile*(paths: IsvikPaths): string =
  ## API Key 元数据文件。文件内只保存摘要,不保存明文 Key。
  paths.config / "api_keys.json"

# ---------------------------------------------------------------------------
# 路径安全校验(§38)
# ---------------------------------------------------------------------------

proc isWindowsReservedName*(segment: string): bool =
  ## 该路径段是否为 Windows 保留设备名。
  ##
  ## 判定在扩展名之前进行:`CON`、`con`、`CON.txt` 均视为保留。
  if segment.len == 0:
    return false
  let dotPos = segment.find('.')
  let stem = if dotPos >= 0: segment[0 ..< dotPos] else: segment
  let upper = stem.toUpperAscii
  for reserved in WindowsReservedNames:
    if upper == reserved:
      return true
  result = false

proc checkRelativePath*(userPath: string): Option[string] =
  ## 校验用户提供的**相对**路径是否安全。
  ##
  ## 返回 `none` 表示安全;返回 `some(reason)` 表示拒绝,reason 是拒绝原因。
  ## 采用返回原因而非布尔值,使错误信息能明确指出问题所在。
  if userPath.len == 0:
    return some("path is empty")

  if '\0' in userPath:
    return some("path contains NUL byte")

  if userPath.strip() != userPath:
    return some("path has leading or trailing whitespace")

  if isAbsolute(userPath):
    return some("absolute paths are not allowed")

  # UNC 前缀。isAbsolute 在部分平台上不认为 \\server\share 是绝对路径,
  # 因此单独判定。
  if userPath.startsWith("\\\\") or userPath.startsWith("//"):
    return some("UNC paths are not allowed")

  # ':' 同时覆盖两种危险:盘符相对路径(C:foo)与 NTFS 备用数据流(f:stream)。
  if ':' in userPath:
    return some("path contains ':' (drive-relative path or NTFS data stream)")

  # 统一按两种分隔符切分,不依赖当前平台的 DirSep。
  let segments = userPath.multiReplace(("\\", "/")).split('/')
  for i, segment in segments:
    if segment.len == 0:
      # 允许结尾的 "a/b/" 形式产生的空尾段,其余空段说明存在 "a//b"。
      if i == segments.high:
        continue
      return some("path contains an empty segment")

    if segment == "..":
      return some("path contains '..' segment")

    if segment == ".":
      return some("path contains '.' segment")

    # Windows 会静默剥离尾部的点与空格,使校验看到的名字与实际落盘名不同。
    if segment.endsWith(".") or segment.endsWith(" "):
      return some("path segment ends with '.' or space")

    if segment.startsWith(" "):
      return some("path segment starts with space")

    if isWindowsReservedName(segment):
      return some("path segment is a reserved Windows device name: " & segment)

    for c in segment:
      # Windows 文件名非法字符。在所有平台上一律拒绝,保证跨平台一致,
      # 也避免在 Linux 上创建出无法在 Windows 上读取的模型库。
      if c in {'<', '>', '"', '|', '?', '*'} or ord(c) < 32:
        return some("path segment contains an invalid character")

  result = none(string)

proc isInsideDirectory*(baseDir, candidate: string): bool =
  ## `candidate` 规范化后是否位于 `baseDir` 之内(或恰为 baseDir 本身)。
  ##
  ## Windows 上路径比较不区分大小写,因此按平台选择比较方式。
  ## 这是最后一道防线:即使前面的字符串校验有疏漏,这里也会拦住逃逸。
  let base = normalizedPath(absolutePath(baseDir))
  let target = normalizedPath(absolutePath(candidate))

  when defined(windows):
    let b = base.toLowerAscii
    let t = target.toLowerAscii
  else:
    let b = base
    let t = target

  if t == b:
    return true
  # 必须以「base + 分隔符」开头,避免 C:\isvikEVIL 被当作在 C:\isvik 之内。
  result = t.startsWith(b & $DirSep) or t.startsWith(b & "/")

proc safeJoin*(baseDir, userPath: string): string =
  ## 将用户提供的相对路径安全地拼接到 baseDir 下。
  ##
  ## 校验失败抛 IsvikError(INVALID_PARAMETER)。detail 中包含被拒绝的原始输入
  ## 与原因,便于排查;由错误模型保证 detail 不会进入 API 响应。
  let problem = checkRelativePath(userPath)
  if problem.isSome:
    raiseIsvikError(
      ecInvalidParameter,
      "Rejected unsafe path",
      "path=" & userPath & " reason=" & problem.get
    )

  let joined = normalizedPath(absolutePath(baseDir) / userPath)

  if not isInsideDirectory(baseDir, joined):
    raiseIsvikError(
      ecInvalidParameter,
      "Rejected unsafe path",
      "path=" & userPath & " reason=resolved outside of base directory"
    )

  result = joined

proc trySafeJoin*(baseDir, userPath: string): Option[string] =
  ## `safeJoin` 的非异常版本。不安全时返回 none。
  if checkRelativePath(userPath).isSome:
    return none(string)
  let joined = normalizedPath(absolutePath(baseDir) / userPath)
  if not isInsideDirectory(baseDir, joined):
    return none(string)
  result = some(joined)
