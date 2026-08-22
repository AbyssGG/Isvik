## Task 4 测试:数据目录布局与路径安全(§16 / §38)

import std/[unittest, os, strutils, options]

import isvik/core/errors
import isvik/config/paths

var tmpCounter = 0

proc makeTempDir(): string =
  inc tmpCounter
  result = getTempDir() / ("isvik_test_paths_" & $tmpCounter)
  if dirExists(result):
    removeDir(result)
  createDir(result)

suite "数据根目录解析":

  test "ISVIK_HOME 非空时优先使用":
    let custom = makeTempDir() / "custom_home"
    putEnv(IsvikHomeEnvVar, custom)
    defer: delEnv(IsvikHomeEnvVar)

    let resolved = resolveIsvikHome()
    check isInsideDirectory(custom, resolved)
    check resolved == normalizedPath(absolutePath(custom))

  test "ISVIK_HOME 为空白时回落到 ~/.isvik":
    putEnv(IsvikHomeEnvVar, "   ")
    defer: delEnv(IsvikHomeEnvVar)

    let resolved = resolveIsvikHome()
    check resolved == normalizedPath(getHomeDir() / DefaultHomeDirName)

  test "未设置 ISVIK_HOME 时使用 ~/.isvik":
    delEnv(IsvikHomeEnvVar)
    let resolved = resolveIsvikHome()
    check resolved.endsWith(DefaultHomeDirName)
    check resolved == normalizedPath(getHomeDir() / DefaultHomeDirName)

  test "解析结果始终是绝对路径":
    delEnv(IsvikHomeEnvVar)
    check isAbsolute(resolveIsvikHome())

  test "不硬编码任何用户名或盘符(§16)":
    # §16 禁止硬编码 C:\Users\<name> 这类路径。
    #
    # 注意:只能检查**代码**,不能检查注释。paths.nim 的文档注释里
    # 需要引用这条禁令本身、也需要列举 C:\Windows 之类的攻击示例,
    # 若连注释一起扫描,就会把「解释禁令」误判为「违反禁令」。
    # 硬编码的路径必然出现在字符串字面量里,因此去掉注释后再检查。
    let src = readFile(currentSourcePath().parentDir.parentDir.parentDir /
                       "src" / "isvik" / "config" / "paths.nim")

    var code = ""
    for line in src.splitLines:
      let hashPos = line.find('#')
      if hashPos < 0:
        code.add(line & "\n")
      else:
        code.add(line[0 ..< hashPos] & "\n")

    check not code.contains("C:\\Users")
    check not code.contains("C:/Users")
    check not code.contains("Users\\WANG")
    # 主目录必须通过 getHomeDir 获取,而不是拼字符串
    check code.contains("getHomeDir()")

suite "目录布局":

  test "六个子目录符合 §16":
    check IsvikSubdirectories.len == 6
    check "models" in IsvikSubdirectories
    check "blobs" in IsvikSubdirectories
    check "cache" in IsvikSubdirectories
    check "logs" in IsvikSubdirectories
    check "config" in IsvikSubdirectories
    check "data" in IsvikSubdirectories

  test "各字段指向 root 下对应的子目录":
    let root = makeTempDir()
    let p = newIsvikPaths(root)
    check p.root == normalizedPath(absolutePath(root))
    check p.models == p.root / "models"
    check p.blobs == p.root / "blobs"
    check p.cache == p.root / "cache"
    check p.logs == p.root / "logs"
    check p.config == p.root / "config"
    check p.data == p.root / "data"

  test "全部目录都位于 root 之内":
    let p = newIsvikPaths(makeTempDir())
    for dir in p.allDirectories():
      check isInsideDirectory(p.root, dir)

  test "newIsvikPaths 不产生副作用,不创建目录":
    let root = makeTempDir() / "not_created_yet"
    let p = newIsvikPaths(root)
    check not dirExists(p.root)
    check not p.directoriesExist()

  test "ensureDirectories 创建全部七个目录":
    let root = makeTempDir() / "fresh"
    let p = newIsvikPaths(root)

    p.ensureDirectories()

    check dirExists(p.root)
    check dirExists(p.models)
    check dirExists(p.blobs)
    check dirExists(p.cache)
    check dirExists(p.logs)
    check dirExists(p.config)
    check dirExists(p.data)
    check p.directoriesExist()

  test "ensureDirectories 幂等,可重复调用":
    let p = newIsvikPaths(makeTempDir() / "idem")
    p.ensureDirectories()
    p.ensureDirectories()
    p.ensureDirectories()
    check p.directoriesExist()

  test "深层嵌套的 root 也能创建":
    let p = newIsvikPaths(makeTempDir() / "a" / "b" / "c" / "isvik")
    p.ensureDirectories()
    check p.directoriesExist()

  test "settings.json 位于 config 子目录(§33)":
    let p = newIsvikPaths(makeTempDir())
    check p.settingsFile == p.config / "settings.json"
    check isInsideDirectory(p.root, p.settingsFile)

  test "root 参数为空时使用 resolveIsvikHome":
    let custom = makeTempDir() / "viaEnv"
    putEnv(IsvikHomeEnvVar, custom)
    defer: delEnv(IsvikHomeEnvVar)
    let p = newIsvikPaths()
    check p.root == normalizedPath(absolutePath(custom))

suite "路径安全:必须拒绝的输入(§38)":

  test "拒绝空路径":
    check checkRelativePath("").isSome

  test "拒绝包含 .. 的路径":
    check checkRelativePath("..").isSome
    check checkRelativePath("../x").isSome
    check checkRelativePath("a/../../etc/passwd").isSome
    check checkRelativePath("a\\..\\..\\windows").isSome
    check checkRelativePath("a/b/../../../..").isSome

  test "拒绝绝对路径":
    check checkRelativePath("/etc/passwd").isSome
    check checkRelativePath("C:\\Windows\\System32").isSome
    check checkRelativePath("C:/Windows").isSome

  test "拒绝 UNC 路径":
    # UNC 会访问远程主机,是真实的数据外泄途径。
    check checkRelativePath("\\\\server\\share\\x").isSome
    check checkRelativePath("//server/share/x").isSome

  test "拒绝盘符相对路径":
    # C:foo 解析到 C 盘的当前目录,不是 baseDir 下的 foo。
    check checkRelativePath("C:foo").isSome

  test "拒绝含冒号的路径(NTFS 备用数据流)":
    # file:stream 写入的内容对普通读取不可见,可用于隐藏数据。
    check checkRelativePath("model.xml:hidden").isSome
    check checkRelativePath("a/b:c").isSome

  test "拒绝 Windows 保留设备名":
    # 这些名字会写入设备而非文件。
    check checkRelativePath("CON").isSome
    check checkRelativePath("con").isSome
    check checkRelativePath("NUL").isSome
    check checkRelativePath("PRN").isSome
    check checkRelativePath("AUX").isSome
    check checkRelativePath("COM1").isSome
    check checkRelativePath("LPT9").isSome
    check checkRelativePath("models/CON").isSome

  test "保留名的判定发生在扩展名之前":
    # CON.txt 在 Windows 上同样指向控制台设备。
    check checkRelativePath("CON.txt").isSome
    check checkRelativePath("nul.bin").isSome
    check checkRelativePath("com1.xml").isSome
    check isWindowsReservedName("CON.txt")
    check isWindowsReservedName("NUL")
    check isWindowsReservedName("lpt3.anything")

  test "非保留名不被误判":
    check not isWindowsReservedName("CONSOLE")
    check not isWindowsReservedName("CONFIG")
    check not isWindowsReservedName("COM")
    check not isWindowsReservedName("COM10")
    check not isWindowsReservedName("NULL")
    check not isWindowsReservedName("model.xml")
    check not isWindowsReservedName("")

  test "拒绝以点或空格结尾的路径段":
    # Windows 静默剥离尾部点与空格:校验看到 "foo." 实际落盘 "foo",
    # 可用于绕过基于名字的白名单。
    check checkRelativePath("foo.").isSome
    check checkRelativePath("foo ").isSome
    check checkRelativePath("a/b./c").isSome

  test "拒绝首尾有空白的路径":
    check checkRelativePath(" model.xml").isSome
    check checkRelativePath("model.xml ").isSome

  test "拒绝含 NUL 字节的路径":
    # NUL 字节可截断 C 层的字符串,使校验与实际打开的路径不一致。
    check checkRelativePath("model\0.xml").isSome

  test "拒绝含 Windows 非法字符的路径":
    check checkRelativePath("a<b").isSome
    check checkRelativePath("a>b").isSome
    check checkRelativePath("a\"b").isSome
    check checkRelativePath("a|b").isSome
    check checkRelativePath("a?b").isSome
    check checkRelativePath("a*b").isSome

  test "拒绝含控制字符的路径":
    check checkRelativePath("a\tb").isSome
    check checkRelativePath("a\nb").isSome

  test "拒绝单点段与空段":
    check checkRelativePath("./x").isSome
    check checkRelativePath("a/./b").isSome
    check checkRelativePath("a//b").isSome

  test "拒绝原因是可读的非空字符串":
    # 错误信息要能指出问题所在,而不只是「非法」。
    let reason = checkRelativePath("../escape")
    check reason.isSome
    check reason.get.len > 0
    check reason.get.contains("..")

suite "路径安全:应当接受的输入":

  test "接受普通文件名":
    check checkRelativePath("model.xml").isNone
    check checkRelativePath("qwen-0.5b.bin").isNone

  test "接受多层子目录":
    check checkRelativePath("models/qwen/model.xml").isNone
    check checkRelativePath("a/b/c/d/e.bin").isNone

  test "接受反斜杠分隔符":
    check checkRelativePath("models\\qwen\\model.xml").isNone

  test "接受结尾的分隔符":
    check checkRelativePath("models/qwen/").isNone

  test "接受名字中包含点的文件":
    check checkRelativePath("model.v2.xml").isNone
    check checkRelativePath(".gitkeep").isNone

  test "接受名字中包含 .. 子串但不是独立段的路径":
    # "a..b" 不是目录穿越,不该被误拒。
    check checkRelativePath("a..b").isNone
    check checkRelativePath("model..xml").isNone

  test "接受含中文的文件名":
    check checkRelativePath("模型/通义千问.xml").isNone

suite "safeJoin":

  test "安全路径被拼接到 baseDir 下":
    let base = makeTempDir()
    let joined = safeJoin(base, "models/qwen/model.xml")
    check isInsideDirectory(base, joined)
    check joined.endsWith("model.xml")
    check isAbsolute(joined)

  test "不安全路径抛 IsvikError(INVALID_PARAMETER)":
    let base = makeTempDir()
    var code: IsvikErrorCode
    var caught = false
    try:
      discard safeJoin(base, "../../etc/passwd")
    except IsvikError as e:
      caught = true
      code = e.code
    check caught
    check code == ecInvalidParameter

  test "错误的 detail 含原始输入与原因,但 API 响应不泄漏":
    let base = makeTempDir()
    try:
      discard safeJoin(base, "../secret")
    except IsvikError as e:
      check e.detail.contains("../secret")
      check e.detail.contains("reason=")
      # detail 不得出现在 API 响应中
      check not e.toJson().contains("../secret")

  test "所有被拒输入经 safeJoin 都抛异常":
    let base = makeTempDir()
    let bad = [
      "..", "../x", "/abs", "C:\\Windows", "\\\\server\\share",
      "C:foo", "a:b", "CON", "NUL.txt", "foo.", "foo ", "a<b", "./x", "a//b", ""
    ]
    for item in bad:
      var raised = false
      try:
        discard safeJoin(base, item)
      except IsvikError:
        raised = true
      check raised

  test "trySafeJoin 对不安全路径返回 none 而非抛异常":
    let base = makeTempDir()
    check trySafeJoin(base, "../escape").isNone
    check trySafeJoin(base, "CON").isNone
    check trySafeJoin(base, "ok/file.xml").isSome

  test "trySafeJoin 与 safeJoin 结果一致":
    let base = makeTempDir()
    let viaTry = trySafeJoin(base, "models/a.xml")
    check viaTry.isSome
    check viaTry.get == safeJoin(base, "models/a.xml")

suite "isInsideDirectory":

  test "目录自身视为在其内部":
    let base = makeTempDir()
    check isInsideDirectory(base, base)

  test "子路径在内部":
    let base = makeTempDir()
    check isInsideDirectory(base, base / "a")
    check isInsideDirectory(base, base / "a" / "b" / "c.txt")

  test "同前缀的兄弟目录不算在内部":
    # 关键边界:C:\isvikEVIL 不在 C:\isvik 之内。
    # 若用朴素的 startsWith 判断会误判为在内部。
    let parent = makeTempDir()
    let base = parent / "isvik"
    let evil = parent / "isvikEVIL"
    check not isInsideDirectory(base, evil)
    check not isInsideDirectory(base, evil / "payload.bin")

  test "父目录不算在子目录内部":
    let base = makeTempDir()
    check not isInsideDirectory(base / "sub", base)

  test "穿越回上层的路径被判定为不在内部":
    let base = makeTempDir()
    check not isInsideDirectory(base, base / ".." / "outside")

  when defined(windows):
    test "Windows 上路径比较不区分大小写":
      let base = makeTempDir()
      check isInsideDirectory(base.toUpperAscii, base / "sub")
      check isInsideDirectory(base, (base / "SUB"))
