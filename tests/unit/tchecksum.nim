## SHA-256 测试
##
## 核心是**用规范的已知答案验证**,而不是自证。测试向量来自
## FIPS 180-4 附录 B 与 NIST 的 SHA-256 示例,以及若干边界长度。
##
## 自己实现哈希函数唯一可接受的前提就是这个:输出能与规范逐位比对。
## 若没有这组用例,这份实现只是「看起来像 SHA-256」。

import std/[unittest, strutils, os]

import isvik/util/checksum

const
  ## FIPS 180-4 附录 B.1 / B.3 与 NIST 示例。
  EmptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  AbcHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  Rfc448Hash = "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
  MillionAHash =
    "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

suite "SHA-256 与规范的已知答案一致":

  test "空输入":
    check sha256Hex("") == EmptyHash

  test "abc(FIPS 180-4 附录 B.1)":
    check sha256Hex("abc") == AbcHash

  test "56 字节输入,恰好触发额外填充块(附录 B.2)":
    # 长度 56 时 0x80 之后已无空间放 8 字节长度,必须多一个块。
    # 这是最容易写错的边界。
    let msg = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    check msg.len == 56
    check sha256Hex(msg) == Rfc448Hash

  test "一百万个 a(附录 B.3)":
    # 同时验证流式累积在多块上的正确性。
    var ctx = initSha256()
    let chunk = "a".repeat(1000)
    for _ in 0 ..< 1000:
      ctx.update(chunk)
    check ctx.finalize().toHex == MillionAHash

suite "填充边界":

  test "长度 55、56、57、63、64、65 都与一次性计算一致":
    # 55 是「刚好放得下」,56 是「必须加块」,64 是「整块」。
    for n in [0, 1, 55, 56, 57, 63, 64, 65, 119, 120, 128]:
      let msg = "x".repeat(n)
      var ctx = initSha256()
      ctx.update(msg)
      check ctx.finalize().toHex == sha256Hex(msg)

  test "分多次 update 与一次性传入结果相同":
    let full = "The quick brown fox jumps over the lazy dog"
    let oneShot = sha256Hex(full)

    # 逐字节喂
    var byByte = initSha256()
    for ch in full:
      byByte.update($ch)
    check byByte.finalize().toHex == oneShot

    # 不规则切分
    var uneven = initSha256()
    uneven.update(full[0 ..< 3])
    uneven.update(full[3 ..< 4])
    uneven.update(full[4 ..< 30])
    uneven.update(full[30 .. ^1])
    check uneven.finalize().toHex == oneShot

  test "空 update 不改变结果":
    var ctx = initSha256()
    ctx.update("")
    ctx.update("abc")
    ctx.update("")
    check ctx.finalize().toHex == AbcHash

suite "输出形状":

  test "摘要恒为 32 字节、64 个十六进制字符":
    let digest = sha256("abc".toOpenArrayByte(0, 2))
    check digest.len == 32
    check digest.toHex.len == 64

  test "十六进制输出为小写且只含合法字符":
    let hex = sha256Hex("Isvik")
    check hex == hex.toLowerAscii
    for c in hex:
      check c in {'0' .. '9', 'a' .. 'f'}

  test "不同输入给出不同摘要":
    check sha256Hex("a") != sha256Hex("b")
    check sha256Hex("abc") != sha256Hex("abd")
    # 单比特差异
    check sha256Hex("\x00") != sha256Hex("\x01")

suite "文件摘要":

  test "文件摘要与同内容的字符串摘要一致":
    let path = getTempDir() / "isvik_test_checksum.bin"
    let content = "Isvik model integrity probe\n"
    writeFile(path, content)
    check sha256FileHex(path) == sha256Hex(content)
    removeFile(path)

  test "空文件的摘要是空输入的摘要":
    let path = getTempDir() / "isvik_test_checksum_empty.bin"
    writeFile(path, "")
    check sha256FileHex(path) == EmptyHash
    removeFile(path)

  test "跨读取块边界的大文件仍然正确":
    # 文件大于单次读取块(1 MiB),验证分块累积没有丢数据或重复。
    let path = getTempDir() / "isvik_test_checksum_large.bin"
    let unit = "0123456789abcdef"          # 16 字节
    var content = newStringOfCap(3 * 1024 * 1024)
    for _ in 0 ..< (3 * 1024 * 1024 div unit.len):
      content.add(unit)
    writeFile(path, content)
    check sha256FileHex(path) == sha256Hex(content)
    removeFile(path)

  test "内容改一个字节,摘要就变":
    let path = getTempDir() / "isvik_test_checksum_mut.bin"
    writeFile(path, "aaaa")
    let before = sha256FileHex(path)
    writeFile(path, "aaab")
    check sha256FileHex(path) != before
    removeFile(path)

  test "文件不存在时抛 IOError,由调用方翻译错误码":
    # 通用工具不该绑定某个业务错误码。
    expect IOError:
      discard sha256FileHex(getTempDir() / "isvik_no_such_file_xyz.bin")
