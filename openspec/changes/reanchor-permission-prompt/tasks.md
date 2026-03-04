# Tasks: Reanchor permission prompt

## 1. MessageWriter content-changed callback

- [x] 1.1 RED: Test `set_on_content_changed` stores callback and
  `_notify_content_changed` fires it
- [x] 1.2 GREEN: Add `_on_content_changed` field,
  `set_on_content_changed(callback)`, and
  `_notify_content_changed()` to `MessageWriter`
- [x] 1.3 RED: Test each public write method fires the callback:
  `write_message`, `write_message_chunk`, `write_tool_call_block`,
  `update_tool_call_block`
- [x] 1.4 GREEN: Call `_notify_content_changed()` at end of each
  public write method

## 2. PermissionManager reanchor logic

- [x] 2.1 RED: Test new content after permission prompt triggers
  reanchor — buttons end up at buffer bottom
- [x] 2.2 GREEN: Add `_reanchor_permission_prompt()` method, wire
  `set_on_content_changed` in `_process_next()`
- [x] 2.3 RED: Test reanchor does not trigger recursive
  `on_content_changed`
- [x] 2.4 GREEN: Add `_reanchoring` flag to guard the callback
- [x] 2.5 RED: Test keymaps work after reanchor
- [x] 2.6 GREEN: Re-bind keymaps in `_reanchor_permission_prompt()`
- [x] 2.7 RED: Test completing a request clears the callback
- [x] 2.8 GREEN: Clear callback in `_complete_request()` and `clear()`

## 3. Validation

- [x] 3.1 Run `make validate` and fix any issues
