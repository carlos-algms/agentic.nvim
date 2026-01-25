# Spec: Split View Display

## Context

When users configure split mode, edit permission requests with diffs should
display the original and proposed content in side-by-side buffers instead of
inline virtual lines.

## ADDED Requirements

### Requirement: Display side-by-side diff in split mode

When `diff_preview.mode` is `"split"`, the plugin MUST display diffs in
side-by-side buffers.

#### Scenario: Show split diff on permission request

**Given** `Config.diff_preview.mode = "split"`
**And** an edit tool call permission request with diff data
**When** the permission request is displayed
**Then** a vertical split window MUST be created
**And** the left buffer MUST show the original file content
**And** the right buffer MUST show the proposed new content
**And** both buffers MUST be set to read-only (`modifiable = false`)

#### Scenario: Apply highlights to both buffers

**Given** a split diff view is displayed
**When** the diff contains changed lines
**Then** deleted/changed lines in the original buffer MUST be highlighted with
`DIFF_DELETE` highlight group
**And** added/changed lines in the new buffer MUST be highlighted with
`DIFF_ADD` highlight group
**And** word-level changes MUST be highlighted with `DIFF_DELETE_WORD` and
`DIFF_ADD_WORD` respectively

#### Scenario: Handle pure insertion (new file)

**Given** `Config.diff_preview.mode = "split"`
**And** an edit tool call for a new file (no original content)
**When** the permission request is displayed
**Then** the left buffer MUST be empty or show a placeholder
**And** the right buffer MUST show the full proposed content
**And** all lines in the right buffer MUST be highlighted as additions

#### Scenario: Handle pure deletion (file removal)

**Given** `Config.diff_preview.mode = "split"`
**And** an edit tool call that deletes a file
**When** the permission request is displayed
**Then** the left buffer MUST show the original file content
**And** the right buffer MUST be empty or show a placeholder
**And** all lines in the left buffer MUST be highlighted as deletions

### Requirement: Clean up split view on permission resolution

When a permission is approved or rejected, the split view MUST be cleaned up.

#### Scenario: Close split on approval

**Given** a split diff view is displayed for a pending permission
**When** the user approves the permission
**Then** the split window MUST be closed
**And** the scratch buffer for proposed content MUST be deleted
**And** the original buffer's `modifiable` state MUST be restored
**And** highlights MUST be cleared from the original buffer

#### Scenario: Close split on rejection

**Given** a split diff view is displayed for a pending permission
**When** the user rejects the permission
**Then** the split window MUST be closed
**And** the scratch buffer MUST be deleted
**And** the original buffer MUST remain unchanged
**And** highlights MUST be cleared from the original buffer

### Requirement: Support hunk navigation in split mode

Hunk navigation keybindings (`]c`, `[c`) MUST work in split view.

#### Scenario: Navigate to next hunk in split view

**Given** a split diff view with multiple hunks
**And** the cursor is on hunk 1
**When** the user presses `]c`
**Then** the cursor MUST move to hunk 2 in the original buffer
**And** the cursor in the new buffer MUST move to the corresponding position
in hunk 2
**And** both buffers MUST scroll to show the hunk if
`center_on_navigate_hunks` is enabled

#### Scenario: Navigate to previous hunk in split view

**Given** a split diff view with multiple hunks
**And** the cursor is on hunk 2
**When** the user presses `[c`
**Then** the cursor MUST move to hunk 1 in the original buffer
**And** the cursor in the new buffer MUST move to the corresponding position
in hunk 1
**And** both buffers MUST scroll to show the hunk if
`center_on_navigate_hunks` is enabled

### Requirement: Maintain tabpage isolation for split views

Each tabpage MUST have independent split view state.

#### Scenario: Independent split views per tabpage

**Given** a split diff view is displayed in tabpage 1
**When** the user switches to tabpage 2
**And** a new edit permission request arrives in tabpage 2
**Then** tabpage 2 MUST show its own independent split view
**And** tabpage 1's split view MUST remain unchanged
**And** closing the split in tabpage 2 MUST NOT affect tabpage 1

#### Scenario: Split state stored per tabpage

**Given** a split diff view is displayed
**When** split view state is stored
**Then** state MUST be stored in `vim.t[tabpage]._agentic_diff_split_state`
**And** closing the tabpage MUST automatically clean up the state

### Requirement: Handle edge cases gracefully

Split view MUST handle edge cases without errors.

#### Scenario: Empty diff (no changes)

**Given** `Config.diff_preview.mode = "split"`
**And** an edit tool call where old and new content are identical
**When** the permission request is processed
**Then** the split view MUST NOT be created
**And** a notification SHOULD inform the user there are no changes

#### Scenario: User manually closes split window

**Given** a split diff view is displayed
**When** the user manually closes the split window (e.g., `:q`)
**Then** the scratch buffer MUST be cleaned up
**And** the split state MUST be cleared from `vim.t[tabpage]`
**And** no orphaned buffers or windows MUST remain

### Requirement: Support "both" mode

When `diff_preview.mode` is `"both"`, the plugin MUST display both inline and
split views.

#### Scenario: Display both inline and split views

**Given** `Config.diff_preview.mode = "both"`
**And** an edit tool call permission request with diff data
**When** the permission request is displayed
**Then** inline virtual lines MUST be displayed in the original buffer
**And** a split view MUST also be created with side-by-side buffers
**And** both visualizations MUST show the same diff data

#### Scenario: Clear both views on permission resolution

**Given** `Config.diff_preview.mode = "both"`
**And** both inline and split views are displayed
**When** the permission is approved or rejected
**Then** inline virtual lines MUST be cleared
**And** the split view MUST be closed
**And** all resources MUST be cleaned up

## Cross-References

- Depends on: `diff-view-configuration` spec (needs mode to be configured)
- Related to: Existing inline diff preview functionality (must coexist without
  conflicts)
