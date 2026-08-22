import c_api
import errors
import infer_request

type
  CompiledModelObj* = object
    pCompiledModel*: ptr OvCompiledModel
  CompiledModel* = ref CompiledModelObj

proc `=destroy`*(m: var CompiledModelObj) =
  if m.pCompiledModel != nil:
    ov_compiled_model_free(m.pCompiledModel)
    m.pCompiledModel = nil

proc isClosed*(m: CompiledModel): bool =
  ## Whether the native handle has already been released.
  m == nil or m.pCompiledModel == nil

proc close*(m: CompiledModel) =
  ## Releases the native handle immediately instead of waiting for `=destroy`.
  ##
  ## This matters more for compiled models than for anything else in the
  ## library: a compiled model holds device-side memory. On an NPU that memory
  ## is scarce, and waiting for the GC to decide means an unrelated part of the
  ## application can fail to compile because memory that is logically free has
  ## not been handed back yet.
  ##
  ## Idempotent.
  if m != nil and m.pCompiledModel != nil:
    ov_compiled_model_free(m.pCompiledModel)
    m.pCompiledModel = nil

proc requireOpen*(m: CompiledModel, action: string) =
  ## Guards against use-after-close. See `model.requireOpen` for the rationale.
  if m.isClosed:
    raiseOpenVinoError(action, INVALID_C_PARAM,
                       "compiled model handle is closed")

proc createInferRequest*(m: CompiledModel): InferRequest =
  m.requireOpen("Create infer request")
  var pReq: ptr OvInferRequest
  requireStatus(
    ov_compiled_model_create_infer_request(m.pCompiledModel, addr pReq),
    "Create infer request"
  )
  new(result)
  result.pReq = pReq

proc exportModelToFile*(m: CompiledModel, path: string) =
  m.requireOpen("Export compiled model")
  requireStatus(
    ov_compiled_model_export_model(m.pCompiledModel, path.cstring),
    "Export compiled model",
    path
  )

# ---------------------------------------------------------------------------
# Port introspection
# ---------------------------------------------------------------------------
#
# Reading port names is the prerequisite for binding tensors by name. A caller
# that wants to drive a KV-cache first needs to know *which* ports exist --
# `past_key_values.0.key` and friends are discovered, not assumed.

type
  PortInfo* = object
    ## One input or output port of a compiled model.
    name*: string
      ## The port's name as reported by OpenVINO.
    index*: int
      ## Positional index, kept so callers can still use the by-index API.
    elementType*: OvElementType
    shape*: seq[int64]
      ## Static shape. A dynamic dimension appears as `-1`.

proc readPortInfo(pPort: ptr OvOutputConstPort, index: int): PortInfo =
  ## Reads one port's metadata and releases the port handle.
  ##
  ## Each field is fetched separately and a failure to read shape or element
  ## type is **tolerated** (leaving the field empty / `DYNAMIC`) while a failure
  ## to read the name is not. Rationale: the name is the whole point of this
  ## API, whereas shape genuinely may be unavailable for a fully dynamic port,
  ## and refusing to report the port at all in that case would be unhelpful.
  result = PortInfo(name: "", index: index, elementType: DYNAMIC, shape: @[])
  try:
    var cname: cstring = nil
    requireStatus(ov_port_get_any_name(pPort, addr cname),
                  "Get port name", "index=" & $index)
    if cname != nil:
      result.name = $cname
      # Allocated by OpenVINO: must go back through ov_free, not dealloc.
      ov_free(cname)

    var typ: OvElementType
    if ov_port_get_element_type(pPort, addr typ) == OK:
      result.elementType = typ

    var shape: OvShape
    if ov_const_port_get_shape(pPort, addr shape) == OK:
      for i in 0 ..< int(shape.rank):
        result.shape.add(cast[ptr UncheckedArray[int64]](shape.dims)[i])
      discard ov_shape_free(addr shape)
  finally:
    ov_output_const_port_free(pPort)

proc inputCount*(m: CompiledModel): int =
  ## Number of input ports.
  m.requireOpen("Get input count")
  var size: csize_t
  requireStatus(
    ov_compiled_model_inputs_size(m.pCompiledModel, addr size),
    "Get input count"
  )
  int(size)

proc outputCount*(m: CompiledModel): int =
  ## Number of output ports.
  m.requireOpen("Get output count")
  var size: csize_t
  requireStatus(
    ov_compiled_model_outputs_size(m.pCompiledModel, addr size),
    "Get output count"
  )
  int(size)

proc inputPort*(m: CompiledModel, index: int): PortInfo =
  ## Metadata for one input port.
  m.requireOpen("Get input port")
  var pPort: ptr OvOutputConstPort
  requireStatus(
    ov_compiled_model_input_by_index(m.pCompiledModel, index.csize_t, addr pPort),
    "Get input port",
    "index=" & $index
  )
  readPortInfo(pPort, index)

proc outputPort*(m: CompiledModel, index: int): PortInfo =
  ## Metadata for one output port.
  m.requireOpen("Get output port")
  var pPort: ptr OvOutputConstPort
  requireStatus(
    ov_compiled_model_output_by_index(m.pCompiledModel, index.csize_t, addr pPort),
    "Get output port",
    "index=" & $index
  )
  readPortInfo(pPort, index)

proc inputPorts*(m: CompiledModel): seq[PortInfo] =
  ## All input ports, in index order.
  result = @[]
  for i in 0 ..< m.inputCount:
    result.add(m.inputPort(i))

proc outputPorts*(m: CompiledModel): seq[PortInfo] =
  ## All output ports, in index order.
  result = @[]
  for i in 0 ..< m.outputCount:
    result.add(m.outputPort(i))

proc findInputPort*(m: CompiledModel, name: string): int =
  ## Index of the input port with the given name, or -1 when absent.
  ##
  ## Returns -1 rather than raising: "does this model have a KV-cache?" is a
  ## question a caller asks in order to *decide* what to do, not an error.
  for port in m.inputPorts:
    if port.name == name:
      return port.index
  -1

proc hasInputPort*(m: CompiledModel, name: string): bool =
  m.findInputPort(name) >= 0
