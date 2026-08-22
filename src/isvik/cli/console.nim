## 控制台编码适配(Windows First,Master Prompt §39)
##
## 问题:Nim 源码与 Isvik 的所有输出均为 UTF-8,但中文版 Windows 的控制台
## 默认代码页是 GBK(936)。直接输出 UTF-8 字节会显示为乱码。
##
## 解决:进程启动时把控制台输出代码页切到 UTF-8(65001)。
## 这只影响当前进程持有的控制台句柄,不修改系统或用户的持久设置。
##
## 该模块不属于 Isvik Core,只服务于 CLI / 终端表现层。

when defined(windows):
  proc setConsoleOutputCP(codePage: uint32): int32
    {.stdcall, dynlib: "kernel32", importc: "SetConsoleOutputCP".}

  proc setConsoleCP(codePage: uint32): int32
    {.stdcall, dynlib: "kernel32", importc: "SetConsoleCP".}

  proc getConsoleProcessList(processList: ptr uint32, count: uint32): uint32
    {.stdcall, dynlib: "kernel32", importc: "GetConsoleProcessList".}

  const cpUtf8 = 65001'u32

## ---
##
## ## 刻意不改 CRT 的缓冲策略
##
## 输出被重定向时 stdout 是全缓冲的,曾考虑用 `setvbuf(stdout, nil, _IONBF, 0)`
## 改成无缓冲。**没有采用**,因为不需要:
##
## 1. 「退出时缓冲没刷干净」由 `cli/main.flushStreams` 在返回前显式
##    `flushFile` 解决;
## 2. 「接进管道时看不到逐 token 流」由 `cli/cmd_chat` 在**每个 token 之后**
##    显式 flush 解决。
##
## 两条各自针对一个具体问题,作用范围明确;而改全局缓冲模式会影响进程里
## 所有写 stdout 的代码(包括 OpenVINO 及其依赖),影响面远大于收益。

proc enableUtf8Console*(): bool {.discardable.} =
  ## 将当前进程的控制台切换到 UTF-8。
  ##
  ## 返回是否成功。失败不是致命错误(例如输出被重定向到管道或文件时,
  ## SetConsoleOutputCP 会失败),调用方可以忽略返回值。
  when defined(windows):
    let outOk = setConsoleOutputCP(cpUtf8) != 0
    let inOk = setConsoleCP(cpUtf8) != 0
    result = outOk and inOk
  else:
    # 类 Unix 平台的终端默认即为 UTF-8,无需处理。
    result = true

# ---------------------------------------------------------------------------
# 「是不是被双击运行的」
# ---------------------------------------------------------------------------
#
# 在资源管理器里双击一个控制台程序,Windows 会为它**新建**一个控制台窗口;
# 程序打印完就退出,窗口随之关闭 —— 用户只看到一闪,什么也读不到。
#
# 判据用 `GetConsoleProcessList`:它返回附着在当前控制台上的进程数。
#
# ```text
# 双击运行            控制台是为本进程新建的,只有它自己  → 返回 1
# 在 PowerShell/cmd 里跑  宿主 shell 也附着在同一控制台    → 返回 ≥ 2
# 输出被重定向 / 无控制台   调用失败                        → 返回 0
# ```
#
# 拒绝用「有没有命令行参数」判断:无参数启动现在会进入常驻工作台，
# 终端、双击与管道 EOF 都是合法路径。该判据只用于工作台启动前出错时
# 保留双击窗口；正常 `-exit` 由工作台自己收尾，不会再次暂停。

proc launchedByDoubleClick*(): bool =
  ## 本进程是否由资源管理器双击启动(即拥有一个专属的新控制台窗口)。
  ##
  ## 非 Windows 平台恒为 false:类 Unix 桌面不会为可执行文件新建终端,
  ## 也就没有「窗口一闪而过」这个问题。
  when defined(windows):
    # 只需要知道个数,但 API 要求给出缓冲;给两个槽足以区分 1 与「多于 1」。
    var slots: array[2, uint32]
    let count = getConsoleProcessList(addr slots[0], uint32(slots.len))
    result = count == 1
  else:
    result = false
