## 1. Type Definitions (`acp_client.lua`)

- [ ] 1.1 Add `"switch_mode"` to `ToolKind` alias
- [ ] 1.2 Add `agentic.acp.CurrentModeUpdate` class with
  `sessionUpdate = "current_mode_update"` and `currentModeId` string
- [ ] 1.3 Add `agentic.acp.CurrentModeUpdate` to
  `agentic.acp.SessionUpdateMessage` alias union

## 2. Handler (`session_manager.lua`)

- [ ] 2.1 Add `elseif update.sessionUpdate == "current_mode_update"`
  branch in `SessionManager:_on_session_update`
- [ ] 2.2 In that branch: update
  `self.agent_modes.current_mode_id = update.currentModeId`
- [ ] 2.3 Call `self:_set_mode_to_chat_header(update.currentModeId)`
  to re-render header
- [ ] 2.4 Call `Logger.notify` with new mode ID at `INFO` level
- [ ] 2.5 Verify NO `session/set_mode` or `self.agent:set_mode()` is
  called in this path

## 3. Tests

- [ ] 3.1 Test: `current_mode_update` updates
  `agent_modes.current_mode_id`
- [ ] 3.2 Test: `current_mode_update` re-renders chat header
  (calls `_set_mode_to_chat_header`)
- [ ] 3.3 Test: `current_mode_update` calls `Logger.notify` at
  `INFO` level
- [ ] 3.4 Test: unknown `currentModeId` still updates state and
  header (fallback to raw ID)
- [ ] 3.5 Test: no `agent:set_mode` call is made during
  `current_mode_update` handling

## 4. Validation

- [ ] 4.1 Run `make validate` - all checks pass
