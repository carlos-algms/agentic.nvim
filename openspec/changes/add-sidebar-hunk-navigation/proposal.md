# Change: Add Sidebar Hunk Navigation

**Note:** This change is part of the existing `feat/25-show-rich-diff-on-buffer` branch work. It extends the diff preview feature with sidebar navigation capabilities.

## Why

Currently, users can only navigate diff hunks when their cursor is inside the buffer showing the diff preview. This requires switching focus away from the chat sidebar, which disrupts the workflow of reviewing and approving changes while maintaining context in the chat conversation.

## What Changes

- Extend hunk navigation to work from ANY widget window (chat, todos, files, code snippets, prompt)
- When user triggers next/prev hunk navigation from sidebar windows, scroll the target buffer to the hunk WITHOUT moving the cursor from the sidebar window
- Preserve existing in-buffer navigation behavior (cursor moves when navigating from within the target buffer itself)
- Reuse existing keymaps (`]c` for next, `[c` for prev) configured in `Config.keymaps.diff_preview`

## Impact

- Affected specs: `specs/diff-preview/spec.md` (new capability)
- Affected code:
  - `lua/agentic/ui/hunk_navigation.lua` - Add sidebar-aware navigation logic
  - `lua/agentic/ui/chat_widget.lua` - Setup keymaps for all widget buffers
  - Tests: `lua/agentic/ui/hunk_navigation.test.lua`