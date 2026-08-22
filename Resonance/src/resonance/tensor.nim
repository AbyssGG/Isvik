import c_api
import errors

type
  TensorObj* = object
    pTensor*: ptr OvTensor
  Tensor* = ref TensorObj

proc `=destroy`*(t: var TensorObj) =
  if t.pTensor != nil:
    ov_tensor_free(t.pTensor)
    t.pTensor = nil

proc isClosed*(t: Tensor): bool =
  ## Whether the native handle has already been released.
  t == nil or t.pTensor == nil

proc close*(t: Tensor) =
  ## Releases the native handle immediately instead of waiting for `=destroy`.
  ##
  ## For host-backed tensors this frees only the OpenVINO-side wrapper; the
  ## backing buffer belongs to whoever allocated it and is untouched.
  ##
  ## Idempotent.
  if t != nil and t.pTensor != nil:
    ov_tensor_free(t.pTensor)
    t.pTensor = nil

proc requireOpen*(t: Tensor, action: string) =
  ## Guards against use-after-close. See `model.requireOpen` for the rationale.
  if t.isClosed:
    raiseOpenVinoError(action, INVALID_C_PARAM, "tensor handle is closed")

proc makeShape(dims: seq[int64]): OvShape =
  result.rank = dims.len.int64
  result.dims = if dims.len > 0: unsafeAddr dims[0] else: nil

proc newTensor*(typ: OvElementType, dims: seq[int64], data: pointer): Tensor =
  ## Creates a tensor that is a logical view over caller-owned memory.
  ##
  ## `data` is **not copied**. The caller must keep that buffer alive for as
  ## long as the tensor is in use, including across inference calls.
  var mutableDims = dims
  var shape = makeShape(mutableDims)
  var pTensor: ptr OvTensor
  requireStatus(
    ov_tensor_create_from_host_ptr(typ, shape, data, addr pTensor),
    "Create tensor from host pointer"
  )
  new(result)
  result.pTensor = pTensor

proc newOwnedTensor*(typ: OvElementType, dims: seq[int64]): Tensor =
  ## Creates a tensor whose memory OpenVINO allocates and owns.
  ##
  ## Prefer `newTensor` when the data already lives in a Nim buffer: that avoids
  ## a copy. This variant exists for element types that have no flat byte
  ## layout -- STRING in particular -- which cannot be host-backed at all.
  var mutableDims = dims
  var shape = makeShape(mutableDims)
  var pTensor: ptr OvTensor
  requireStatus(
    ov_tensor_create(typ, shape, addr pTensor),
    "Create tensor"
  )
  new(result)
  result.pTensor = pTensor

proc setStringData*(t: Tensor, texts: openArray[string]) =
  ## Writes UTF-8 strings into a STRING tensor.
  ##
  ## The runtime copies the characters, so `texts` does not need to outlive the
  ## call -- unlike `newTensor`, which aliases caller memory.
  t.requireOpen("Set tensor string data")
  if texts.len == 0:
    # Nothing to write. Verified on the real DLL: calling the C function with a
    # null pointer and size 0 returns INVALID_C_PARAM rather than succeeding as
    # a no-op. Returning early keeps a zero-element STRING tensor usable, and
    # keeps `newStringTensor(xs).getSize() == xs.len` true for every input.
    return
  # `cstring` borrows from the Nim string, so the seq must stay alive until the
  # C call returns. Binding it to a local keeps it rooted.
  var pointers = newSeq[cstring](texts.len)
  for i, s in texts:
    pointers[i] = s.cstring
  requireStatus(
    ov_tensor_set_string_data(
      t.pTensor,
      if pointers.len > 0: addr pointers[0] else: nil,
      csize_t(pointers.len)
    ),
    "Set tensor string data"
  )

proc newStringTensor*(texts: openArray[string]): Tensor =
  ## Creates a 1-D STRING tensor holding `texts`.
  ##
  ## This is the only way to feed a tokenizer IR: its single input port has
  ## element type STRING (verified on the real model, DEVLOG section 9.5).
  result = newOwnedTensor(STRING, @[int64(texts.len)])
  result.setStringData(texts)

proc getData*[T](t: Tensor, _: typedesc[T]): ptr UncheckedArray[T] =
  t.requireOpen("Get tensor data")
  var p: pointer
  requireStatus(ov_tensor_data(t.pTensor, addr p), "Get tensor data")
  result = cast[ptr UncheckedArray[T]](p)

proc setShape*(t: Tensor, dims: seq[int64]) =
  t.requireOpen("Set tensor shape")
  var mutableDims = dims
  var shape = makeShape(mutableDims)
  requireStatus(ov_tensor_set_shape(t.pTensor, addr shape), "Set tensor shape")

proc getShape*(t: Tensor): seq[int64] =
  t.requireOpen("Get tensor shape")
  var shape: OvShape
  requireStatus(ov_tensor_get_shape(t.pTensor, addr shape), "Get tensor shape")
  try:
    result = newSeq[int64](int(shape.rank))
    if shape.dims != nil:
      let dims = cast[ptr UncheckedArray[int64]](shape.dims)
      for i in 0 ..< int(shape.rank):
        result[i] = dims[i]
  finally:
    discard ov_shape_free(addr shape)

proc getSize*(t: Tensor): int =
  ## Number of elements, i.e. the product of the dimensions.
  let dims = t.getShape()
  result = 1
  for dim in dims:
    result *= int(dim)

proc getElementType*(t: Tensor): OvElementType =
  ## The tensor's element type as reported by OpenVINO.
  ##
  ## Needed when reading *output* tensors: their type is decided by the model,
  ## not by the caller, so it has to be queried rather than assumed.
  t.requireOpen("Get tensor element type")
  var typ: OvElementType
  requireStatus(ov_tensor_get_element_type(t.pTensor, addr typ),
                "Get tensor element type")
  result = typ

proc getByteSize*(t: Tensor): int =
  ## Size of the tensor's data in bytes, as reported by OpenVINO.
  ##
  ## Preferred over computing `elementCount * elementSize` by hand: for
  ## sub-byte element types the two disagree, and OpenVINO knows the real
  ## allocation size.
  t.requireOpen("Get tensor byte size")
  var size: csize_t
  requireStatus(ov_tensor_get_byte_size(t.pTensor, addr size),
                "Get tensor byte size")
  result = int(size)
