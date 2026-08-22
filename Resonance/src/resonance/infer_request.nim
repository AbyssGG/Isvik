import c_api
import errors
import tensor

type
  InferRequestObj* = object
    pReq*: ptr OvInferRequest
  InferRequest* = ref InferRequestObj

  ProfilingInfo* = object
    status*: int
    realTimeUs*: int64
    cpuTimeUs*: int64
    nodeName*: string
    execType*: string
    nodeType*: string

proc `=destroy`*(req: var InferRequestObj) =
  if req.pReq != nil:
    ov_infer_request_free(req.pReq)
    req.pReq = nil

proc isClosed*(req: InferRequest): bool =
  ## Whether the native handle has already been released.
  req == nil or req.pReq == nil

proc close*(req: InferRequest) =
  ## Releases the native handle immediately instead of waiting for `=destroy`.
  ##
  ## Idempotent.
  if req != nil and req.pReq != nil:
    ov_infer_request_free(req.pReq)
    req.pReq = nil

proc requireOpen*(req: InferRequest, action: string) =
  ## Guards against use-after-close. See `model.requireOpen` for the rationale.
  if req.isClosed:
    raiseOpenVinoError(action, INVALID_C_PARAM,
                       "infer request handle is closed")

proc setInputTensor*(req: InferRequest, idx: int, t: Tensor) =
  ## Binds an input tensor by index.
  ##
  ## Note on lifetime: tensors created by `newTensor` are host-backed, meaning
  ## OpenVINO holds a pointer into memory owned by the caller. The caller must
  ## keep both the tensor **and its backing buffer** alive until inference
  ## completes. This function cannot enforce that.
  req.requireOpen("Set input tensor")
  if t.isClosed:
    raiseOpenVinoError("Set input tensor", INVALID_C_PARAM,
                       "tensor handle is closed, index=" & $idx)
  requireStatus(
    ov_infer_request_set_input_tensor_by_index(req.pReq, idx.csize_t, t.pTensor),
    "Set input tensor",
    "index=" & $idx
  )

proc getOutputTensor*(req: InferRequest, idx: int): Tensor =
  ## Reads an output tensor by index.
  ##
  ## The returned tensor's data is owned by OpenVINO and is only valid until the
  ## next inference on this request. Copy it if it must outlive that.
  req.requireOpen("Get output tensor")
  var pTensor: ptr OvTensor
  requireStatus(
    ov_infer_request_get_output_tensor_by_index(req.pReq, idx.csize_t, addr pTensor),
    "Get output tensor",
    "index=" & $idx
  )
  new(result)
  result.pTensor = pTensor

proc infer*(req: InferRequest) =
  req.requireOpen("Run inference")
  requireStatus(ov_infer_request_infer(req.pReq), "Run inference")

proc getProfilingInfo*(req: InferRequest): seq[ProfilingInfo] =
  req.requireOpen("Get profiling info")
  var infoList: OvProfilingInfoList
  requireStatus(
    ov_infer_request_get_profiling_info(req.pReq, addr infoList),
    "Get profiling info"
  )
  try:
    result = newSeq[ProfilingInfo](int(infoList.size))
    for i in 0 ..< int(infoList.size):
      let p = addr infoList.profilingInfos[i]
      result[i] = ProfilingInfo(
        status: int(p.status),
        realTimeUs: p.realTime,
        cpuTimeUs: p.cpuTime,
        nodeName: if p.nodeName != nil: $p.nodeName else: "",
        execType: if p.execType != nil: $p.execType else: "",
        nodeType: if p.nodeType != nil: $p.nodeType else: ""
      )
  finally:
    if infoList.size > 0:
      ov_profiling_info_list_free(addr infoList)

# ---------------------------------------------------------------------------
# Bind tensors by name
# ---------------------------------------------------------------------------
#
# Why binding by name is required rather than merely convenient:
#
# A KV-cache model exposes dozens of inputs named like
# `past_key_values.0.key`, `past_key_values.0.value`, ... plus `input_ids`,
# `attention_mask`, `position_ids`. Their **indices are an implementation
# detail of the model graph** -- they vary between exports of the same
# architecture, and nothing in the model guarantees an order.
#
# Binding a KV-cache by index therefore means hardcoding an ordering that can
# silently change. The failure mode is the worst kind: inference succeeds and
# produces plausible-looking but wrong tokens, because key and value tensors
# were swapped. Binding by name removes that whole class of bug.

proc setTensor*(req: InferRequest, name: string, t: Tensor) =
  ## Binds a tensor to the port with the given name.
  ##
  ## The lifetime caveat from `setInputTensor` applies here too: host-backed
  ## tensors are pointers into caller-owned memory, which must stay alive until
  ## inference completes.
  req.requireOpen("Set tensor by name")
  if t.isClosed:
    raiseOpenVinoError("Set tensor by name", INVALID_C_PARAM,
                       "tensor handle is closed, name=" & name)
  requireStatus(
    ov_infer_request_set_tensor(req.pReq, name.cstring, t.pTensor),
    "Set tensor by name",
    "name=" & name
  )

proc getTensor*(req: InferRequest, name: string): Tensor =
  ## Reads the tensor bound to the port with the given name.
  ##
  ## Works for both inputs and outputs. For outputs the data is owned by
  ## OpenVINO and is only valid until the next inference on this request.
  ##
  ## This is what makes a KV-cache loop possible: the present-state outputs are
  ## read by name and fed back as the past-state inputs of the next step.
  req.requireOpen("Get tensor by name")
  var pTensor: ptr OvTensor
  requireStatus(
    ov_infer_request_get_tensor(req.pReq, name.cstring, addr pTensor),
    "Get tensor by name",
    "name=" & name
  )
  new(result)
  result.pTensor = pTensor
