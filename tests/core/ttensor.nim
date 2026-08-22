## Task 5 测试:Core 的 Tensor

import std/[unittest, strutils]

import isvik/core/errors
import isvik/core/tensor

suite "元素类型":

  test "字符串表示是稳定契约":
    check $etBool == "BOOL"
    check $etBF16 == "BF16"
    check $etF16 == "F16"
    check $etF32 == "F32"
    check $etF64 == "F64"
    check $etI4 == "I4"
    check $etI8 == "I8"
    check $etI16 == "I16"
    check $etI32 == "I32"
    check $etI64 == "I64"
    check $etU1 == "U1"
    check $etU4 == "U4"
    check $etU8 == "U8"
    check $etU16 == "U16"
    check $etU32 == "U32"
    check $etU64 == "U64"

  test "类型总数为 16,不含 DYNAMIC":
    # 已分配的张量必然有确定类型,动态性属于模型端口而非张量。
    var count = 0
    var names: seq[string] = @[]
    for et in ElementType:
      inc count
      names.add($et)
    check count == 16
    check "DYNAMIC" notin names

  test "位宽正确":
    check bitsPerElement(etU1) == 1
    check bitsPerElement(etI4) == 4
    check bitsPerElement(etU4) == 4
    check bitsPerElement(etBool) == 8
    check bitsPerElement(etI8) == 8
    check bitsPerElement(etU8) == 8
    check bitsPerElement(etF16) == 16
    check bitsPerElement(etBF16) == 16
    check bitsPerElement(etI16) == 16
    check bitsPerElement(etU16) == 16
    check bitsPerElement(etF32) == 32
    check bitsPerElement(etI32) == 32
    check bitsPerElement(etU32) == 32
    check bitsPerElement(etF64) == 64
    check bitsPerElement(etI64) == 64
    check bitsPerElement(etU64) == 64

  test "亚字节类型被标记为非字节对齐":
    check not isByteAligned(etU1)
    check not isByteAligned(etI4)
    check not isByteAligned(etU4)

  test "其余类型均为字节对齐":
    for et in ElementType:
      if et notin {etU1, etI4, etU4}:
        check isByteAligned(et)

  test "字节对齐类型的字节宽度正确":
    check bytesPerElement(etI8) == 1
    check bytesPerElement(etU8) == 1
    check bytesPerElement(etBool) == 1
    check bytesPerElement(etF16) == 2
    check bytesPerElement(etI32) == 4
    check bytesPerElement(etF32) == 4
    check bytesPerElement(etF64) == 8
    check bytesPerElement(etI64) == 8

  test "亚字节类型的字节宽度查询抛 NOT_IMPLEMENTED":
    # 返回一个「看起来合理」的数字会让上层算出错误的缓冲大小,
    # 因此明确报未实现而不是猜。
    for et in [etU1, etI4, etU4]:
      var caught = false
      var code: IsvikErrorCode
      try:
        discard bytesPerElement(et)
      except IsvikError as e:
        caught = true
        code = e.code
      check caught
      if caught:
        check code == ecNotImplemented

suite "形状与元素数":

  test "常规形状":
    check elementCountOf([2, 3, 4]) == 24
    check elementCountOf([1, 3, 224, 224]) == 150528
    check elementCountOf([5]) == 5

  test "空形状表示标量,元素数为 1":
    var empty: seq[int] = @[]
    check elementCountOf(empty) == 1

  test "任一维度为 0 时元素数为 0":
    check elementCountOf([0]) == 0
    check elementCountOf([2, 0, 3]) == 0

  test "形状文本可读":
    check shapeText([1, 3, 224, 224]) == "[1, 3, 224, 224]"
    check shapeText([5]) == "[5]"
    var empty: seq[int] = @[]
    check shapeText(empty) == "[]"

suite "构造张量":

  test "零初始化张量的尺寸正确":
    let t = newTensor(etF32, [2, 3])
    check t.elementType == etF32
    check t.shape == @[2, 3]
    check t.rank == 2
    check t.elementCount == 6
    check t.byteLen == 24        # 6 * 4 字节
    check not t.isEmpty

  test "零初始化的内容确实全为 0":
    let t = newTensor(etI32, [4])
    check t.toSeq(int32) == @[0'i32, 0, 0, 0]

  test "标量张量":
    var empty: seq[int] = @[]
    let t = newTensor(etF32, empty)
    check t.rank == 0
    check t.elementCount == 1
    check t.byteLen == 4

  test "空张量的指针为 nil,不崩溃":
    let t = newTensor(etF32, [0])
    check t.isEmpty
    check t.elementCount == 0
    check t.byteLen == 0
    check t.dataPtr == nil

  test "负数维度被拒绝":
    var caught = false
    var code: IsvikErrorCode
    try:
      discard newTensor(etF32, [2, -1])
    except IsvikError as e:
      caught = true
      code = e.code
    check caught
    if caught:
      check code == ecInvalidParameter

  test "亚字节元素类型的张量构造被拒绝":
    var caught = false
    try:
      discard newTensor(etI4, [8])
    except IsvikError as e:
      caught = true
      check e.code == ecNotImplemented
    check caught

  test "从数据构造并复制内容":
    let t = newTensor(etF32, [3], [1.5'f32, 2.5, 3.5])
    check t.toSeq(float32) == @[1.5'f32, 2.5, 3.5]

  test "构造时数据被复制,不是引用":
    # 张量的生命周期不应依赖调用方的临时变量,否则出借给 Backend 的
    # 指针可能指向已失效的内存。
    var source = @[1'i32, 2, 3]
    let t = newTensor(etI32, [3], source)
    source[0] = 999
    check t.toSeq(int32) == @[1'i32, 2, 3]

  test "数据数量与形状不符时报错":
    var caught = false
    try:
      discard newTensor(etF32, [4], [1.0'f32, 2.0])
    except IsvikError as e:
      caught = true
      check e.code == ecInvalidParameter
      check e.detail.contains("expectedCount=4")
      check e.detail.contains("gotCount=2")
    check caught

  test "Nim 类型宽度与元素类型不符时报错":
    # 用 int32 去填 F64 张量会写出错误的内存布局,必须拦住。
    var caught = false
    try:
      discard newTensor(etF64, [2], [1'i32, 2])
    except IsvikError as e:
      caught = true
      check e.code == ecInvalidParameter
      check e.detail.contains("expectedBytes=8")
    check caught

suite "读写数据":

  test "data 提供类型化访问":
    let t = newTensor(etI32, [3], [10'i32, 20, 30])
    let p = t.data(int32)
    check p[0] == 10
    check p[1] == 20
    check p[2] == 30

  test "通过 data 写入后可读回":
    let t = newTensor(etF32, [2])
    let p = t.data(float32)
    p[0] = 7.5
    p[1] = -1.25
    check t.toSeq(float32) == @[7.5'f32, -1.25]

  test "setFrom 覆盖全部内容":
    let t = newTensor(etI64, [3])
    t.setFrom([100'i64, 200, 300])
    check t.toSeq(int64) == @[100'i64, 200, 300]

  test "setFrom 数量不符时报错":
    let t = newTensor(etI32, [3])
    var caught = false
    try:
      t.setFrom([1'i32, 2])
    except IsvikError as e:
      caught = true
      check e.code == ecInvalidParameter
    check caught

  test "fillZero 清空内容":
    let t = newTensor(etF32, [3], [1.0'f32, 2.0, 3.0])
    t.fillZero()
    check t.toSeq(float32) == @[0.0'f32, 0.0, 0.0]

  test "空张量的 data 返回 nil":
    let t = newTensor(etF32, [0])
    check t.data(float32) == nil
    check t.toSeq(float32).len == 0

  test "类型不匹配的读取被拒绝":
    let t = newTensor(etF32, [2])
    var caught = false
    try:
      discard t.toSeq(float64)
    except IsvikError as e:
      caught = true
      check e.code == ecInvalidParameter
    check caught

  test "dataPtr 指向的内存与 data 一致":
    let t = newTensor(etU8, [4], [1'u8, 2, 3, 4])
    check t.dataPtr != nil
    let asBytes = cast[ptr UncheckedArray[uint8]](t.dataPtr)
    check asBytes[0] == 1
    check asBytes[3] == 4

suite "多种类型的往返":

  test "F32":
    let t = newTensor(etF32, [2], [1.25'f32, -2.5])
    check t.toSeq(float32) == @[1.25'f32, -2.5]

  test "F64":
    let t = newTensor(etF64, [2], [1.25'f64, -2.5])
    check t.toSeq(float64) == @[1.25'f64, -2.5]

  test "I8 与 U8":
    check newTensor(etI8, [2], [-1'i8, 127]).toSeq(int8) == @[-1'i8, 127]
    check newTensor(etU8, [2], [0'u8, 255]).toSeq(uint8) == @[0'u8, 255]

  test "I16 与 U16":
    check newTensor(etI16, [2], [-32768'i16, 32767]).toSeq(int16) ==
      @[-32768'i16, 32767]
    check newTensor(etU16, [2], [0'u16, 65535]).toSeq(uint16) ==
      @[0'u16, 65535]

  test "I32 与 U32":
    check newTensor(etI32, [1], [-2147483648'i32]).toSeq(int32) ==
      @[-2147483648'i32]
    check newTensor(etU32, [1], [4294967295'u32]).toSeq(uint32) ==
      @[4294967295'u32]

  test "I64 与 U64":
    check newTensor(etI64, [1], [-9223372036854775807'i64]).toSeq(int64) ==
      @[-9223372036854775807'i64]
    check newTensor(etU64, [1], [18446744073709551615'u64]).toSeq(uint64) ==
      @[18446744073709551615'u64]

  test "大张量的尺寸计算不溢出":
    let t = newTensor(etF32, [1, 3, 224, 224])
    check t.elementCount == 150528
    check t.byteLen == 602112

suite "展示":

  test "$ 输出含类型、形状与字节数":
    let text = $newTensor(etF32, [2, 3])
    check text.contains("F32")
    check text.contains("[2, 3]")
    check text.contains("24")

  test "nil 张量的 $ 不崩溃":
    let t: Tensor = nil
    check $t == "Tensor(nil)"
