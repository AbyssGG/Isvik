## 架构适应性测试(Architecture Fitness Test)
##
## Master Prompt §46.5 给出了一张验收清单,其中若干条是「依赖方向」类约束:
##
## ```text
## [ ] OpenVINO 是 Backend,而不是 Core 的直接业务层
## [ ] 无 Python Runtime 依赖
## [ ] 无 Python inference server
## [ ] 无 Python hidden runtime
## ```
##
## 这类约束靠人工复查会随代码量增长而失效。本文件把它们变成**机械检查**:
## 违反约束时构建直接失败,而不是等到某次 review 才被发现。
##
## ---
##
## ## 为什么必须解析 import 语句,而不能直接搜文本
##
## `src/isvik/core/backend.nim` 的文档注释里明确写着
## 「不得 import resonance / openvino」这句说明本身。
## 如果扫描器在全文里搜 "resonance",真实代码会被误报为违规 ——
## 「解释禁令」被当成「违反禁令」。
##
## 因此扫描器只检查真正的 `import` / `from` / `include` 语句,
## 并且在检查前去掉注释。本文件包含专门的测试来验证这一点。
##
## ---
##
## ## 负例验证
##
## 一个永远通过的检查等于没有检查。本文件不仅验证真实源码合规,
## 还构造**故意违规**的源码与目录,断言扫描器确实能把它们抓出来。
## 若扫描器失效,负例测试会失败。

import std/[unittest, os, strutils, algorithm, sequtils]

const
  repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  srcRoot = repoRoot / "src"

type
  ImportStatement = object
    lineNo: int
    text: string

  Violation = object
    file: string
    lineNo: int
    statement: string
    token: string

  ArchitectureRule = object
    name: string
    scopeDirs: seq[string]      ## 相对 src/ 的目录;不存在的目录会被跳过
    forbiddenTokens: seq[string]
    reason: string

# ---------------------------------------------------------------------------
# import 语句解析
# ---------------------------------------------------------------------------

proc stripComment(line: string): string =
  ## 去掉行内注释。
  ##
  ## 这是启发式的:如果字符串字面量中含 '#' 会被误截断。
  ## 对 import 语句而言不成问题 —— Nim 的 import 语句里不会出现字符串。
  let hashPos = line.find('#')
  if hashPos < 0:
    return line
  result = line[0 ..< hashPos]

proc importStatements*(source: string): seq[ImportStatement] =
  ## 提取源码中所有 import / from / include 语句(已去注释)。
  ##
  ## 处理 Nim 的多行 import 形式:
  ##
  ## ```nim
  ## import
  ##   std/os,
  ##   isvik/core/errors
  ## ```
  ##
  ## 续行判定采取保守策略(宁可多扫也不漏):以逗号结尾、或 `import`
  ## 单独成行时,继续把后续的缩进行纳入检查,直到遇到空行或非缩进行。
  result = @[]
  var inContinuation = false
  var lineNo = 0

  for rawLine in source.splitLines:
    inc lineNo
    let line = stripComment(rawLine)
    let stripped = line.strip()

    if stripped.len == 0:
      inContinuation = false
      continue

    let isIndented = rawLine.len > 0 and rawLine[0] in {' ', '\t'}

    if inContinuation:
      if not isIndented:
        # 缩进结束,多行 import 结束。该行本身仍需按新语句判定。
        inContinuation = false
      else:
        result.add(ImportStatement(lineNo: lineNo, text: stripped))
        inContinuation = stripped.endsWith(",")
        continue

    # export 也必须纳入:重导出会把符号传递给下游,
    # `export resonance` 等价于把 Resonance 的类型泄漏到产品层。
    if stripped == "import" or stripped == "export" or
       stripped.startsWith("import ") or
       stripped.startsWith("export ") or
       stripped.startsWith("from ") or
       stripped.startsWith("include "):
      result.add(ImportStatement(lineNo: lineNo, text: stripped))
      inContinuation = stripped.endsWith(",") or
                       stripped == "import" or stripped == "export"

proc findViolations*(filePath, source: string,
                     forbiddenTokens: openArray[string]): seq[Violation] =
  ## 在单个文件的 import 语句中查找禁用 token。
  result = @[]
  for statement in importStatements(source):
    let lowered = statement.text.toLowerAscii
    for token in forbiddenTokens:
      if lowered.contains(token.toLowerAscii):
        result.add(Violation(
          file: filePath,
          lineNo: statement.lineNo,
          statement: statement.text,
          token: token
        ))

proc nimFilesIn(dir: string): seq[string] =
  ## 递归收集目录下所有 .nim 文件。目录不存在时返回空列表。
  result = @[]
  if not dirExists(dir):
    return
  for path in walkDirRec(dir):
    if path.endsWith(".nim"):
      result.add(path)
  sort(result)

proc checkRule(rule: ArchitectureRule): seq[Violation] =
  ## 对一条规则涉及的全部目录执行检查。
  result = @[]
  for scope in rule.scopeDirs:
    let dir = srcRoot / scope
    for file in nimFilesIn(dir):
      result.add(findViolations(file, readFile(file), rule.forbiddenTokens))

proc describe(violations: seq[Violation]): string =
  ## 把违规列表格式化为可读报告,便于失败时直接定位。
  result = ""
  for v in violations:
    result.add("\n  " & v.file.relativePath(repoRoot) &
               ":" & $v.lineNo &
               "  禁用 token '" & v.token & "'  语句: " & v.statement)

# ---------------------------------------------------------------------------
# 规则定义
# ---------------------------------------------------------------------------

const
  ## 产品层与 Core 一律不得触及 OpenVINO 相关模块(§5、§9、§20.5.2、§23、§24)。
  ##
  ## 注意 backends/ 不在检查范围内:`backends/openvino/` 正是唯一被允许
  ## import resonance 的位置,这条边界由「谁在范围内」表达,
  ## 而不是靠给某个文件开例外。
  ProductLayerScopes = @[
    "isvik/core",
    "isvik/cli",
    "isvik/server",
    "isvik/gui",
    "isvik/protocol",
    "isvik/services",
    "isvik/config",
    "isvik/logging",
    "isvik/models",
    "isvik/i18n",
    "isvik/util",
    "isvik/cache",
    "isvik/inference",
    "isvik/benchmark",
    "gui"
  ]

  OpenVinoTokens = @["resonance", "c_api", "openvino"]

  architectureRules = [
    ArchitectureRule(
      name: "产品层与 Core 不得 import OpenVINO / Resonance",
      scopeDirs: ProductLayerScopes,
      forbiddenTokens: OpenVinoTokens,
      reason: "§5:上层不直接调用 OpenVINO C API;" &
              "OpenVINO-specific types 不得泄漏到产品层"
    ),
    ArchitectureRule(
      name: "Core 不得依赖任何具体 Backend 实现",
      scopeDirs: @["isvik/core"],
      forbiddenTokens: @["isvik/backends"],
      reason: "§5 / §50:Core 通过 Backend 抽象工作,不感知具体实现"
    ),
    ArchitectureRule(
      name: "Core 不得依赖上层(CLI / Server / GUI / Protocol / Services)",
      scopeDirs: @["isvik/core"],
      forbiddenTokens: @["isvik/cli", "isvik/server", "isvik/gui",
                         "isvik/protocol", "isvik/services"],
      reason: "§5:Isvik Core 不依赖 GUI、不依赖 CLI、不依赖 HTTP Server。" &
              "Core 定义 ProtocolAdapter 接口,但不得依赖任何具体 Adapter 实现"
    ),
    ArchitectureRule(
      name: "Core 不得依赖 logging",
      scopeDirs: @["isvik/core"],
      forbiddenTokens: @["isvik/logging"],
      reason: "依赖方向为 logging → core:Core 只发布事件,由 logging 订阅落盘"
    ),
    ArchitectureRule(
      name: "src 下不得启动外部进程",
      scopeDirs: @["isvik", "gui"],
      forbiddenTokens: @["osproc"],
      reason: "§0.5.4:禁止把 Python / 外部进程作为推理链的一部分。" &
              "构建脚本(nimble task)不受此限,它不在 src 内"
    )
  ]

# ---------------------------------------------------------------------------
# 真实源码必须合规
# ---------------------------------------------------------------------------

suite "架构约束:真实源码":

  test "src 目录存在且包含 Nim 源码":
    # 保证检查真的扫到了东西 —— 空扫描会让所有断言假通过。
    check dirExists(srcRoot)
    let files = nimFilesIn(srcRoot)
    check files.len >= 10

  test "扫描确实覆盖了 Core 的全部模块":
    # 同样防止「扫了 0 个文件所以没有违规」这种假通过。
    let coreFiles = nimFilesIn(srcRoot / "isvik" / "core")
    check coreFiles.len >= 5
    let names = coreFiles.mapIt(it.extractFilename)
    check "errors.nim" in names
    check "events.nim" in names
    check "backend.nim" in names
    check "runtime.nim" in names
    check "tensor.nim" in names

  for rule in architectureRules:
    test rule.name:
      let violations = checkRule(rule)
      if violations.len > 0:
        checkpoint("违反约束:" & rule.name)
        checkpoint("理由:" & rule.reason)
        checkpoint(describe(violations))
      check violations.len == 0

suite "架构约束:OpenVINO Backend 是唯一例外":

  test "backends/openvino 未被纳入产品层检查范围":
    # 这条边界必须是显式的:唯一允许 import resonance 的位置
    # 是通过「不在检查范围内」表达的,而不是给某个文件开例外。
    for scope in ProductLayerScopes:
      check not scope.startsWith("isvik/backends")

  test "若 backends/openvino 已存在,它确实 import 了 Resonance":
    # Task 9 之后这条会真正生效:Isvik 不重复封装 OpenVINO(§0.5.2),
    # OpenVINO Backend 必须建立在 Resonance 之上,而不是自己另写一套 FFI。
    let dir = srcRoot / "isvik" / "backends" / "openvino"
    if not dirExists(dir):
      skip()
    else:
      var importsResonance = false
      for file in nimFilesIn(dir):
        let violations = findViolations(file, readFile(file), ["resonance"])
        if violations.len > 0:
          importsResonance = true
          break
      check importsResonance

  test "core 之外没有其它位置偷偷 import resonance":
    # 全量扫描 src,列出所有 import resonance 的文件,
    # 断言它们全部位于 backends/openvino 之下。
    var offenders: seq[string] = @[]
    for file in nimFilesIn(srcRoot):
      if findViolations(file, readFile(file), ["resonance"]).len > 0:
        let rel = file.relativePath(srcRoot).replace('\\', '/')
        if not rel.startsWith("isvik/backends/openvino/"):
          offenders.add(rel)
    if offenders.len > 0:
      checkpoint("以下文件不应 import resonance:\n  " & offenders.join("\n  "))
    check offenders.len == 0

# ---------------------------------------------------------------------------
# 禁止 Python 运行时依赖(§0.5.4)
# ---------------------------------------------------------------------------

suite "禁止 Python 运行时依赖(§0.5.4)":

  test "仓库中不存在 Python 源文件":
    var pythonFiles: seq[string] = @[]
    for dir in [repoRoot / "src", repoRoot / "tests", repoRoot / "examples",
                repoRoot / "scripts", repoRoot / "Resonance" / "src"]:
      if not dirExists(dir):
        continue
      for path in walkDirRec(dir):
        let lowered = path.toLowerAscii
        if lowered.endsWith(".py") or lowered.endsWith(".pyw") or
           lowered.endsWith(".ipynb"):
          pythonFiles.add(path.relativePath(repoRoot))
    if pythonFiles.len > 0:
      checkpoint("发现 Python 文件:\n  " & pythonFiles.join("\n  "))
    check pythonFiles.len == 0

  test "不存在 requirements.txt / pyproject.toml 等 Python 依赖声明":
    for name in ["requirements.txt", "pyproject.toml", "setup.py",
                 "Pipfile", "environment.yml", "poetry.lock"]:
      check not fileExists(repoRoot / name)

  test "src 中不出现 python 可执行文件名":
    # 即便不 import osproc,也可能通过其它方式拼出 python 命令。
    # 这里检查源码中是否出现形如 "python" / "python3" 的字符串字面量。
    var offenders: seq[string] = @[]
    for file in nimFilesIn(srcRoot):
      for rawLine in readFile(file).splitLines:
        let line = stripComment(rawLine).toLowerAscii
        if line.contains("\"python") or line.contains("'python"):
          offenders.add(file.relativePath(repoRoot) & ": " & rawLine.strip())
    if offenders.len > 0:
      checkpoint("发现 python 命令引用:\n  " & offenders.join("\n  "))
    check offenders.len == 0

# ---------------------------------------------------------------------------
# 负例验证:扫描器本身必须有效
# ---------------------------------------------------------------------------

suite "负例验证:扫描器能抓出违规":

  test "直接 import resonance 被检出":
    # 注意行号:Nim 的三引号字符串会吞掉紧跟 `"""` 的那个换行,
    # 所以 "import std/os" 是第 1 行,"import resonance" 是第 2 行。
    let source = """
import std/os
import resonance
"""
    let violations = findViolations("fake/core/x.nim", source, OpenVinoTokens)
    check violations.len == 1
    check violations[0].lineNo == 2
    check violations[0].token == "resonance"

  test "import 子模块被检出":
    let source = "import resonance/core\n"
    check findViolations("fake.nim", source, OpenVinoTokens).len == 1

  test "from ... import 被检出":
    let source = "from resonance/core import newCore\n"
    check findViolations("fake.nim", source, OpenVinoTokens).len == 1

  test "include 被检出":
    let source = "include resonance/c_api\n"
    # 同时命中 resonance 与 c_api 两个 token
    check findViolations("fake.nim", source, OpenVinoTokens).len == 2

  test "同一行多个模块中的违规被检出":
    let source = "import std/os, resonance, std/json\n"
    check findViolations("fake.nim", source, OpenVinoTokens).len == 1

  test "方括号形式的 import 被检出":
    let source = "import resonance/[core, tensor]\n"
    check findViolations("fake.nim", source, OpenVinoTokens).len == 1

  test "多行 import 中的违规被检出":
    let source = """
import
  std/os,
  resonance,
  std/json
"""
    let violations = findViolations("fake.nim", source, OpenVinoTokens)
    check violations.len == 1
    # "import" 第 1 行、"std/os," 第 2 行、"resonance," 第 3 行
    check violations[0].lineNo == 3

  test "import ... as 被检出":
    let source = "import resonance as ov\n"
    check findViolations("fake.nim", source, OpenVinoTokens).len == 1

  test "export resonance 被检出":
    # 重导出会把 Resonance 的类型传递给下游,等同于泄漏到产品层,
    # 因此 export 必须与 import 一样受检。
    let source = "export resonance\n"
    check findViolations("fake.nim", source, OpenVinoTokens).len == 1

  test "export 无关模块不算违规":
    check findViolations("fake.nim", "export version\n", OpenVinoTokens).len == 0

  test "大小写不同的写法被检出":
    let source = "import Resonance\n"
    check findViolations("fake.nim", source, OpenVinoTokens).len == 1

  test "Core 依赖具体 Backend 被检出":
    let source = "import isvik/backends/mock/mock_backend\n"
    check findViolations("fake.nim", source, ["isvik/backends"]).len == 1

  test "Core 依赖 CLI 被检出":
    let source = "import isvik/cli/console\n"
    check findViolations("fake.nim", source, ["isvik/cli"]).len == 1

  test "Core 依赖 logging 被检出":
    let source = "import isvik/logging/logger\n"
    check findViolations("fake.nim", source, ["isvik/logging"]).len == 1

  test "osproc 被检出":
    let source = "import std/osproc\n"
    check findViolations("fake.nim", source, ["osproc"]).len == 1

suite "负例验证:目录级扫描":

  setup:
    let tmpDir = getTempDir() / "isvik_arch_test"
    if dirExists(tmpDir):
      removeDir(tmpDir)
    createDir(tmpDir / "core")

  teardown:
    if dirExists(tmpDir):
      removeDir(tmpDir)

  test "临时目录中的违规文件被扫描出来":
    writeFile(tmpDir / "core" / "clean.nim", "import std/os\n")
    writeFile(tmpDir / "core" / "dirty.nim",
              "import std/json\nimport resonance/core\n")

    var found: seq[Violation] = @[]
    for file in nimFilesIn(tmpDir):
      found.add(findViolations(file, readFile(file), OpenVinoTokens))

    check found.len == 1
    check found[0].file.endsWith("dirty.nim")
    check found[0].lineNo == 2

  test "全部合规时扫描结果为空":
    writeFile(tmpDir / "core" / "a.nim", "import std/os\nimport std/json\n")
    writeFile(tmpDir / "core" / "b.nim", "import isvik/core/errors\n")

    var found: seq[Violation] = @[]
    for file in nimFilesIn(tmpDir):
      found.add(findViolations(file, readFile(file), OpenVinoTokens))
    check found.len == 0

  test "不存在的目录被跳过而不报错":
    check nimFilesIn(tmpDir / "does_not_exist").len == 0

# ---------------------------------------------------------------------------
# 反向验证:不能误报
# ---------------------------------------------------------------------------

suite "扫描器不得误报":

  test "注释中提到 resonance 不算违规":
    # 这是真实存在的情况:core/backend.nim 的文档注释里写着
    # 「不得 import resonance」这句说明本身。
    let source = """
## 本模块不得 import resonance / openvino。
# import resonance  <- 这是被注释掉的示例
import std/os
"""
    check findViolations("fake.nim", source, OpenVinoTokens).len == 0

  test "行内注释中提到 resonance 不算违规":
    let source = "import std/os  # 不要在这里 import resonance\n"
    check findViolations("fake.nim", source, OpenVinoTokens).len == 0

  test "标识符中含 openvino 不算违规":
    # §28 要求 GUI 显示 OpenVINO Version,Core 里出现
    # openvinoVersion 这类字段名是正常的。
    let source = """
import std/os

type
  RuntimeInfo = object
    openvinoVersion: string

proc describeOpenVino(): string = "n/a"
"""
    check findViolations("fake.nim", source, OpenVinoTokens).len == 0

  test "字符串字面量中含 openvino 不算违规":
    let source = """
import std/os

const dllName = "openvino_c.dll"
"""
    check findViolations("fake.nim", source, OpenVinoTokens).len == 0

  test "core/backend.nim 的真实内容不被误报":
    # 直接用真实文件做回归:它的注释里确实写了禁令原文。
    let file = srcRoot / "isvik" / "core" / "backend.nim"
    check fileExists(file)
    let content = readFile(file)
    # 确认该文件的注释里真的提到了这些词(否则这个测试没有意义)
    check content.contains("resonance")
    # 但 import 语句里没有
    check findViolations(file, content, OpenVinoTokens).len == 0

  test "core/runtime.nim 的真实内容不被误报":
    let file = srcRoot / "isvik" / "core" / "runtime.nim"
    check fileExists(file)
    check findViolations(file, readFile(file), OpenVinoTokens).len == 0

suite "import 语句解析":

  test "识别单行 import":
    let stmts = importStatements("import std/os\n")
    check stmts.len == 1
    check stmts[0].text == "import std/os"

  test "识别 from 与 include":
    check importStatements("from std/os import getEnv\n").len == 1
    check importStatements("include foo\n").len == 1

  test "识别 export":
    # export 同样会把符号传递出去,构成依赖关系。
    check importStatements("export version\n").len == 1

  test "忽略普通代码行":
    let source = """
proc foo() =
  let x = 1
  echo x
"""
    check importStatements(source).len == 0

  test "忽略纯注释行":
    check importStatements("## import resonance\n").len == 0
    check importStatements("# import resonance\n").len == 0

  test "多行 import 的每一行都被记录":
    let source = """
import
  std/os,
  std/json
"""
    # "import" 本身 + 两个模块行
    check importStatements(source).len == 3

  test "多行 import 在遇到非缩进行后结束":
    let source = """
import
  std/os

proc resonance() = discard
"""
    let stmts = importStatements(source)
    # 不应把 proc 行当成 import 的续行
    for s in stmts:
      check not s.text.startsWith("proc")
