# Implementation Tasks

## Phase 1: ChatHistory Class Skeleton + Path Generation (TDD)

- [ ] 1.1 Create class skeleton
  - [ ] 1.1.1 Create `lua/agentic/chat_history.lua` with empty class
  - [ ] 1.1.2 Add constructor accepting `session_id` and optional `dir_path`
  - [ ] 1.1.3 Store `timestamp` as `os.time()`
  - [ ] 1.1.4 Initialize empty `messages = {}`
  - [ ] 1.1.5 Add stub methods: `_get_project_folder()`, `_get_file_path()`
- [ ] 1.2 Write path generation tests FIRST
  - [ ] 1.2.1 Create `lua/agentic/chat_history.test.lua`
  - [ ] 1.2.2 Test `_get_project_folder()`: normal path, spaces, colons, Unicode
  - [ ] 1.2.3 Test SHA256 hash is 8 chars
  - [ ] 1.2.4 Test `_get_file_path()`: verify full path structure
  - [ ] 1.2.5 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **EXPECT FAILURES**
- [ ] 1.3 Implement path generation to pass tests
  - [ ] 1.3.1 Implement `_get_project_folder()` with `[/\\%s:]` regex + SHA256
  - [ ] 1.3.2 Implement `_get_file_path()` with full cache path
  - [ ] 1.3.3 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **VERIFY PASS**

**CHECKPOINT:** Path generation tests pass

## Phase 2: Message Operations (TDD)

- [ ] 2.1 Write message operation tests FIRST
  - [ ] 2.1.1 Test `add_message()`: adds to messages array
  - [ ] 2.1.2 Test `update_tool_call()`: finds and merges tool_call by ID
  - [ ] 2.1.3 Test `get_messages()`: returns all messages
  - [ ] 2.1.4 Test `get_title()`: extracts first user message, truncates to 100
  - [ ] 2.1.5 Test `clear()`: empties messages array
  - [ ] 2.1.6 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **EXPECT FAILURES**
- [ ] 2.2 Implement message operations to pass tests
  - [ ] 2.2.1 Implement `add_message(msg)` - append to `self.messages`
  - [ ] 2.2.2 Implement `update_tool_call(tool_call_id, update)` - find and
    merge
  - [ ] 2.2.3 Implement `get_messages()` - return `self.messages`
  - [ ] 2.2.4 Implement `get_title()` - find first user_message_chunk, truncate
  - [ ] 2.2.5 Implement `clear()` - `self.messages = {}`
  - [ ] 2.2.6 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **VERIFY PASS**

**CHECKPOINT:** All message operation tests pass

## Phase 3: Async Save (TDD)

- [ ] 3.1 Write save tests FIRST
  - [ ] 3.1.1 Test `save()`: creates JSON file with correct structure
  - [ ] 3.1.2 Test pcall wrapper handles encoding errors
  - [ ] 3.1.3 Test directory creation (mkdir with "p")
  - [ ] 3.1.4 Test async callback is called
  - [ ] 3.1.5 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **EXPECT FAILURES**
- [ ] 3.2 Implement save to pass tests
  - [ ] 3.2.1 Implement `save(callback)` method
  - [ ] 3.2.2 Add `vim.fn.mkdir(dir, "p")` for directory creation
  - [ ] 3.2.3 Wrap `vim.json.encode()` in pcall
  - [ ] 3.2.4 Serialize `{ session_id, title, timestamp, messages }`
  - [ ] 3.2.5 Write async via `vim.uv.fs_open` + `fs_write` + `fs_close`
  - [ ] 3.2.6 Handle errors, call callback
  - [ ] 3.2.7 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **VERIFY PASS**

**CHECKPOINT:** Save tests pass, manually inspect
`~/.cache/nvim/agentic/sessions/<hash>/*.json`

## Phase 4: Async Load (TDD)

- [ ] 4.1 Write load tests FIRST
  - [ ] 4.1.1 Test `load()`: reads JSON and restores ChatHistory instance
  - [ ] 4.1.2 Test restores session_id, title, timestamp, messages
  - [ ] 4.1.3 Test pcall wrapper handles corrupted JSON
  - [ ] 4.1.4 Test missing file returns nil
  - [ ] 4.1.5 Test async callback is called
  - [ ] 4.1.6 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **EXPECT FAILURES**
- [ ] 4.2 Implement load to pass tests
  - [ ] 4.2.1 Implement `ChatHistory.load(session_id, dir_path, callback)`
    static
  - [ ] 4.2.2 Build file path using same `_get_project_folder()` logic
  - [ ] 4.2.3 Read async via `vim.uv.fs_open` + `fs_read` + `fs_close`
  - [ ] 4.2.4 Wrap `vim.json.decode()` in pcall
  - [ ] 4.2.5 Create ChatHistory instance with restored data
  - [ ] 4.2.6 Handle missing/corrupted files (callback with nil)
  - [ ] 4.2.7 Run `make test-file FILE=lua/agentic/chat_history.test.lua` -
    **VERIFY PASS**

**CHECKPOINT:** Full save/load round-trip tests pass

## Phase 5: SessionManager Save Integration

- [ ] 5.1 Integrate ChatHistory into SessionManager
  - [ ] 5.1.1 Add `chat_history` field to SessionManager class definition
  - [ ] 5.1.2 Initialize `ChatHistory:new(session_id)` in `new_session()`
    callback
  - [ ] 5.1.3 Store user messages in `_handle_input_submit()` via
    `chat_history:add_message()`
  - [ ] 5.1.4 Store agent messages in prompt callback after `is_generating =
    false`
  - [ ] 5.1.5 Store tool_call in `on_tool_call` handler via
    `chat_history:add_message()`
  - [ ] 5.1.6 Update tool_call in `on_tool_call_update` handler via
    `chat_history:update_tool_call()`
  - [ ] 5.1.7 Call `chat_history:save(callback)` after full turn (only if no
    error/cancel)
  - [ ] 5.1.8 Clear history in `_cancel_session()` via `chat_history:clear()`

**CHECKPOINT:** Manual test - start session, have conversation with tool calls,
verify JSON saved to `~/.cache/nvim/agentic/sessions/<hash>/<session_id>.json`

## Phase 6: Message Replay (TDD)

- [ ] 6.1 Write replay tests FIRST
  - [ ] 6.1.1 Create test file or add to existing SessionManager tests
  - [ ] 6.1.2 Test `_replay_messages()`: calls MessageWriter methods correctly
  - [ ] 6.1.3 Test user/agent messages call `write_message()`
  - [ ] 6.1.4 Test thought chunks call `write_message_chunk()`
  - [ ] 6.1.5 Test tool_call calls `write_tool_call_block()`
  - [ ] 6.1.6 Run tests - **EXPECT FAILURES**
- [ ] 6.2 Implement replay to pass tests
  - [ ] 6.2.1 Add `_replay_messages(messages)` private method to SessionManager
  - [ ] 6.2.2 Loop through messages with type checks
  - [ ] 6.2.3 Call appropriate MessageWriter methods
  - [ ] 6.2.4 Add `restore_from_history(chat_history)` method
  - [ ] 6.2.5 Call `_replay_messages()` and set `_needs_history_send = true`
  - [ ] 6.2.6 Run tests - **VERIFY PASS**

**CHECKPOINT:** Replay tests pass

## Phase 7: History Send on First Submit (TDD)

- [ ] 7.1 Write history send tests FIRST
  - [ ] 7.1.1 Test `_needs_history_send` flag controls behavior
  - [ ] 7.1.2 Test history content prepended to prompt array
  - [ ] 7.1.3 Test current user input is last in array
  - [ ] 7.1.4 Test flag cleared after first submit
  - [ ] 7.1.5 Run tests - **EXPECT FAILURES**
- [ ] 7.2 Implement history send to pass tests
  - [ ] 7.2.1 Add `_needs_history_send` field (default false)
  - [ ] 7.2.2 Check flag in `_handle_input_submit()`
  - [ ] 7.2.3 Extract `content` from all messages
  - [ ] 7.2.4 Prepend to prompt array before current input
  - [ ] 7.2.5 Clear flag after send
  - [ ] 7.2.6 Run tests - **VERIFY PASS**

**CHECKPOINT:** History send tests pass

## Phase 8: Public API with Conflict Detection (TDD)

- [ ] 8.1 Write restore_session tests FIRST
  - [ ] 8.1.1 Test restore on empty tabpage proceeds immediately
  - [ ] 8.1.2 Test restore on tabpage with empty ChatHistory proceeds
    immediately
  - [ ] 8.1.3 Test restore with existing session_id and messages prompts user
  - [ ] 8.1.4 Test user selects "Cancel" aborts restoration
  - [ ] 8.1.5 Test user selects "Clear current session and restore" cancels then
    restores
  - [ ] 8.1.6 Test handles missing session gracefully
  - [ ] 8.1.7 Run tests - **EXPECT FAILURES**
- [ ] 8.2 Implement restore_session to pass tests
  - [ ] 8.2.1 Add `Agentic.restore_session(session_id, opts)` to init.lua
  - [ ] 8.2.2 Get SessionManager for current tab via SessionRegistry
  - [ ] 8.2.3 Check if session exists AND has session_id AND ChatHistory has
    messages
  - [ ] 8.2.4 If conflict exists, call `vim.ui.select()` with options: "Cancel",
    "Clear current session and restore"
  - [ ] 8.2.5 Handle "Cancel" - return early
  - [ ] 8.2.6 Handle "Clear current session and restore" - call
    `session:_cancel_session()`
  - [ ] 8.2.7 Call `ChatHistory.load(session_id, nil, callback)` async
  - [ ] 8.2.8 In callback, get/create SessionManager and call
    `restore_from_history()`
  - [ ] 8.2.9 Show widget after restoration
  - [ ] 8.2.10 Run tests - **VERIFY PASS**

**CHECKPOINT:** Full API tests pass including conflict handling

## Phase 9: End-to-End Validation

- [ ] 9.1 Manual end-to-end test
  - [ ] 9.1.1 Start fresh session, have multi-turn conversation with tool calls
  - [ ] 9.1.2 Note the session_id from chat header
  - [ ] 9.1.3 Exit Neovim completely
  - [ ] 9.1.4 Restart Neovim
  - [ ] 9.1.5 Call `require('agentic').restore_session('<session_id>')`
  - [ ] 9.1.6 Verify all messages/tool calls visible in UI
  - [ ] 9.1.7 Submit new prompt, verify agent has conversation context
- [ ] 9.2 Edge case testing
  - [ ] 9.2.1 Test conflict prompt with existing session
  - [ ] 9.2.2 Test multiple sessions in same project folder
  - [ ] 9.2.3 Test different projects get different folders
  - [ ] 9.2.4 Test special chars in paths (spaces, colons)
  - [ ] 9.2.5 Test restore non-existent session (should log warning)
- [ ] 9.3 Run full validation suite
  - [ ] 9.3.1 `make validate` (format, luals, luacheck, tests)
  - [ ] 9.3.2 Fix any type checking errors
  - [ ] 9.3.3 Fix any linting warnings

**FINAL CHECKPOINT:** All tests pass, `make validate` passes
