# Implementation Tasks

## Phase 1: ChatHistory Class Skeleton + Path Generation (TDD)

- [x] 1.1 Create class skeleton
  - [x] 1.1.1 Create `lua/agentic/chat_history.lua` with empty class
  - [x] 1.1.2 Add constructor accepting `session_id` and optional `dir_path`
  - [x] 1.1.3 Store `timestamp` as `os.time()`
  - [x] 1.1.4 Initialize empty `messages = {}`
  - [x] 1.1.5 Add stub methods: `_get_project_folder()`, `_get_file_path()`
- [x] 1.2 Write path generation tests FIRST
  - [x] 1.2.1 Create `lua/agentic/chat_history.test.lua`
  - [x] 1.2.2 Test `_get_project_folder()`: normal path, spaces, colons, Unicode
  - [x] 1.2.3 Test SHA256 hash is 8 chars
  - [x] 1.2.4 Test `_get_file_path()`: verify full path structure
  - [x] 1.2.5 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **EXPECT FAILURES**
- [x] 1.3 Implement path generation to pass tests
  - [x] 1.3.1 Implement `_get_project_folder()` with `[/\\%s:]` regex + SHA256
  - [x] 1.3.2 Implement `_get_file_path()` with full cache path
  - [x] 1.3.3 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **VERIFY PASS**

**CHECKPOINT:** Path generation tests pass

## Phase 2: Message Operations (TDD)

- [x] 2.1 Write message operation tests FIRST
  - [x] 2.1.1 Test `add_message()`: adds to messages array
  - [x] 2.1.2 Test `update_tool_call()`: finds and merges tool_call by ID
  - [x] 2.1.3 Test `get_messages()`: returns all messages
  - [x] 2.1.4 Test `get_title()`: extracts first user message, truncates to 100
  - [x] 2.1.5 Test `clear()`: empties messages array
  - [x] 2.1.6 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **EXPECT FAILURES**
- [x] 2.2 Implement message operations to pass tests
  - [x] 2.2.1 Implement `add_message(msg)` - append to `self.messages`
  - [x] 2.2.2 Implement `update_tool_call(tool_call_id, update)` - find and
    merge
  - [x] 2.2.3 Implement `get_messages()` - return `self.messages`
  - [x] 2.2.4 Implement `get_title()` - find first user_message_chunk, truncate
  - [x] 2.2.5 Implement `clear()` - `self.messages = {}`
  - [x] 2.2.6 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **VERIFY PASS**

**CHECKPOINT:** All message operation tests pass

## Phase 3: Async Save (TDD)

- [x] 3.1 Write save tests FIRST
  - [x] 3.1.1 Test `save()`: creates JSON file with correct structure
  - [x] 3.1.2 Test pcall wrapper handles encoding errors
  - [x] 3.1.3 Test directory creation (mkdir with "p")
  - [x] 3.1.4 Test async callback is called
  - [x] 3.1.5 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **EXPECT FAILURES**
- [x] 3.2 Implement save to pass tests
  - [x] 3.2.1 Implement `save(callback)` method
  - [x] 3.2.2 Add `vim.fn.mkdir(dir, "p")` for directory creation
  - [x] 3.2.3 Wrap `vim.json.encode()` in pcall
  - [x] 3.2.4 Serialize `{ session_id, title, timestamp, messages }`
  - [x] 3.2.5 Write async via `vim.uv.fs_open` + `fs_write` + `fs_close`
  - [x] 3.2.6 Handle errors, call callback
  - [x] 3.2.7 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **VERIFY PASS**

**CHECKPOINT:** Save tests pass, manually inspect
`~/.cache/nvim/agentic/sessions/<hash>/*.json`

## Phase 4: Async Load (TDD)

- [x] 4.1 Write load tests FIRST
  - [x] 4.1.1 Test `load()`: reads JSON and restores ChatHistory instance
  - [x] 4.1.2 Test restores session_id, title, timestamp, messages
  - [x] 4.1.3 Test pcall wrapper handles corrupted JSON
  - [x] 4.1.4 Test missing file returns nil
  - [x] 4.1.5 Test async callback is called
  - [x] 4.1.6 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **EXPECT FAILURES**
- [x] 4.2 Implement load to pass tests
  - [x] 4.2.1 Implement `ChatHistory.load(session_id, dir_path, callback)`
    static
  - [x] 4.2.2 Build file path using same `_get_project_folder()` logic
  - [x] 4.2.3 Read async via `vim.uv.fs_open` + `fs_read` + `fs_close`
  - [x] 4.2.4 Wrap `vim.json.decode()` in pcall
  - [x] 4.2.5 Create ChatHistory instance with restored data
  - [x] 4.2.6 Handle missing/corrupted files (callback with nil)
  - [x] 4.2.7 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **VERIFY PASS**

**CHECKPOINT:** Full save/load round-trip tests pass

## Phase 5: SessionManager Save Integration

- [x] 5.1 Integrate ChatHistory into SessionManager
  - [x] 5.1.1 Add `chat_history` field to SessionManager class definition
  - [x] 5.1.2 Initialize `ChatHistory:new(session_id)` in `new_session()`
    callback
  - [x] 5.1.3 Store user messages in `_handle_input_submit()` via
    `chat_history:add_message()`
  - [x] 5.1.4 Store agent messages in `_on_session_update()` for
    agent_message_chunk and agent_thought_chunk
  - [x] 5.1.5 Store tool_call in `on_tool_call` handler via
    `chat_history:add_message()`
  - [x] 5.1.6 Update tool_call in `on_tool_call_update` handler via
    `chat_history:update_tool_call()`
  - [x] 5.1.7 Call `chat_history:save(callback)` after full turn (only if no
    error/cancel)
  - [x] 5.1.8 Clear history in `_cancel_session()` via `chat_history:clear()`

**CHECKPOINT:** Manual test - start session, have conversation with tool calls,
verify JSON saved to `~/.cache/nvim/agentic/sessions/<hash>/<session_id>.json`

## Phase 6: Message Replay (TDD)

- [x] 6.1 Implement replay (tests skipped - implementation verified via
  integration)
  - [x] 6.2.1 Add `_replay_messages(messages)` private method to SessionManager
  - [x] 6.2.2 Loop through messages with type checks
  - [x] 6.2.3 Call appropriate MessageWriter methods
  - [x] 6.2.4 Add `restore_from_history(chat_history)` method
  - [x] 6.2.5 Call `_replay_messages()` and set `_needs_history_send = true`

**CHECKPOINT:** Replay implemented

## Phase 7: History Send on First Submit (TDD)

- [x] 7.1 Implement history send (tests skipped - implementation verified via
  integration)
  - [x] 7.2.1 Add `_needs_history_send` field (default false)
  - [x] 7.2.2 Check flag in `_handle_input_submit()`
  - [x] 7.2.3 Extract `content` from all messages
  - [x] 7.2.4 Prepend to prompt array before current input
  - [x] 7.2.5 Clear flag after send

**CHECKPOINT:** History send implemented

## Phase 8: Public API with Conflict Detection (TDD)

- [x] 8.1 Implement restore_session
  - [x] 8.2.1 Add `Agentic.restore_session(session_id, opts)` to init.lua
  - [x] 8.2.2 Get SessionManager for current tab via SessionRegistry
  - [x] 8.2.3 Check if session exists AND has session_id AND ChatHistory has
    messages
  - [x] 8.2.4 If conflict exists, call `vim.ui.select()` with options: "Cancel",
    "Clear current session and restore"
  - [x] 8.2.5 Handle "Cancel" - return early
  - [x] 8.2.6 Handle "Clear current session and restore" - cancel and restore
  - [x] 8.2.7 Call `ChatHistory.load(session_id, nil, callback)` async
  - [x] 8.2.8 In callback, get/create SessionManager and call
    `restore_from_history()`
  - [x] 8.2.9 Show widget after restoration
  - [x] 8.2.10 Add `Agentic.list_sessions(callback)` for session discovery

**CHECKPOINT:** Full API implemented including conflict handling

## Phase 9: End-to-End Validation

- [x] 9.1 Manual end-to-end test
  - [x] 9.1.1 Start fresh session, have multi-turn conversation with tool calls
  - [x] 9.1.2 Note the session_id from chat header
  - [x] 9.1.3 Exit Neovim completely
  - [x] 9.1.4 Restart Neovim
  - [x] 9.1.5 Call `require('agentic').restore_session('<session_id>')`
  - [x] 9.1.6 Verify all messages/tool calls visible in UI
  - [x] 9.1.7 Submit new prompt, verify agent has conversation context
- [x] 9.2 Edge case testing
  - [x] 9.2.1 Test conflict prompt with existing session
  - [x] 9.2.2 Test multiple sessions in same project folder
  - [x] 9.2.3 Test different projects get different folders
  - [x] 9.2.4 Test special chars in paths (spaces, colons)
  - [x] 9.2.5 Test restore non-existent session (should log warning)
- [x] 9.3 Run full validation suite
  - [x] 9.3.1 `make validate` (format, luals, luacheck, tests)
  - [x] 9.3.2 Fix any type checking errors
  - [x] 9.3.3 Fix any linting warnings

**FINAL CHECKPOINT:** All tests pass, `make validate` passes
