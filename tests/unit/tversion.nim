## Task 1 回归测试:版本号与产品标识的一致性
##
## 背景:nimble 强制 `version` 必须是字符串字面量,不接受常量引用,
## 所以版本号无法在语法层面只写一处(见 isvik.nimble 顶部说明)。
##
## 本测试承担「单一事实来源」的强制职责:
## src/isvik/version.nim 是权威来源,isvik.nimble 里的字面量必须与之相等。
## 一旦有人只改了其中一处,这里立即失败。

import std/[unittest, strutils, os]

import isvik/version

const
  ## tests/unit/tversion.nim -> tests/unit -> tests -> 仓库根
  repoRoot = currentSourcePath().parentDir.parentDir.parentDir
  nimbleFile = repoRoot / "isvik.nimble"

proc nimbleAssign(content, key: string): string =
  ## 从 nimble 文件中解析形如 `key   = "值"` 的赋值,返回引号内的字符串。
  ## 找不到时返回空字符串。文档注释行(以 ## 开头)不会被误匹配,
  ## 因为要求 strip 后的行必须以 key 开头且紧随 `=`。
  for rawLine in content.splitLines:
    let line = rawLine.strip()
    if not line.startsWith(key):
      continue
    let rest = line[key.len .. ^1].strip()
    if not rest.startsWith("="):
      continue
    let value = rest[1 .. ^1].strip()
    if value.len >= 2 and value[0] == '"':
      let closing = value.find('"', 1)
      if closing > 0:
        return value[1 ..< closing]
  return ""

suite "版本与产品标识":

  test "版本号符合 semver 三段式且各段为纯数字":
    let parts = IsvikVersion.split('.')
    check parts.len == 3
    for p in parts:
      check p.len > 0
      check p.allCharsInSet({'0'..'9'})

  test "产品名称与 CLI 名称符合 Master Prompt §1":
    # §1 规定正式名称为 Isvik,正式 CLI 为 isvik,
    # 并禁止使用历史名称 OVResonance / ovr。
    check IsvikProductName == "Isvik"
    check IsvikCliName == "isvik"
    check IsvikProductName.toLowerAscii != "ovresonance"
    check IsvikCliName != "ovr"

  test "中英文定位描述均非空":
    check IsvikDescription.len > 0
    check IsvikDescriptionZhCn.len > 0

  test "isvik.nimble 存在":
    check fileExists(nimbleFile)

suite "nimble 与 version.nim 不得分叉":

  let content = readFile(nimbleFile)

  test "nimble 的 version 字面量等于 IsvikVersion":
    let v = nimbleAssign(content, "version")
    check v.len > 0
    check v == IsvikVersion

  test "nimble 的 description 等于 IsvikDescription":
    let d = nimbleAssign(content, "description")
    check d.len > 0
    check d == IsvikDescription

  test "nimble 的 license 为 Apache-2.0":
    check nimbleAssign(content, "license") == "Apache-2.0"

  test "nimble 的 srcDir 为 src":
    check nimbleAssign(content, "srcDir") == "src"

  test "nimble 产出的可执行文件名等于 IsvikCliName":
    # namedBin["isvik/cli/main"] = "isvik"
    check content.contains("namedBin[\"isvik/cli/main\"] = \"" & IsvikCliName & "\"")

  test "nimble 顶部保留了版本号同步说明":
    # 防止有人删掉说明后,后来者不知道必须同步两处。
    check content.contains("src/isvik/version.nim")
    check content.contains("tests/unit/tversion.nim")

suite "构建配置硬性约束":

  let cfg = readFile(repoRoot / "nim.cfg")

  test "nim.cfg 将 C 编译器钉在 gcc":
    # 硬性约束:Resonance 的 perf_count_wrapper.c 使用 GCC 专属语法
    # (__attribute__((ms_abi)) 等),换用 vcc 会导致该 C 文件无法编译。
    check cfg.contains("cc = \"gcc\"")

  test "nim.cfg 引入 Isvik 与 Resonance 的源码路径":
    check cfg.contains("--path:\"src\"")
    check cfg.contains("--path:\"Resonance/src\"")

  test "nim.cfg 显式指定 ORC 内存管理":
    check cfg.contains("--mm:orc")
