version       = "0.1.0"
author        = "WANG"
description   = "Resonance: A Nim OpenVINO C API wrapper / binding library with Intel NPU-oriented runtime helpers."
license       = "Apache-2.0"
srcDir        = "src"

requires "nim >= 2.0.0"

task demo, "Build the basic inference example":
  exec "nim c -r --path:src examples/basic_infer.nim"

task test, "Run the Resonance test suite":
  ## Most tests do not require openvino_c.dll: they verify that the enum values
  ## match the official headers and that the ABI shim compiles and links.
  ## Tests that need a real runtime are skipped (not silently passed) when the
  ## DLL cannot be loaded.
  exec "nim c -r --hints:off --path:src tests/tbindings.nim"
