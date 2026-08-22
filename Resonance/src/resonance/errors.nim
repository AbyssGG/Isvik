import std/strformat

import c_api

type
  OpenVinoError* = object of CatchableError
    ## Raised when an OpenVINO call reports a non-OK status.
    ##
    ## The status code and the action name are kept as **structured fields**,
    ## not only interpolated into `msg`. Callers that need to react differently
    ## per status (mapping `NOT_FOUND` to "model missing" versus mapping a
    ## generic failure to "compilation failed", for instance) would otherwise
    ## have to parse the message string, which breaks as soon as the wording
    ## changes.
    status*: OvStatus
      ## The raw `ov_status_e` value returned by the failing call.
    action*: string
      ## Short description of what was attempted, e.g. "Compile model".

proc lastErrorDetail*(): string =
  let msg = ov_get_last_err_msg()
  if msg == nil:
    return ""
  result = $msg

proc raiseOpenVinoError*(action: string, status: OvStatus, detail: string = "") {.noreturn.} =
  var message = &"{action} failed with status {ord(status)} ({status})"
  if detail.len > 0:
    message.add(": " & detail)
  let last = lastErrorDetail()
  if last.len > 0 and last != detail:
    message.add(" | OpenVINO: " & last)
  # The message format is unchanged for backward compatibility; the fields are
  # additive so existing `except OpenVinoError as e: echo e.msg` still works.
  var err = newException(OpenVinoError, message)
  err.status = status
  err.action = action
  raise err

proc requireStatus*(status: OvStatus, action: string, detail: string = "") =
  if status != OK:
    raiseOpenVinoError(action, status, detail)
