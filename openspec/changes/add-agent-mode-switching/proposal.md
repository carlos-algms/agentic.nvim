# Change: Add agent-initiated mode switching support

## Why

Agents can switch session modes mid-turn via `session/update` with
`current_mode_update`. The plugin ignores this notification today,
so agent-initiated mode changes are silently dropped. Users see stale
mode labels and the UI never reacts to mode transitions (e.g.,
plan -> code).

Additionally, `"switch_mode"` is a valid ACP tool call `kind` but is
missing from the `ToolKind` alias, causing type checker gaps.

## What Changes

- Handle `current_mode_update` in `SessionManager:_on_session_update`
  - Update `AgentModes.current_mode_id` (internal state only)
  - Re-render chat header via `_set_mode_to_chat_header`
  - Notify user via `Logger.notify`
  - NO `session/set_mode` sent back to agent
- Add `CurrentModeUpdate` type to `SessionUpdateMessage` union in
  `acp_client.lua`
- Add `"switch_mode"` to `ToolKind` alias in `acp_client.lua`

## Impact

- Affected specs: new `agent-mode-switching` capability
- Affected code:
  - `lua/agentic/acp/acp_client.lua` - `CurrentModeUpdate` type,
    `SessionUpdateMessage` union, `ToolKind` alias
  - `lua/agentic/session_manager.lua` - `_on_session_update` new
    `elseif` branch
