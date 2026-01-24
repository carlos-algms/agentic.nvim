## ADDED Requirements

### Requirement: Sidebar Hunk Navigation

The system SHALL allow users to navigate diff hunks from ANY widget window (chat, todos, files, code snippets, prompt) without losing focus on the current sidebar window.

#### Scenario: Navigate next hunk from sidebar window

- **WHEN** user is in any widget window (chat, todos, files, code snippets, or prompt)
- **AND** there is an active diff preview in a target buffer
- **AND** user presses the next hunk keymap (`]c` by default)
- **THEN** the target buffer window scrolls to show the next hunk
- **AND** the cursor remains in the sidebar window (does not move to target buffer)
- **AND** the hunk is centered or positioned at top based on `Config.diff_preview.center_on_navigate_hunks` setting

#### Scenario: Navigate previous hunk from sidebar window

- **WHEN** user is in any widget window (chat, todos, files, code snippets, or prompt)
- **AND** there is an active diff preview in a target buffer
- **AND** user presses the previous hunk keymap (`[c` by default)
- **THEN** the target buffer window scrolls to show the previous hunk
- **AND** the cursor remains in the sidebar window (does not move to target buffer)
- **AND** the hunk is centered or positioned at top based on `Config.diff_preview.center_on_navigate_hunks` setting

#### Scenario: Navigate from target buffer preserves existing behavior

- **WHEN** user is in the buffer showing the diff preview (not a sidebar window)
- **AND** user presses next/prev hunk keymap
- **THEN** the cursor moves to the hunk position in the current buffer
- **AND** the window scrolls to show the hunk
- **AND** existing in-buffer navigation behavior is preserved

#### Scenario: No diff preview active

- **WHEN** user presses next/prev hunk keymap from a sidebar window
- **AND** there is no active diff preview in any visible buffer
- **THEN** the system notifies the user "No active diff preview found"
- **AND** no navigation occurs

#### Scenario: Target buffer not visible

- **WHEN** user presses next/prev hunk keymap from a sidebar window
- **AND** the buffer with active diff preview is not visible in any window
- **THEN** the system notifies the user "Diff preview buffer not visible"
- **AND** no navigation occurs

### Requirement: Unified Keymap Configuration

The system SHALL reuse existing `Config.keymaps.diff_preview.next_hunk` and `Config.keymaps.diff_preview.prev_hunk` configuration for both in-buffer and sidebar navigation.

#### Scenario: Keymaps work consistently across contexts

- **WHEN** user configures custom keymaps in `Config.keymaps.diff_preview`
- **THEN** those keymaps work identically for both in-buffer navigation and sidebar navigation
- **AND** no additional configuration is required for sidebar navigation
