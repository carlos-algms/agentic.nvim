## 1. Type Definitions (`acp_client.lua`)

- [x] 1.1 Add `"switch_mode"` to `ToolKind` alias
- [x] 1.2 Add `agentic.acp.CurrentModeUpdate` class with
  `sessionUpdate = "current_mode_update"` and `currentModeId` string
- [x] 1.3 Add `agentic.acp.CurrentModeUpdate` to
  `agentic.acp.SessionUpdateMessage` alias union

## 2. Handler (`session_manager.lua`)

- [x] 2.1 Add `elseif update.sessionUpdate == "current_mode_update"`
  branch in `SessionManager:_on_session_update`
- [x] 2.2 In that branch: update
  `self.agent_modes.current_mode_id = update.currentModeId`
- [x] 2.3 Call `self:_set_mode_to_chat_header(update.currentModeId)`
  to re-render header
- [x] 2.4 Call `Logger.notify` with new mode ID at `INFO` level
- [x] 2.5 Verify NO `session/set_mode` or `self.agent:set_mode()` is
  called in this path

## 3. Tests

- [x] 3.1 Test: `current_mode_update` updates state, re-renders
  header, notifies user, does not call `agent:set_mode`

## 4. Validation

- [x] 4.1 Run `make validate` - all checks pass
