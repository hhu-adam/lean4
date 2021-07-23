import Lean.Data.Lsp.Extra
import Lean.Server.Requests
import Lean.Server.FileWorker.LspEncoding

/-! Allows LSP clients to make Remote Procedure Calls to the server.

The single use case for these is to allow the infoview UI to refer to and manipulate heavy-weight
objects residing on the server. It would be inefficient to serialize these into JSON and send over.
For example, the client can format an `Expr` without transporting the whole `Environment`.

All RPC requests are relative to an open file and an RPC session for that file. It must first
be initialized as follows:

- (client -> server notification) `$/lean/rpc/initialize { uri: 'file/of/interest.lean' }`
- (server -> client notification) `$/lean/rpc/initialized { uri: 'file/of/interest.lean', sessionId: '1234' }`
-/

namespace Lean.Server

private structure RpcProcedure where
  wrapper : (sessionId : UInt64) → Json → RequestM (RequestTask Json)

builtin_initialize rpcProcedures : IO.Ref (Std.PersistentHashMap Name RpcProcedure) ←
  IO.mkRef {}

private def handleRpcCall (p : Lsp.RpcCallParams) : RequestM (RequestTask Json) := do
  let rc ← read
  let some proc ← (← rpcProcedures.get).find? p.method
    | throwThe RequestError { code := JsonRpc.ErrorCode.methodNotFound
                              message := s!"No RPC method '{p.method}' bound" }
  proc.wrapper p.sessionId p.params

private def handleRpcRelease (p : Lsp.RpcReleaseParams) : RequestM (RequestTask Json) := do
  let rc ← read
  let some rpcSesh ← rc.rpcSesh?
    | throwThe RequestError { code := JsonRpc.ErrorCode.rpcNotInitialized
                              message := s!"RPC session not initialized" }
  if p.sessionId ≠ rpcSesh.sessionId then
    throwThe RequestError { code := JsonRpc.ErrorCode.rpcNotInitialized
                            message := s!"Outdated RPC session" }
  rpcSesh.state.modify fun st => st.release p.ref
  RequestM.asTask do
    return Json.null

builtin_initialize
  registerLspRequestHandler "$/lean/rpc/call"    Lsp.RpcCallParams    Json handleRpcCall
  registerLspRequestHandler "$/lean/rpc/release" Lsp.RpcReleaseParams Json handleRpcRelease

def registerRpcCallHandler (method : Name)
    paramType
    respType
    {paramLspType} [LspEncoding paramType paramLspType] [FromJson paramLspType]
    {respLspType} [LspEncoding respType respLspType] [ToJson respLspType]
    (handler : paramType → RequestM (RequestTask respType)) : IO Unit := do
  if !(← IO.initializing) then
    throw <| IO.userError s!"Failed to register RPC call handler for '{method}': only possible during initialization"
  if (←rpcProcedures.get).contains method then
    throw <| IO.userError s!"Failed to register RPC call handler for '{method}': already registered"

  let wrapper seshId j := do
    let rc ← read

    let t ← RequestM.asTask do
      let paramsLsp ← parseRequestParams paramLspType j
      let some rpcSesh ← rc.rpcSesh?
        | throwThe RequestError { code := JsonRpc.ErrorCode.rpcNotInitialized
                                  message := s!"RPC session not initialized" }
      if seshId ≠ rpcSesh.sessionId then
        throwThe RequestError { code := JsonRpc.ErrorCode.rpcNotInitialized
                                message := s!"Outdated RPC session" }
      @lspDecode paramType paramLspType _ paramsLsp

    let t ← RequestM.bindTask t fun
      | Except.error e => throw e
      | Except.ok ps => handler ps

    RequestM.mapTask t fun
      | Except.error e => throw e
      | Except.ok ret => do
        let retLsp ← @lspEncode respType respLspType _ ret
        return toJson retLsp

  rpcProcedures.modify fun ps => ps.insert method ⟨wrapper⟩

end Lean.Server
