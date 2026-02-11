## ADDED Requirements

### Requirement: Current Mode Update Type Definition

The system SHALL define a `CurrentModeUpdate` type as part of the
`SessionUpdateMessage` union with `sessionUpdate` value
`"current_mode_update"` and a required `currentModeId` string field,
matching the ACP protocol schema.

#### Scenario: Type included in SessionUpdateMessage alias

- **WHEN** a `session/update` notification arrives with
  `sessionUpdate` = `"current_mode_update"`
- **THEN** the update SHALL be assignable to
  `agentic.acp.SessionUpdateMessage`

### Requirement: Switch Mode Tool Kind

The system SHALL include `"switch_mode"` in the `ToolKind` alias so
that tool calls with `kind = "switch_mode"` pass type checking
without diagnostics.

#### Scenario: Tool call with switch_mode kind

- **WHEN** an agent sends a `tool_call` with `kind = "switch_mode"`
- **THEN** the kind SHALL match the `agentic.acp.ToolKind` alias
- **AND** the tool call SHALL flow through the existing tool_call
  dispatch pipeline without type warnings

### Requirement: Agent-Initiated Mode Switch Handling

The system SHALL handle `current_mode_update` notifications in
`SessionManager:_on_session_update` by updating internal mode state
and re-rendering the chat header. The system SHALL NOT send
`session/set_mode` back to the agent in response to this
notification.

#### Scenario: Agent switches from plan to code mode

- **WHEN** the agent sends `current_mode_update` with
  `currentModeId = "code"` while current mode is `"plan"`
- **THEN** `AgentModes.current_mode_id` SHALL be `"code"`
- **AND** the chat header SHALL re-render with the new mode
- **AND** no `session/set_mode` request SHALL be sent to the agent

#### Scenario: Agent switches to a mode with known name

- **WHEN** the agent sends `current_mode_update` with a
  `currentModeId` that exists in `AgentModes._modes`
- **THEN** the chat header SHALL display the mode's `name` property

### Requirement: User Notification on Agent Mode Change

The system SHALL notify the user via `Logger.notify` at `INFO` level
when the agent changes the session mode, including the new mode
identifier.

#### Scenario: Notification on agent-initiated mode switch

- **WHEN** the agent sends a `current_mode_update` notification
- **THEN** `Logger.notify` SHALL be called with a message containing
  the new mode ID at `vim.log.levels.INFO`