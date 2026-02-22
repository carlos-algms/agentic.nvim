## ADDED Requirements

### Requirement: In-flight provider switch

The system SHALL allow switching the ACP provider for the current
tabpage session without clearing the chat widget or losing chat
history. The public API accepts an optional opts table with a
`provider` field. If `opts.provider` is set, `Config.provider` is
updated and the switch proceeds directly. If nil or omitted, the
provider selector picker is shown, `Config.provider` is set on
selection, and no-op on cancel. All accumulated messages MUST be
re-sent to the new provider on the next user prompt.

#### Scenario: Switch with explicit provider in opts

- **WHEN** user calls `switch_provider` with `opts.provider` set
- **THEN** `Config.provider` is updated and the switch proceeds
  directly without showing a picker

#### Scenario: Switch without provider shows selector

- **WHEN** user calls `switch_provider` without `opts.provider`
- **THEN** the provider selector picker is shown,
  `Config.provider` is set on selection, and the switch proceeds

#### Scenario: Selector cancelled

- **WHEN** user cancels the provider selector
- **THEN** no switch occurs and the current session is unaffected

#### Scenario: Chat display preserved

- **WHEN** provider switch completes
- **THEN** the chat buffer content remains unchanged and a new
  session header is appended showing the new provider name, new
  session ID, and current timestamp

#### Scenario: User context preserved

- **WHEN** provider switch completes
- **THEN** file list and code selection remain intact

#### Scenario: Provider-specific state cleared

- **WHEN** provider switch completes
- **THEN** todo list is cleared and the old ACP session is
  cancelled

#### Scenario: History re-sent on first prompt

- **WHEN** user submits a prompt after switching providers
- **THEN** all accumulated messages are prepended to the prompt
  via `_schedule_history_resend` and system info is re-sent to
  the new provider

#### Scenario: Blocked during generation

- **WHEN** user attempts to switch while `is_generating` is true
- **THEN** the switch is rejected with a user notification

#### Scenario: New session on target provider

- **WHEN** provider switch is initiated
- **THEN** a new `AgentInstance` is obtained for `Config.provider`
  and `new_session` is called, which handles ACP session creation,
  modes, slash commands, and welcome header

### Requirement: Scheduled history resend

The system SHALL provide a `_schedule_history_resend(messages)`
method that flags the given messages to be prepended on the next
prompt submit. Callers set `_is_first_message` independently since
the intent differs between provider switch (`true`) and session
restore (`false`).

#### Scenario: Flags set correctly

- **WHEN** `_schedule_history_resend(messages)` is called
- **THEN** `_needs_history_send` is true and `_history_to_send`
  references the provided messages array

#### Scenario: Caller controls first-message flag

- **WHEN** `switch_provider` calls `_schedule_history_resend`
- **THEN** it sets `_is_first_message = true` separately
- **WHEN** `restore_from_history` calls `_schedule_history_resend`
- **THEN** it sets `_is_first_message = false` separately

#### Scenario: Consumed on next prompt

- **WHEN** user submits a prompt with `_needs_history_send` true
- **THEN** history is prepended via `prepend_restored_messages`
  and the flag is cleared

### Requirement: Welcome header helper

The system SHALL provide a reusable helper function for generating
session welcome headers, used by both new session creation and
provider switching.

#### Scenario: Consistent format

- **WHEN** a new session is created or a provider switch occurs
- **THEN** the welcome header follows the format
  `# Agentic - <provider_name> - <session_id>` with timestamp

#### Scenario: Single source

- **WHEN** welcome header logic is modified
- **THEN** both new session and provider switch paths reflect
  the change
