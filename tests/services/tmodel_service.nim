## Model Service 测试
##
## 重点是**解析策略**:它此前被复制在 cmd_chat 与 workbench 两处,下沉到服务后
## 必须保持同样的取舍(目录优先、其次 id、空引用时不替用户挑),并且把失败原因
## 表达成状态而不是界面文案。
##
## 不需要真实模型文件:解析只看目录是否存在与清单里有没有该 id。

import std/[os, strutils, unittest]

import isvik/core/errors
import isvik/models/storage
import isvik/services/model_service

var tempCounter = 0

proc tempRoot(label: string): string =
  inc tempCounter
  result = getTempDir() /
    ("isvik_model_svc_" & label & "_" & $getCurrentProcessId() & "_" &
     $tempCounter)
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc newStore(root: string): ModelStore =
  newModelStore(root)

proc makeSourceModel(dir, fileName: string): string =
  ## 造一个满足生产契约检测的最小 stateful token causal-LM 目录。
  createDir(dir)
  let xml = """<net name="probe" version="11">
<layers>
  <layer id="0" name="input_ids" type="Parameter" version="opset1">
    <data shape="?,?" element_type="i64"/>
    <output>
      <port id="0" precision="I64" names="input_ids"/>
    </output>
  </layer>
  <layer id="1" name="attention_mask" type="Parameter" version="opset1">
    <data shape="?,?" element_type="i64"/>
    <output>
      <port id="0" precision="I64" names="attention_mask"/>
    </output>
  </layer>
  <layer id="2" name="position_ids" type="Parameter" version="opset1">
    <data shape="?,?" element_type="i64"/>
    <output>
      <port id="0" precision="I64" names="position_ids"/>
    </output>
  </layer>
  <layer id="3" name="state_read" type="ReadValue" version="opset6"/>
  <layer id="4" name="state_assign" type="Assign" version="opset6"/>
  <layer id="5" name="logits_source" type="Relu" version="opset1">
    <output>
      <port id="1" precision="FP32" names="logits" shape="?,?,?"/>
    </output>
  </layer>
  <layer id="6" name="logits/sink_port_0" type="Result" version="opset1"/>
</layers>
<edges>
  <edge from-layer="5" from-port="1" to-layer="6" to-port="0"/>
</edges>
</net>"""
  writeFile(dir / fileName & ".xml", xml)
  writeFile(dir / fileName & ".bin", "binary")
  result = dir

proc importOne(store: ModelStore, sourceDir, id: string) =
  discard store.importModel(sourceDir, initImportOptions(id))

suite "Model Service:引用解析":

  test "目录优先于同名标识,路径是明确意图":
    # 这条是刻意的取舍:用户给了一个真实存在的目录,不该被库里一个同名 id
    # 遮住。反过来会让「我给的是路径」这件事被静默改写。
    let root = tempRoot("dir_first")
    defer: removeDir(root)
    let store = newStore(root)
    let source = makeSourceModel(root / "src_a", "openvino_model")
    store.importOne(source, "src_a")

    # 切到父目录，使相对路径 "src_a" 同时是一个真实目录和一个已导入 id。
    let previous = getCurrentDir()
    setCurrentDir(root)
    defer: setCurrentDir(previous)

    let svc = newModelService(newModelManager(store))
    check svc.has("src_a")
    let res = svc.resolveReference("src_a")
    check res.status == mrsResolved
    check res.directory == (root / "src_a").absolutePath
    # 走目录分支时 id 必须为空:那个模型是按路径用的,硬编 id 会让
    # 「它已被导入」看起来成立。
    check res.id == ""
    check res.label == "src_a"

  test "已导入标识解析为库内内容目录与展示名":
    let root = tempRoot("by_id")
    defer: removeDir(root)
    let store = newStore(root)
    let source = makeSourceModel(root / "source", "openvino_model")
    store.importOne(source, "gemma-probe")

    let svc = newModelService(newModelManager(store))
    let res = svc.resolveReference("gemma-probe")
    check res.status == mrsResolved
    check res.id == "gemma-probe"
    check res.directory.len > 0
    check dirExists(res.directory)

  test "既不是目录也不是标识时报 not-found,而不是抛界面文案":
    let root = tempRoot("missing")
    defer: removeDir(root)
    let svc = newModelService(newModelManager(newStore(root)))
    let res = svc.resolveReference("no_such_thing_xyz")
    check res.status == mrsNotFound
    check res.requested == "no_such_thing_xyz"
    check res.directory == ""

  test "空引用:空库报 store-empty 并带上模型库位置":
    let root = tempRoot("empty")
    defer: removeDir(root)
    let svc = newModelService(newModelManager(newStore(root)))
    let res = svc.resolveReference("")
    check res.status == mrsStoreEmpty
    check res.ids.len == 0
    # 前端要用它提示「用 import 导入」,因此失败时也必须带上。
    check res.rootDirectory.len > 0

  test "空引用:恰好一个模型就用它":
    let root = tempRoot("single")
    defer: removeDir(root)
    let store = newStore(root)
    store.importOne(makeSourceModel(root / "only", "openvino_model"), "only-one")

    let svc = newModelService(newModelManager(store))
    let res = svc.resolveReference("")
    check res.status == mrsResolved
    check res.id == "only-one"

  test "空引用:多个模型时不替用户挑":
    let root = tempRoot("many")
    defer: removeDir(root)
    let store = newStore(root)
    store.importOne(makeSourceModel(root / "a", "openvino_model"), "model-a")
    store.importOne(makeSourceModel(root / "b", "openvino_model"), "model-b")

    let svc = newModelService(newModelManager(store))
    let res = svc.resolveReference("")
    check res.status == mrsAmbiguous
    check res.ids.len == 2
    # 候选必须回传:前端要把它们列给用户。
    check "model-a" in res.ids
    check "model-b" in res.ids

  test "首尾空白不影响解析":
    let root = tempRoot("trim")
    defer: removeDir(root)
    let store = newStore(root)
    store.importOne(makeSourceModel(root / "s", "openvino_model"), "trim-me")
    let svc = newModelService(newModelManager(store))
    check svc.resolveReference("  trim-me  ").status == mrsResolved
    # 只有空白等同于「没指定」,不是一个叫空格的模型。
    check svc.resolveReference("   ").status == mrsResolved

suite "Model Service:编号解析":

  test "编号映射到按标识排序的稳定序列":
    # 不用文件系统遍历顺序:那个顺序不保证稳定,会让 [1] 指向的模型漂移。
    let root = tempRoot("index")
    defer: removeDir(root)
    let store = newStore(root)
    store.importOne(makeSourceModel(root / "z", "openvino_model"), "zeta")
    store.importOne(makeSourceModel(root / "a", "openvino_model"), "alpha")

    let svc = newModelService(newModelManager(store))
    check svc.ids() == @["alpha", "zeta"]
    check svc.resolveIndex(1).id == "alpha"
    check svc.resolveIndex(2).id == "zeta"

  test "越界与非正编号报 index-out-of-range 并带上总数":
    let root = tempRoot("index_bad")
    defer: removeDir(root)
    let store = newStore(root)
    store.importOne(makeSourceModel(root / "a", "openvino_model"), "only")

    let svc = newModelService(newModelManager(store))
    for bad in [0, -1, 2, 99]:
      let res = svc.resolveIndex(bad)
      check res.status == mrsIndexOutOfRange
      check res.ids.len == 1

suite "Model Service:失败转错误码":

  test "每种失败状态映射到对应的 Isvik 错误码":
    let root = tempRoot("codes")
    defer: removeDir(root)
    let store = newStore(root)
    let svc = newModelService(newModelManager(store))

    proc codeOf(res: ModelResolution): IsvikErrorCode =
      result = ecServerError
      try:
        res.requireResolved()
      except IsvikError as e:
        result = e.code

    # 空库与找不到都属于模型类错误。
    check codeOf(svc.resolveReference("")) == ecModelNotFound
    check codeOf(svc.resolveReference("nope")) == ecModelNotFound
    check codeOf(svc.resolveIndex(1)) == ecInvalidParameter

    store.importOne(makeSourceModel(root / "a", "openvino_model"), "a-model")
    store.importOne(makeSourceModel(root / "b", "openvino_model"), "b-model")
    # 多选是调用方没说清楚,属于参数错误而不是模型缺失。
    check codeOf(svc.resolveReference("")) == ecInvalidParameter

  test "解析成功时 requireResolved 不抛异常":
    let root = tempRoot("ok")
    defer: removeDir(root)
    let store = newStore(root)
    store.importOne(makeSourceModel(root / "a", "openvino_model"), "fine")
    let svc = newModelService(newModelManager(store))
    let res = svc.resolveRequired("fine")
    check res.status == mrsResolved

  test "错误消息不含路径,可变部分只出现在 detail":
    # §22:detail 不进 API 响应。凡是含路径的内容都只能放 detail,
    # 否则模型库的绝对路径会随错误响应外泄。
    let root = tempRoot("detail")
    defer: removeDir(root)
    let svc = newModelService(newModelManager(newStore(root)))
    var captured: ref IsvikError = nil
    try:
      svc.resolveReference("").requireResolved()
    except IsvikError as e:
      captured = e
    check captured != nil
    check not captured.msg.contains(root)
    check captured.detail.contains(root)
    # 同时确认它确实没有出现在对外响应里。
    check not captured.toJson().contains(root)
