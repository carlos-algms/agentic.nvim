# ACP Transport Framing and Process Lifecycle

## Stdio framing

Provider stdout is newline-delimited JSON-RPC, but reads arrive in arbitrary
chunks.

```text
chunk 1:  ...{"jsonrpc":"2.0","i
chunk 2:  d":1,...}\n{"jsonrpc":"2.0","method
```

Transport buffering:

```text
chunks = chunks .. data
lines  = split(chunks, "\n")
chunks = lines[#lines]
for i = 1, #lines - 1 do
    dispatch(decode(trim(lines[i])))
end
```

Invariants:

- `chunks` keeps the unterminated tail across reads.
- A read can dispatch zero or more complete messages.
- Empty or whitespace-only lines are skipped.
- JSON decode failures call `Logger.notify` and continue.
- Decode goes through `ACPTransport.decode_line`, which passes
  `{ luanil = { object = true, array = true } }`. JSON `null` becomes Lua `nil`,
  not `vim.NIL`.

Why preserved: large payloads routinely exceed a single pipe read. Dropping the
partial tail turns multi-chunk messages into JSON parse errors and message loss.

Why `luanil`: `vim.NIL` is truthy userdata. A consumer that truthiness-guards a
decoded field (`if x then ipairs(x)` or `x.field`) crashes when the provider
sends explicit `null` instead of omitting the field. This crashed session
restore in `ACPClient:__build_tool_call_message` (`ipairs` on userdata).
Removing the opt re-crashes every such consumer (tool-call content/locations,
plan entries, availableCommands, configOptions, modes).

Regression:

- `lua/agentic/acp/acp_transport.test.lua::"decodes JSON null as nil, not vim.NIL"`

## Subprocess lifecycle

- ACP children spawn with `uv.spawn({ detached = true })`.
- On POSIX, `transport:stop` signals the process group with `uv.kill(-pid, 15)`
  and then `uv.kill(-pid, 9)`.
- Windows falls back to `process:kill`.
- This catches wrappers that do not forward signals.
- Tradeoff: descendants can outlive a hard `kill -9` of nvim.

Regression:

- `lua/agentic/acp/acp_transport.test.lua::"kills descendant processes when wrapper does not forward signals"`
