# session-persistence Specification

## Purpose
TBD - created by archiving change add-session-persistence. Update Purpose after archive.
## Requirements
### Requirement: Chat History Storage

The system SHALL maintain an in-memory record of all conversation messages
(user prompts, agent responses, tool calls) within a `ChatHistory` class
identified by session ID with creation timestamp.

#### Scenario: Initialize with session ID and timestamp

- **WHEN** ChatHistory is created
- **THEN** it requires session_id parameter, captures current timestamp via
  `os.time()`, and accepts optional dir_path parameter

#### Scenario: Add user message

- **WHEN** user submits a prompt
- **THEN** the message is added to ChatHistory with type `user_message_chunk`

#### Scenario: Add agent response

- **WHEN** agent completes a response
- **THEN** the message is added to ChatHistory with type `agent_message_chunk`

#### Scenario: Add tool call with initial state

- **WHEN** agent invokes a tool
- **THEN** the message is added to ChatHistory with type `tool_call`

#### Scenario: Update tool call in-place

- **WHEN** tool_call_update is received for existing tool call
- **THEN** find the original tool_call message and merge status/body updates

#### Scenario: Extract title from first message

- **WHEN** `get_title()` is called
- **THEN** return text from first `user_message_chunk` truncated to 100
  characters

#### Scenario: Clear history

- **WHEN** user starts a new session via `/new` command
- **THEN** ChatHistory is cleared and all messages removed from memory

### Requirement: Async Disk Persistence

The system SHALL save conversation history to disk asynchronously after each
completed turn using non-blocking I/O operations.

#### Scenario: Save asynchronously with callback

- **WHEN** `save(callback)` is called
- **THEN** write JSON file using `vim.uv.fs_*` APIs without blocking UI

#### Scenario: Wrap JSON encoding in pcall

- **WHEN** serializing data to JSON
- **THEN** wrap `vim.json.encode()` in `pcall` and handle encoding errors

#### Scenario: Save with session metadata

- **WHEN** serializing to JSON succeeds
- **THEN** include `session_id`, `title`, `timestamp`, and `messages` fields

#### Scenario: Include session start timestamp

- **WHEN** serializing to JSON
- **THEN** include `timestamp` field as Unix timestamp from session creation

#### Scenario: Handle save errors gracefully

- **WHEN** async save fails (permissions, disk full, etc.)
- **THEN** log error via Logger.debug and call callback with error

#### Scenario: Skip save on error

- **WHEN** agent response fails with error
- **THEN** history is NOT saved to disk to avoid incomplete turns

#### Scenario: Skip save on cancellation

- **WHEN** user cancels generation before completion
- **THEN** history is NOT saved to disk to avoid incomplete turns

#### Scenario: Restore timestamp on load

- **WHEN** loading session from disk
- **THEN** restore `timestamp` field from JSON to ChatHistory instance

### Requirement: Project-Isolated Storage

The system SHALL generate project-specific folder paths using normalized CWD
path with hash suffix to isolate sessions between projects.

#### Scenario: Normalize CWD path

- **WHEN** generating project folder name
- **THEN** replace slashes, spaces, and colons with underscores using regex
  `[/\\%s:]`

#### Scenario: Append collision-resistant hash

- **WHEN** generating project folder name
- **THEN** compute SHA256 hash of CWD and use first 8 characters as suffix

#### Scenario: Use flat folder structure

- **WHEN** generating file path
- **THEN** path is
  `<cache>/agentic/sessions/<normalized_path_hash>/<session_id>.json`

#### Scenario: Multiple sessions per project

- **WHEN** multiple sessions exist for same project
- **THEN** all sessions stored in same `<normalized_path_hash>` folder with
  different session_id filenames

#### Scenario: Use Neovim cache directory

- **WHEN** determining base storage location
- **THEN** use `vim.fn.stdpath("cache")/agentic/sessions/` as base directory

#### Scenario: Create project folder if missing

- **WHEN** saving for the first time in a project
- **THEN** create `sessions/<normalized_path_hash>/` directory using
  `vim.fn.mkdir(dir, "p")` (recursive)

### Requirement: Session Discovery and Selection

The system SHALL list all available sessions for the current project and allow
users to select one for restoration.

#### Scenario: List sessions for current project

- **WHEN** user calls `restore_session()` without session_id parameter
- **THEN** scan project folder `<cache>/sessions/<normalized_path_hash>/` for
  JSON files

#### Scenario: Read session metadata from files

- **WHEN** scanning session files
- **THEN** read `session_id`, `title`, and `timestamp` from each JSON file

#### Scenario: Format session list for display

- **WHEN** presenting sessions to user
- **THEN** format as `<human_readable_date> - <title>` (e.g., "2024-01-15
  10:30 - Fix authentication bug")

#### Scenario: Show selection UI

- **WHEN** sessions are loaded
- **THEN** call `vim.ui.select()` with formatted session list

#### Scenario: Restore selected session

- **WHEN** user selects a session from list
- **THEN** extract session_id and proceed with restoration

#### Scenario: Handle no sessions found

- **WHEN** project folder is empty or doesn't exist
- **THEN** show notification "No saved sessions found for this project"

#### Scenario: Cancel selection

- **WHEN** user cancels `vim.ui.select()` prompt
- **THEN** abort restoration, return without action

### Requirement: Session Restoration API

The system SHALL provide a public API method to restore previous sessions by
session ID using async load with conflict detection.

#### Scenario: Check for existing session with messages

- **WHEN** user calls `restore_session(session_id)` on tabpage with active
  session
- **THEN** check if current session_id exists and ChatHistory has messages

#### Scenario: Prompt user on conflict

- **WHEN** existing session has session_id and non-empty ChatHistory
- **THEN** show `vim.ui.select()` with options: "Cancel" and "Clear current
  session and restore"

#### Scenario: Cancel restoration

- **WHEN** user selects "Cancel"
- **THEN** abort restoration, keep current session active

#### Scenario: Clear and restore

- **WHEN** user selects "Clear current session and restore"
- **THEN** call `_cancel_session()` on current session, then proceed with
  restoration

#### Scenario: Restore on empty tabpage

- **WHEN** tabpage has no active session or ChatHistory is empty
- **THEN** proceed with restoration immediately without prompting

#### Scenario: Restore via public API with async load

- **WHEN** restoration is confirmed (no conflict or user approved)
- **THEN** call `ChatHistory.load(session_id, nil, callback)` asynchronously

#### Scenario: Create session after load completes

- **WHEN** async load callback receives ChatHistory
- **THEN** create SessionManager and call `restore_from_history(chat_history)`

#### Scenario: Handle missing session file

- **WHEN** restoring session with non-existent session_id
- **THEN** callback receives nil, log warning, don't create session

#### Scenario: Handle corrupted file

- **WHEN** session file exists but contains invalid JSON
- **THEN** wrap `vim.json.decode()` in `pcall`, callback receives nil, log
  warning, don't create session

### Requirement: Message Replay

The system SHALL replay all stored messages to the chat widget with
message-type-specific rendering.

#### Scenario: Replay user and agent messages

- **WHEN** message type is `user_message_chunk` or `agent_message_chunk`
- **THEN** call `message_writer:write_message(msg)`

#### Scenario: Replay thought chunks

- **WHEN** message type is `agent_thought_chunk`
- **THEN** call `message_writer:write_message_chunk(msg)`

#### Scenario: Replay tool calls with final state

- **WHEN** message type is `tool_call`
- **THEN** call `message_writer:write_tool_call_block(msg)` with merged final
  state

#### Scenario: No agent communication during replay

- **WHEN** replaying messages to UI
- **THEN** messages are NOT sent to agent immediately (only UI rendering)

#### Scenario: Show restored widget

- **WHEN** restoration completes successfully
- **THEN** chat widget is shown with all restored messages visible

### Requirement: History Send on First Submit

The system SHALL send all restored messages to the agent when user submits
their first prompt after restoration.

#### Scenario: Set flag on restoration

- **WHEN** `restore_from_history()` is called
- **THEN** set `_needs_history_send` flag to true

#### Scenario: Prepend history on first submit

- **WHEN** user submits first prompt and `_needs_history_send` is true
- **THEN** extract `content` from all stored messages and prepend to prompt
  array

#### Scenario: Current prompt is last

- **WHEN** prepending history to prompt
- **THEN** ensure current user input is the last element in the array

#### Scenario: Clear flag after send

- **WHEN** history is sent with first prompt
- **THEN** clear `_needs_history_send` flag so subsequent prompts don't include
  history

#### Scenario: Only send content field

- **WHEN** converting stored messages for agent
- **THEN** extract only the `content` field from each `SessionUpdateMessage`

### Requirement: Message Format Preservation

The system SHALL store messages in ACP protocol format
(`SessionUpdateMessage`) without transformation to preserve all metadata.

#### Scenario: Store raw ACP messages

- **WHEN** saving history to disk
- **THEN** messages are serialized as-is from ACP protocol types

#### Scenario: Preserve message types

- **WHEN** loading history from disk
- **THEN** message types (`user_message_chunk`, `agent_message_chunk`,
  `agent_thought_chunk`, `tool_call`) are preserved exactly

#### Scenario: Tool call updates merged

- **WHEN** saving history to disk
- **THEN** tool_call messages contain final merged state, tool_call_update
  messages are NOT stored separately

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

