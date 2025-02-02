
from compiler/astalgo import strTableGet
from compiler/modulegraphs import ModuleGraph, newModuleGraph
from compiler/idents import IdentCache, newIdentCache, getIdent
from compiler/vmdef import PCtx, newCtx, TEvalMode
from compiler/sem import semPass
from compiler/vm import evalPass, registerAdditionalOps, execProc, setupGlobalCtx
from compiler/llstream import llStreamOpen
from compiler/options import ConfigRef, newConfigRef
from compiler/condsyms import initDefines, defineSymbol, undefSymbol
from compiler/passes import registerPass, clearPasses, processModule
from compiler/modules import makeModule, compileSystemModule, includeModule, importModule, connectCallbacks
from compiler/ast import PSym, PNode, TSymFlag, initStrTable, newIntNode, newFloatNode, newStrNode, newNode, newTree, TNodeKind,IdGenerator,idGeneratorFromModule
from compiler/pathutils import AbsoluteDir, AbsoluteFile

import os, threadpool, times

import apiImpl
import std/tables
from std/sequtils import zip
import std/marshal
# The path to the directory that contains the scripts, api declaration, and stdlib source
let 
  scriptsDir = getAppDir() / "scripts"
  configRef = newConfigRef()
  identCache = newIdentCache()
var
  idGenerator : IdGenerator #(module:1000,symId:1000,typeId:1000)

configRef.libpath = AbsoluteDir "/home/lotfi/programing/nim/Nim/lib/" # AbsoluteDir(scriptsDir & "/stdlib")
configRef.implicitIncludes.add(scriptsDir / "api.nim")


# Nodes can be passed to setResult or used as arguments in script.call
proc toNode* (val: int): PNode = newIntNode(nkIntLit, val)
proc toNode* (val: float): PNode = newFloatNode(nkFloatLit, val)
proc toNode* (val: string): PNode = newStrNode(nkStrLit, val)
proc toNode* (val: bool): PNode = val.ord.toNode
proc toNode* (val: enum): PNode = val.ord.toNode

proc toNode* (list: openArray[int|float|string|bool|enum]): PNode =
  result = newNode(nkBracket)
  result.sons.initialize(list.len)
  for i in 0..list.high: result.sons[i] = list[i].toNode()

proc toNode* (tree: tuple|object): PNode =
  result = newTree(nkPar)
  for field in tree.fields:
      result.sons.add(field.toNode)

proc toNode* (tree: ref tuple|ref object): PNode =
  result = newTree(nkPar)
  if tree.isNil: return result
  for field in tree[].fields:
      result.sons.add(field.toNode)


proc setupNimscript(graph: ModuleGraph) =
  graph.connectCallbacks()
  initDefines(configRef.symbols)
  defineSymbol(configRef.symbols, "nimscript")
  defineSymbol(configRef.symbols, "nimconfig")
  graph.registerPass(semPass)
  graph.registerPass(evalPass)


proc cleanupNimscript(graph: ModuleGraph) =
  # resetSystemArtifacts()
  initDefines(configRef.symbols)
  undefSymbol(configRef.symbols, "nimscript")
  undefSymbol(configRef.symbols, "nimconfig")
  clearPasses(graph)


proc watch (filename: string): int =
  var writeTime: Time
  var info: FileInfo
  while true:
      info = getFileInfo(filename)
      writeTime = info.lastWriteTime
      sleep(100)
      info = getFileInfo(filename)
      if writeTime != info.lastWriteTime and info.size > 0:
          break


proc compileScript* (filename: string, watch = false): Script =
  # Populate result
  result.new()
  result.graph = newModuleGraph(identCache, configRef)
  setupNimscript(result.graph)
  result.filename = scriptsDir / filename
  result.moduleName = filename.splitFile.name

  result.mainModule = makeModule(result.graph, result.filename)
  idGenerator = idGeneratorFromModule(result.mainModule)
  incl(result.mainModule.flags, sfMainModule)
  result.context = newCtx(result.mainModule, identCache, result.graph,idGenerator)
  result.context.mode = emRepl

  # Expose API
  result.exposeScriptApi()

  # Set context
  setupGlobalCtx(result.mainModule, result.graph,idGenerator)
  registerAdditionalOps(result.context)

  # Compile standard library
  #configRef.searchPaths.add(configRef.libpath)
  #configRef.searchPaths.add(AbsoluteDir configRef.libpath.string & " / pure")
  configRef.searchPaths.add(AbsoluteDir "/home/lotfi/programing/nim/Nim/")
  configRef.searchPaths.add(AbsoluteDir "/home/lotfi/programing/nim/Nim/lib/")
  compileSystemModule(result.graph)

  # Compile script as module
  if not processModule(result.graph, result.mainModule,idGenerator,
      llStreamOpen(AbsoluteFile(result.filename), fmRead)).bool:
      echo "Failed to process `", result.filename, "`"

  # Cleanup
  setupGlobalCtx(nil, result.graph,idGenerator)
  cleanupNimscript(result.graph)

  # Watch the script file for changes
  if watch: result.watcher = spawn watch result.filename


proc reload* (script: Script) =
  setupNimscript(script.graph)

  #initStrTable(script.mainModule.tab) TODO
  setupGlobalCtx(script.mainModule, script.graph,idGenerator)

  if not processModule(script.graph, script.mainModule,idGenerator,
      llStreamOpen(AbsoluteFile script.filename, fmRead)):
      echo "Failed to process `", script.filename, "`"

  cleanupNimscript(script.graph)


proc getProc (script: Script, procName: string): PSym =
    echo "getProc",procName
    var z=getIdent(identCache, procName)
    #echo z.id
    echo "",z.id ," ", z.s,z.h
    for i in script.graph.compilerprocs.data :
      if not i.isNil:
        echo i.name.s
    echo ".."
    for i in script.graph.typeInstCache.keys:
      echo i

      for  j in script.graph.typeInstCache[i]:
        if not j.typ.isNil and not j.typ.sym.isNil:
          echo $$(j.typ.sym.name)
    
    var s = $$script
    echo s
    z=getIdent(identCache, "Point")
    var tmp = script.graph.packageTypes.strTableGet(z)
    #echo $$tmp
    #script.graph
    #return strTableGet(script.mainModule,  procName)
    
    #discard


proc hasProc* (script: Script, procName: string): bool =
    not script.getProc(procName).isNil


proc call* (script: Script, procName: string,
    args: openArray[PNode] = []): PNode {.discardable.} =
    # Check the watcher
    if not script.watcher.isNil and script.watcher.isReady:
      echo script.moduleName, " changed - reloading"
      script.reload()
      script.watcher = spawn watch script.filename
  
    setupGlobalCtx(script.mainModule, script.graph,idGenerator)

    let prc = script.getProc(procName)
    assert(not prc.isNil, "\nUnable to locate proc `" & procName & "` in `" & script.filename & "`")

    result = vm.execProc(script.context, prc, args)
