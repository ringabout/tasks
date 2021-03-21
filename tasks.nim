import std/[macros]

template transfer[T: not ref](x: T): T =
  move(x)

type
  Task = object
    callback: proc (args: pointer) {.nimcall.}
    args: pointer

proc invoke*(task: Task) =
  ## Tasks can only be used once.
  task.callback(task.args)

macro toTask*(e: typed{nkCall | nkCommand}): Task =
  doAssert getTypeInst(e).typeKind == ntyVoid

  if e.len > 1:
    let scratchIdent = genSym(kind = nskTemp, ident = "scratch")
    let impl = e[0].getTypeInst
    let formalParams = impl[0]

    var scratchRecList = newNimNode(nnkRecList)
    var scratchAssignList: seq[NimNode]
    var tempAssignList: seq[NimNode]
    var callNode: seq[NimNode]

    let objTemp = genSym(ident = "obj")
    let transferProc = newIdentNode("transfer")

    for i in 1 ..< formalParams.len:
      let param = formalParams[i][1]

      case param.kind
      of nnkVarTy:
        error("'toTask'ed function cannot have a 'var' parameter")
      of nnkBracketExpr:
        if param[0].eqIdent("sink"):
          scratchRecList.add newIdentDefs(newIdentNode(formalParams[i][0].strVal), param[1])
        else:
          scratchRecList.add newIdentDefs(newIdentNode(formalParams[i][0].strVal), param)
      of nnkSym:
        scratchRecList.add newIdentDefs(newIdentNode(formalParams[i][0].strVal), param)
      else:
        error("'toTask'ed function cannot have a 'static' parameter")
        # scratchRecList.add newIdentDefs(newIdentNode(formalParams[i][0].strVal), getType(param))

      let scratchDotExpr = newDotExpr(scratchIdent, formalParams[i][0])
      case e[i].kind
      of nnkSym:
        scratchAssignList.add newCall(newIdentNode("=sink"), scratchDotExpr, e[i])
      else:
        scratchAssignList.add newAssignment(scratchDotExpr, e[i])

      let tempNode = genSym(kind = nskTemp, ident = "")
      callNode.add tempNode
      tempAssignList.add newLetStmt(tempNode, newCall(transferProc, newDotExpr(objTemp, formalParams[i][0])))

    let stmtList = newStmtList()
    let scratchObjType = genSym(kind = nskType, ident = "ScratchObj")
    let scratchObj = nnkTypeSection.newTree(
                      nnkTypeDef.newTree(
                        scratchObjType,
                        newEmptyNode(),
                        nnkObjectTy.newTree(
                          newEmptyNode(),
                          newEmptyNode(),
                          scratchRecList
                        )
                      )
                    )


    let scratchVarSection = nnkVarSection.newTree(
      nnkIdentDefs.newTree(
        scratchIdent,
        scratchObjType,
        newEmptyNode()
      )
    )

    stmtList.add(scratchObj)
    stmtList.add(scratchVarSection)
    stmtList.add(scratchAssignList)

    var functionStmtList = newStmtList()
    let funcCall = newCall(e[0], callNode)
    functionStmtList.add tempAssignList
    functionStmtList.add funcCall

    let funcName = genSym(nskProc, e[0].strVal)

    result = quote do:
      `stmtList`

      proc `funcName`(args: pointer) {.nimcall.} =
        let `objTemp` = cast[ptr `scratchObjType`](args)
        `functionStmtList`

      Task(callback: `funcName`, args: addr(`scratchIdent`))
  else:
    let funcCall = newCall(e[0])
    let funcName = genSym(nskProc, e[0].strVal)

    result = quote do:
      proc `funcName`(args: pointer) {.nimcall.} =
        `funcCall`

      Task(callback: `funcName`, args: nil)

  echo result.repr

when isMainModule:
  import std/strformat


  block:
    proc hello(x: int, y: seq[string], d = 134) =
      echo fmt"{x=} {y=} {d=}"

    proc ok() =
      echo "ok"

    proc main() =
      var x = @["23456"]
      let t = toTask hello(2233, x)
      t.invoke()

    main()


  block:
    proc hello(x: int, y: seq[string], d = 134) =
      echo fmt"{x=} {y=} {d=}"

    proc ok() =
      echo "ok"

    proc main() =
      var x = @["23456"]
      let t = toTask hello(2233, x)
      t.invoke()
      t.invoke()

    main()

    var x = @["4"]
    let m = toTask hello(2233, x)
    m.invoke()

    let n = toTask ok()
    n.invoke()

  block:
    var called = 0
    block:
      proc hello() =
        inc called

      let a = toTask hello()
      invoke(a)

    doAssert called == 1

    block:
      proc hello(a: int) =
        inc called, a

      let b = toTask hello(13)
      let c = toTask hello(a = 14)
      b.invoke()
      c.invoke()

    doAssert called == 28

    block:
      proc hello(a: int, c: int) =
        inc called, a

      let b = toTask hello(c = 0, a = 8)
      b.invoke()

    doAssert called == 36
