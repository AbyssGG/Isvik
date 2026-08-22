import c_api
import errors

type
  PartialDimension* = object
    minimum*: int64
    maximum*: int64

  ModelInputShape* = object
    name*: string
    dims*: seq[PartialDimension]

  ModelObj* = object
    pModel*: ptr OvModel
  Model* = ref ModelObj

proc `=destroy`*(m: var ModelObj) =
  if m.pModel != nil:
    ov_model_free(m.pModel)
    m.pModel = nil

proc isClosed*(m: Model): bool =
  ## Whether the native handle has already been released.
  m == nil or m.pModel == nil

proc close*(m: Model) =
  ## Releases the native handle immediately instead of waiting for `=destroy`.
  ##
  ## Why this exists alongside the destructor: a destructor runs whenever the
  ## GC decides to collect, which for device-side resources is too late to be
  ## useful. Applications that need to hand memory back at a known point --
  ## releasing an NPU-compiled model right after exporting its blob, for
  ## instance -- cannot express that with a destructor alone.
  ##
  ## Idempotent: the pointer is nil'd, so both a second `close` and the
  ## eventual `=destroy` become no-ops.
  if m != nil and m.pModel != nil:
    ov_model_free(m.pModel)
    m.pModel = nil

proc requireOpen*(m: Model, action: string) =
  ## Guards against use-after-close.
  ##
  ## Without this, calling a method on a closed handle would pass a nil pointer
  ## into the C API. Some entry points return `INVALID_C_PARAM`, others
  ## dereference it -- the failure mode is inconsistent and, in the second
  ## case, a crash with no usable diagnostics. Failing here turns that into a
  ## normal catchable error naming the action.
  if m.isClosed:
    raiseOpenVinoError(action, INVALID_C_PARAM, "model handle is closed")

proc reshape*(m: Model, inputs: openArray[ModelInputShape]) =
  ## Applies bounded partial shapes to model inputs before compilation.
  m.requireOpen("Reshape model")
  if inputs.len == 0:
    return

  var nameStorage = newSeq[string](inputs.len)
  var names = newSeq[cstring](inputs.len)
  var partials = newSeq[OvPartialShape](inputs.len)
  var created = 0
  try:
    for i, input in inputs:
      if input.name.len == 0 or input.dims.len == 0:
        raiseOpenVinoError("Reshape model", INVALID_C_PARAM,
                           "input name and dimensions must not be empty")
      nameStorage[i] = input.name
      names[i] = nameStorage[i].cstring
      var nativeDims = newSeq[OvDimension](input.dims.len)
      for j, dim in input.dims:
        if dim.minimum < 0 or dim.maximum < dim.minimum:
          raiseOpenVinoError("Reshape model", INVALID_C_PARAM,
                             "invalid bounded dimension")
        nativeDims[j] = OvDimension(min: dim.minimum, max: dim.maximum)
      let rank = OvDimension(min: input.dims.len.int64,
                             max: input.dims.len.int64)
      requireStatus(
        ov_partial_shape_create_dynamic(
          rank, unsafeAddr nativeDims[0], addr partials[i]),
        "Create bounded partial shape", input.name)
      inc created

    requireStatus(
      ov_model_reshape(m.pModel, unsafeAddr names[0], unsafeAddr partials[0],
                       inputs.len.csize_t),
      "Reshape model", "inputs=" & $inputs.len)
  finally:
    for i in 0 ..< created:
      ov_partial_shape_free(addr partials[i])
