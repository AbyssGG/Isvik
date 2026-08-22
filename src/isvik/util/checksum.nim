## SHA-256 —— 用于模型与缓存的完整性校验
##
## ---
##
## ## 为什么自己实现,而不是用现成的
##
## 三个候选都不合适:
##
## | 候选 | 问题 |
## | --- | --- |
## | `std/sha1` | Nim 2.2 起**已废弃**,编译告警要求改用外部包;且 SHA-1 已不安全 |
## | `checksums` 包 | 要引入一个 nimble 依赖,而 §41 要求添加依赖前先判断是否必需 |
## | `std/md5` | MD5 碰撞已可实用构造,不该在新代码里用 |
##
## SHA-256 的规范(FIPS 180-4)是确定的,实现约一百行,且**有官方已知答案可以
## 逐字节验证**。为一个可完全验证的一百行函数引入依赖不划算,而用废弃 API
## 会在每次构建时刷告警。
##
## 关键点在于「可验证」:`tests/unit/tchecksum.nim` 用 FIPS 180-4 与
## NIST 的标准测试向量断言输出。这不是「看起来对」,是「与规范逐位一致」。
##
## ---
##
## ## 它能保证什么、不能保证什么
##
## ```text
## 能:检测损坏      下载截断、磁盘坏块、复制中断、位翻转
## 不能:防篡改      攻击者若能改文件,也能改清单里的哈希
## ```
##
## 防篡改需要签名(哈希 + 可信公钥),换算法解决不了信任问题。因此模型清单
## 里的校验和只用于回答「文件内容和登记时一样吗」。

import std/strutils

type
  Sha256Digest* = array[32, byte]
    ## 32 字节摘要。

  Sha256Ctx* = object
    ## 流式计算上下文。
    ##
    ## 提供流式接口是必需的:本机的 Gemma 模型单文件 2.19 GB,
    ## 一次读进内存再算会白占几 GB 常驻内存。
    state: array[8, uint32]
    buffer: array[64, byte]
    bufferLen: int
    totalBytes: uint64

const
  ## FIPS 180-4 §4.2.2:前 64 个素数立方根小数部分的前 32 位。
  RoundConstants: array[64, uint32] = [
    0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
    0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
    0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
    0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
    0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
    0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
    0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
    0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
    0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
    0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
    0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
    0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
    0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
    0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
    0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
    0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32
  ]

  ## FIPS 180-4 §5.3.3:前 8 个素数平方根小数部分的前 32 位。
  InitialState: array[8, uint32] = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32
  ]

  FileReadChunk = 1 shl 20
    ## 每次从文件读取的字节数(1 MiB)。
    ##
    ## 取这个量级是为了在「系统调用次数」与「常驻内存」之间取平衡:
    ## 太小会让 4 GB 文件产生几百万次读调用,太大则失去流式的意义。

proc rotr(x: uint32, n: int): uint32 {.inline.} =
  ## 32 位循环右移。Nim 的 `shr` 对 uint32 是逻辑移位,不补符号位。
  (x shr n) or (x shl (32 - n))

proc processBlock(ctx: var Sha256Ctx, block64: array[64, byte]) =
  ## 处理一个 64 字节块(FIPS 180-4 §6.2.2)。
  var w: array[64, uint32]

  # 前 16 个字按**大端**读入。字节序写错会让结果完全不同,
  # 而且只有对着测试向量才看得出来。
  for i in 0 ..< 16:
    w[i] = (uint32(block64[i * 4]) shl 24) or
           (uint32(block64[i * 4 + 1]) shl 16) or
           (uint32(block64[i * 4 + 2]) shl 8) or
            uint32(block64[i * 4 + 3])

  for i in 16 ..< 64:
    let s0 = rotr(w[i - 15], 7) xor rotr(w[i - 15], 18) xor (w[i - 15] shr 3)
    let s1 = rotr(w[i - 2], 17) xor rotr(w[i - 2], 19) xor (w[i - 2] shr 10)
    w[i] = w[i - 16] + s0 + w[i - 7] + s1

  var a = ctx.state[0]
  var b = ctx.state[1]
  var c = ctx.state[2]
  var d = ctx.state[3]
  var e = ctx.state[4]
  var f = ctx.state[5]
  var g = ctx.state[6]
  var h = ctx.state[7]

  for i in 0 ..< 64:
    let s1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
    let ch = (e and f) xor ((not e) and g)
    let temp1 = h + s1 + ch + RoundConstants[i] + w[i]
    let s0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
    let maj = (a and b) xor (a and c) xor (b and c)
    let temp2 = s0 + maj

    h = g
    g = f
    f = e
    e = d + temp1
    d = c
    c = b
    b = a
    a = temp1 + temp2

  ctx.state[0] = ctx.state[0] + a
  ctx.state[1] = ctx.state[1] + b
  ctx.state[2] = ctx.state[2] + c
  ctx.state[3] = ctx.state[3] + d
  ctx.state[4] = ctx.state[4] + e
  ctx.state[5] = ctx.state[5] + f
  ctx.state[6] = ctx.state[6] + g
  ctx.state[7] = ctx.state[7] + h

proc initSha256*(): Sha256Ctx =
  ## 初始化上下文。
  result.state = InitialState
  result.bufferLen = 0
  result.totalBytes = 0

proc update*(ctx: var Sha256Ctx, data: openArray[byte]) =
  ## 追加数据。可反复调用,与一次性传入等价。
  ctx.totalBytes += uint64(data.len)
  var offset = 0

  # 先把缓冲区凑满一整块。
  if ctx.bufferLen > 0:
    while ctx.bufferLen < 64 and offset < data.len:
      ctx.buffer[ctx.bufferLen] = data[offset]
      inc ctx.bufferLen
      inc offset
    if ctx.bufferLen == 64:
      ctx.processBlock(ctx.buffer)
      ctx.bufferLen = 0

  # 整块直接处理,不经缓冲区。
  while data.len - offset >= 64:
    var full: array[64, byte]
    for i in 0 ..< 64:
      full[i] = data[offset + i]
    ctx.processBlock(full)
    inc offset, 64

  # 余下的留在缓冲区等下一次 update 或 finalize。
  while offset < data.len:
    ctx.buffer[ctx.bufferLen] = data[offset]
    inc ctx.bufferLen
    inc offset

proc update*(ctx: var Sha256Ctx, data: string) =
  ## 按字节追加字符串内容(不含结尾 NUL)。
  if data.len == 0:
    return
  ctx.update(cast[ptr UncheckedArray[byte]](data[0].addr).toOpenArray(0, data.len - 1))

proc finalize*(ctx: var Sha256Ctx): Sha256Digest =
  ## 收尾并返回摘要。调用后不应再 `update`。
  ##
  ## 填充规则(FIPS 180-4 §5.1.1):追加 0x80,补零到长度 ≡ 56 (mod 64),
  ## 再追加 8 字节大端的**比特**总数。用字节数会算出完全不同的结果。
  let bitLength = ctx.totalBytes * 8

  var padding: array[72, byte]
  var padLen = 0
  padding[padLen] = 0x80'u8
  inc padLen

  # 补零直到 (totalBytes + padLen) % 64 == 56
  while (int(ctx.totalBytes) + padLen) mod 64 != 56:
    padding[padLen] = 0'u8
    inc padLen

  for i in countdown(7, 0):
    padding[padLen] = byte((bitLength shr (i * 8)) and 0xFF'u64)
    inc padLen

  # update 会把 totalBytes 加上填充长度,但填充之后不再使用它,无影响。
  ctx.update(padding.toOpenArray(0, padLen - 1))

  for i in 0 ..< 8:
    result[i * 4] = byte((ctx.state[i] shr 24) and 0xFF'u32)
    result[i * 4 + 1] = byte((ctx.state[i] shr 16) and 0xFF'u32)
    result[i * 4 + 2] = byte((ctx.state[i] shr 8) and 0xFF'u32)
    result[i * 4 + 3] = byte(ctx.state[i] and 0xFF'u32)

proc toHex*(digest: Sha256Digest): string =
  ## 摘要的十六进制小写表示(64 个字符)。
  result = newStringOfCap(64)
  for b in digest:
    result.add(toHex(int(b), 2).toLowerAscii)

proc sha256*(data: openArray[byte]): Sha256Digest =
  ## 一次性计算摘要。
  var ctx = initSha256()
  ctx.update(data)
  result = ctx.finalize()

proc sha256Hex*(data: string): string =
  ## 字符串内容的摘要,十六进制小写。
  var ctx = initSha256()
  ctx.update(data)
  result = ctx.finalize().toHex

proc sha256FileHex*(path: string): string =
  ## 文件内容的摘要,十六进制小写。
  ##
  ## 分块流式读取,因此对多 GB 的模型权重也只占固定内存。
  ## 文件打不开时抛 IOError,由调用方决定如何翻译成 IsvikError ——
  ## 本模块是通用工具,不该绑定某个业务错误码。
  var f = open(path, fmRead)
  defer: f.close()

  var ctx = initSha256()
  var chunk = newSeq[byte](FileReadChunk)
  while true:
    let read = f.readBuffer(addr chunk[0], FileReadChunk)
    if read <= 0:
      break
    ctx.update(chunk.toOpenArray(0, read - 1))
  result = ctx.finalize().toHex
