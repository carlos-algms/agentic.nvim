## ADDED Requirements

### Requirement: Buffer reload on file-related tool call completion

The system SHALL trigger `vim.cmd.checktime()` when a provider
completes a file-mutating tool call (`edit`, `create`, `write`,
`delete`, `move` kinds) to reload any buffers whose backing
files changed on disk.

#### Scenario: Edit tool call completes successfully

- **WHEN** a `tool_call_update` arrives with `status = "completed"`
  and the original tool call had `kind = "edit"`
- **THEN** the system calls `vim.cmd.checktime()`

#### Scenario: Create tool call completes successfully

- **WHEN** a `tool_call_update` arrives with `status = "completed"`
  and the original tool call had `kind = "create"`
- **THEN** the system calls `vim.cmd.checktime()`

#### Scenario: Delete tool call completes successfully

- **WHEN** a `tool_call_update` arrives with `status = "completed"`
  and the original tool call had `kind = "delete"`
- **THEN** the system calls `vim.cmd.checktime()`

#### Scenario: Move tool call completes successfully

- **WHEN** a `tool_call_update` arrives with `status = "completed"`
  and the original tool call had `kind = "move"`
- **THEN** the system calls `vim.cmd.checktime()`

#### Scenario: Failed tool call does not trigger reload

- **WHEN** a `tool_call_update` arrives with `status = "failed"`
  and any file-mutating kind
- **THEN** the system does NOT call `checktime()`

#### Scenario: Non-file tool call does not trigger reload

- **WHEN** a `tool_call_update` arrives with `status = "completed"`
  and `kind = "think"` or `kind = "search"` or `kind = "read"`
  or other non-mutating kind
- **THEN** the system does NOT call `checktime()`

#### Scenario: Missing kind in tool call tracker

- **WHEN** a `tool_call_update` arrives with `status = "completed"`
  but the tool call tracker has no `kind` field
- **THEN** the system does NOT call `checktime()`
- **AND** logs a debug message

### Requirement: Force-reload buffers without user prompt

The system SHALL register a `FileChangedShell` autocommand that
sets `vim.v.fcs_choice = "reload"` so that buffers with unsaved
changes are silently reloaded when `checktime` detects disk
changes. This matches Cursor/Zed behavior where agent changes
always take precedence.

#### Scenario: Buffer has unsaved changes when agent edits file

- **WHEN** a buffer has unsaved modifications
- **AND** the agent writes a new version of the file to disk
- **AND** `checktime()` detects the change
- **THEN** the buffer is silently reloaded from disk without
  prompting the user

#### Scenario: Buffer has no unsaved changes

- **WHEN** a buffer has no unsaved modifications
- **AND** the agent writes a new version of the file to disk
- **AND** `checktime()` detects the change
- **THEN** the buffer is silently reloaded from disk (standard
  `autoread` behavior)

### Requirement: FS capability declaration disabled

The ACP client SHALL announce `readTextFile: false` and
`writeTextFile: false` during initialization so providers
handle file I/O directly.

#### Scenario: Initialize with FS capabilities disabled

- **WHEN** the client sends the `initialize` request
- **THEN** `clientCapabilities.fs.readTextFile` is `false`
- **AND** `clientCapabilities.fs.writeTextFile` is `false`

### Requirement: Remove fs request handlers

The ACP client SHALL NOT process `fs/read_text_file` or
`fs/write_text_file` requests but SHALL keep notification
routing branches to log warnings (avoiding "unknown method"
noise).

#### Scenario: Provider sends fs/read_text_file despite disabled capability

- **WHEN** the client receives a `fs/read_text_file` notification
- **THEN** the system logs a warning about unexpected fs request
- **AND** does NOT process the request

#### Scenario: Provider sends fs/write_text_file despite disabled capability

- **WHEN** the client receives a `fs/write_text_file` notification
- **THEN** the system logs a warning about unexpected fs request
- **AND** does NOT process the request
