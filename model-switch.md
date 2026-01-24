# ACP Model Selection

Model selection is **not part of the ACP specification**. Each provider implements it differently.

## Summary

| Provider | CLI Flag | Runtime ACP Method |
|----------|----------|-------------------|
| Claude | ❌ | `unstable_setSessionModel` |
| Gemini | `--model` | ❌ |
| Codex | `-c model="..."` | `set_session_config_option` |
| OpenCode | `--model` / `-m` | `session/set_model` |
| Cursor | ❌ | `session/setModel` |

**Gemini is the only provider without runtime model switching.**

## CLI Examples

```bash
# Gemini (startup only)
gemini --experimental-acp --model gemini-2.5-pro

# Codex
codex-acp -c model="o3"

# OpenCode
opencode --model anthropic/claude-sonnet-4-5
```

## ACP Runtime Examples

### Claude

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "unstable_setSessionModel",
  "params": {
    "sessionId": "sess_abc123",
    "modelId": "claude-opus-4-5-20251101"
  }
}
```

### Codex

Follows draft RFC [session-config-options](https://agentclientprotocol.com/rfds/session-config-options):

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "set_session_config_option",
  "params": {
    "session_id": "sess_abc123",
    "config_id": "model",
    "value": "o3"
  }
}
```

### OpenCode

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "session/set_model",
  "params": {
    "sessionId": "sess_abc123",
    "modelId": "anthropic/claude-sonnet-4-5"
  }
}
```

### Cursor

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "session/setModel",
  "params": {
    "sessionId": "sess_abc123",
    "modelId": "sonnet-4-thinking"
  }
}
```

## Notes

- `claude-code-acp` ignores `ANTHROPIC_MODEL` env var - hardcodes `models[0]`
- Codex's `set_session_config_option` also supports `mode` and `reasoning_effort`
- Draft RFC proposes `session/set_config_option` as future standard

---

## agentic.nvim Implementation Analysis

### Current Mode Switching (agent_modes.lua)

The existing `AgentModes` class provides a pattern for model switching:

1. **Initialization**: `SessionManager` creates `AgentModes` with buffers and a callback
2. **Data source**: `session/new` response includes `modes` with `availableModes[]` and `currentModeId`
3. **UI**: `<S-Tab>` triggers `vim.ui.select` with available modes
4. **ACP call**: Callback invokes `ACPClient:set_mode(session_id, mode_id, callback)`

```lua
-- agent_modes.lua pattern
AgentModes:new(buffers, set_mode_callback)
AgentModes:set_modes(modes_info)  -- from session/new response
AgentModes:show_mode_selector()   -- vim.ui.select
```

### Model Data Already Available

`session/new` response type already includes models:

```lua
--- @class agentic.acp.SessionCreationResponse
--- @field sessionId string
--- @field modes? agentic.acp.ModesInfo
--- @field models? agentic.acp.ModelsInfo  -- already defined!

--- @class agentic.acp.ModelsInfo
--- @field availableModels agentic.acp.Model[]
--- @field currentModelId string

--- @class agentic.acp.Model
--- @field modelId string
--- @field name string
--- @field description string
```

### Implementation Path

To add model switching, mirror `AgentModes` pattern:

1. **Create `AgentModels` class** similar to `agent_modes.lua`
2. **Add `ACPClient:set_model()` method** - provider-specific (see table above)
3. **Handle in `SessionManager:new_session()`** when `response.models` exists
4. **Bind keymap** (e.g., `<C-m>` or similar)

### Provider-Specific `set_model` Methods

Each adapter needs its own implementation:

```lua
-- Base ACPClient (won't work for all providers)
function ACPClient:set_model(session_id, model_id, callback)
    -- Default: no-op or error
end

-- Claude adapter override
function ClaudeACPAdapter:set_model(session_id, model_id, callback)
    return self:_send_request("unstable_setSessionModel", {
        sessionId = session_id,
        modelId = model_id,
    }, callback)
end

-- Codex adapter override
function CodexACPAdapter:set_model(session_id, model_id, callback)
    return self:_send_request("set_session_config_option", {
        session_id = session_id,
        config_id = "model",
        value = model_id,
    }, callback)
end

-- Gemini: no runtime method, would need process restart
```

### Gemini Limitation

Gemini requires `--model` at CLI startup. Options:
- Restart subprocess with new `--model` arg (disruptive)
- Show warning that model switching not supported
- Pre-configure model in provider config
