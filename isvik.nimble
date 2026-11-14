## Isvik —— 面向 Intel AI PC 的本地 AI 推理运行平台
##
## 关于版本号的重要说明:
##
## nimble 强制要求 `version` 必须是字符串**字面量**,不接受常量引用
## (否则报 "assignments to 'version' must be string literals")。
## 因此版本号无法在语法层面只写一处。
##
## 采用的替代方案:
##   - src/isvik/version.nim 是版本号的**权威来源**(运行时、CLI、API 上报均用它)
##   - 本文件的字面量必须与之一致
##   - tests/unit/tversion.nim 解析本文件并断言两者相等,一旦分叉测试立即失败
##
## 修改版本号时必须同时改这两处,测试会保证你不会漏掉其中一处。

import std/[os, strutils, algorithm]

# ---------------------------------------------------------------------------
# 包元信息(必须为字面量,见上文说明)
# ---------------------------------------------------------------------------

version       = "0.1.2"
author        = "WANG"
description   = "Local AI Runtime Platform for Intel AI PCs"
license       = "Apache-2.0"
srcDir        = "src"

# CLI 可执行文件:src/isvik/cli/main.nim -> isvik.exe
# 使用 namedBin 而非 bin,是为了让 src/isvik.nim 保持为库入口,
# 不与可执行文件入口冲突。
namedBin["isvik/cli/main"] = "isvik"

# ---------------------------------------------------------------------------
# 依赖
# ---------------------------------------------------------------------------
#
# Resonance 是 Isvik 的基础库(Master Prompt §0.5.2)。
# 它以同仓库同级目录的形式存在,通过 nim.cfg 的 --path 引入,
# 因此这里不声明为 nimble 依赖,避免要求用户先把 Resonance 发布到 nimble。
# 若将来 Resonance 独立发布,可改为 requires "resonance >= 0.1.0"。

requires "nim >= 2.2.4"

# ---------------------------------------------------------------------------
# 任务
# ---------------------------------------------------------------------------

proc collectTestFiles(dir: string, acc: var seq[string]) =
  ## 递归收集 dir 下所有以 t 开头、以 .nim 结尾的测试文件。
  for f in listFiles(dir):
    let name = f.extractFilename
    if name.startsWith("t") and name.endsWith(".nim"):
      acc.add(f)
  for sub in listDirs(dir):
    collectTestFiles(sub, acc)

task test, "运行 Isvik 全部测试(tests/ 下所有 t*.nim)":
  var files: seq[string] = @[]
  if dirExists("tests"):
    collectTestFiles("tests", files)
  if files.len == 0:
    echo "错误:tests/ 下没有找到任何 t*.nim 测试文件"
    quit(1)
  sort(files)
  mkDir("build/tests")
  for f in files:
    echo ""
    echo "===> 测试 " & f
    let exe = "build/tests/" & f.extractFilename.changeFileExt("exe")
    exec "nim c -r --hints:off --path:src --nimcache:build/nimcache/tests -o:" &
      exe & " " & f
  echo ""
  echo "全部通过:" & $files.len & " 个测试文件"

task demo_events, "运行「事件 → GUI + 日志」演示程序":
  mkDir("build/demo")
  exec "nim c -r --hints:off --path:src --nimcache:build/nimcache/demo " &
    "-o:build/demo/event_logging_demo.exe examples/event_logging_demo.nim"

task clean, "清除构建产物":
  for d in ["build", "nimcache", ".nimcache"]:
    if dirExists(d):
      rmDir(d)
      echo "已删除 " & d

task tabcheck, "检查源码是否存在制表符缩进(Nim 禁止制表符缩进)":
  var bad = 0
  proc scan(dir: string) =
    for f in listFiles(dir):
      if f.endsWith(".nim") or f.endsWith(".nims"):
        if readFile(f).contains('\t'):
          echo "包含制表符:" & f
          inc bad
    for sub in listDirs(dir):
      scan(sub)
  if dirExists("src"): scan("src")
  if dirExists("tests"): scan("tests")
  if bad > 0:
    quit(1)
  echo "未发现制表符缩进"
