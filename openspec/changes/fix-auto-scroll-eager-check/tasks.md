## 1. Rename method (non-behavioral, unblocks tests)

- [ ] 1.1 Rename `_should_auto_scroll` method to
  `_check_auto_scroll`
- [ ] 1.2 Update existing tests for the method rename

## 2. Write tests (red phase)

- [ ] 2.1 Test: `_should_auto_scroll` field stays `true` across
  multiple `_auto_scroll` calls (sticky behavior — skip
  re-evaluation when already `true`)
- [ ] 2.2 Test: large buffer growth after field is `true` does
  not flip it — scroll still executes
- [ ] 2.3 Test: timer callback resets `_should_auto_scroll` to
  `nil` after scrolling
- [ ] 2.4 Test: after reset, re-evaluation returns `false` when
  user has scrolled up
- [ ] 2.5 Run tests — verify new tests fail

## 3. Scaffold (green skeleton)

- [ ] 3.1 Add `_should_auto_scroll` boolean field to
  MessageWriter (initialized as `nil`)
- [ ] 3.2 Add empty/stub logic in `_auto_scroll` and timer
  callback referencing the new field
- [ ] 3.3 Run tests — verify new tests still fail

## 4. Implement (green phase)

- [ ] 4.1 In `_auto_scroll`: only call `_check_auto_scroll` when
  `self._should_auto_scroll` is not `true`; store result in
  `self._should_auto_scroll`
- [ ] 4.2 In the timer callback: read `self._should_auto_scroll`,
  scroll if `true`, reset field to `nil`
- [ ] 4.3 Remove `_auto_scroll` call from `_append_lines`,
  making it a pure buffer-write helper
- [ ] 4.4 Add `_auto_scroll` call at end of `write_message`'s
  `with_modifiable` block
- [ ] 4.5 Add `_auto_scroll` call at end of
  `write_tool_call_block`'s `with_modifiable` block
- [ ] 4.6 Add `_auto_scroll` call at end of
  `display_permission_buttons`'s `with_modifiable` block
- [ ] 4.7 `write_message_chunk` already calls `_auto_scroll`
  once — verify no changes needed
- [ ] 4.8 Run tests — verify all tests pass

## 5. Validation

- [ ] 5.1 Run `make validate` — all checks pass
