# Feature Specification: Permission Hint Keybindings

**Feature Branch**: `001-permission-hint-keybinds`  
**Created**: 2026-01-24  
**Status**: Draft  
**Input**: User description: "When we are showing a permission request, specifically if it's an edit one, we are calling the "Deep Preview" or "DisplayDeep" method so the user can have a visual feedback of what is going to be the change. When we are doing this, specifically for an edit, I also want to show below the permission request a virtual line showing hints about what the user can do and which key bindings are available for him. For example, I want the user to see the message highlighted as a comment so it has a low contrast, a sentence like this. "Hint" in all caps. `]c` next Hunk, `[c` previous hunk. so the user knows which key bindings are available while we are waiting for his response to be accepted or released. to be accepted or rejected. These virtual lines should be removed if the user approves or reject the current pending permission request. Maybe instead of a virtual line, let's make it a real line so we don't have to clean up, because we already have cleanups in place for approvals or rejections whenever a tool call is called. Make sure to do a deep investigation and figure out how the approval tool shows the available options and then remove the available options. So you know if it's possible to show a new line at the bottom because it's going to be automatically removed and then we don't need to add additional code to remove that line. I also consider that maybe it's going to be very difficult to pass information or to fetch information that this current permission is for an added tool instead of a bash execution request. And if that is the case, if that is extremely difficult or it requires too many prop drilling and passing parameters around, maybe we should consider a different approach. Do your investigation and then we can clarify how to do it."

## Clarifications

### Session 2026-01-24

- Q: Where exactly should the hint line appear relative to the permission buttons? → A: After the "--- ---" separator line (buttons → separator → hint → blank line)
- Q: Should the backticks around `]c` and `[c` render as inline code formatting or plain text? → A: No backticks, plain keybinding names

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Discover Navigation Keybindings During Edit Permission (Priority: P1)

When a user receives an edit tool permission request with diff preview, they see a hint line below the permission buttons showing available navigation keybindings (`]c` for next hunk, `[c` for previous hunk).

**Why this priority**: This is the core value - users can immediately discover and use navigation keybindings without reading documentation or experimenting.

**Independent Test**: Can be fully tested by triggering any edit permission request with diff preview and verifying the hint line appears with correct keybinding information.

**Acceptance Scenarios**:

1. **Given** user receives an edit permission request with diff preview active, **When** the permission buttons are displayed, **Then** a hint line appears below showing "HINT: ]c next hunk, [c previous hunk"
2. **Given** user sees the hint line, **When** they press a navigation key (e.g., `]c`), **Then** cursor navigates to next hunk as indicated
3. **Given** user sees permission buttons with hint line, **When** they approve or reject the permission, **Then** hint line is automatically removed along with permission buttons

---

### User Story 2 - Low-Contrast Visual Design for Hints (Priority: P2)

The hint line is styled with low contrast (comment-style highlighting) so it provides guidance without drawing excessive attention from the primary permission decision.

**Why this priority**: Improves user experience by preventing visual clutter, but the feature is still valuable without perfect styling.

**Independent Test**: Visual inspection of hint line styling confirms low-contrast, comment-like appearance that doesn't overpower permission buttons.

**Acceptance Scenarios**:

1. **Given** hint line is displayed, **When** user views the permission request, **Then** hint text appears with comment-style highlighting (low contrast)
2. **Given** permission buttons and hint line are both visible, **When** user scans the interface, **Then** permission buttons remain the primary visual focus

---

### User Story 3 - Automatic Cleanup on Permission Resolution (Priority: P1)

When a permission request is resolved (approved/rejected/cancelled), both permission buttons and hint line are automatically removed without requiring separate cleanup logic.

**Why this priority**: Essential for correct behavior - prevents hint line from persisting after permission resolution and ensures clean user experience.

**Independent Test**: Trigger permission request, resolve it (approve/reject), and verify both buttons and hint line are removed automatically.

**Acceptance Scenarios**:

1. **Given** permission buttons and hint line are displayed, **When** user approves the permission (selects option), **Then** both buttons and hint line are removed in single cleanup operation
2. **Given** permission buttons and hint line are displayed, **When** user rejects the permission, **Then** both buttons and hint line are removed automatically
3. **Given** permission request is queued, **When** session is cleared/cancelled, **Then** hint line is removed along with other permission UI elements

---

### Edge Cases

- What happens when permission request is for a non-edit tool (e.g., bash execution)? Hint line should only appear for edit permissions with diff preview.
- What happens when diff preview is disabled in configuration? Hint line should not appear since navigation keybindings won't be available.
- What happens when multiple permission requests are queued? Hint line should only appear for the currently displayed request.
- What happens when buffer becomes invalid during permission request? Cleanup should handle invalid buffer gracefully.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST display a hint line after the "--- ---" separator line (below permission buttons) when showing edit tool permission requests with active diff preview
- **FR-002**: Hint line MUST contain text: "HINT: ]c next hunk, [c previous hunk" (plain text, no backticks or special formatting)
- **FR-003**: Hint line MUST be styled with comment-style highlighting for low visual contrast
- **FR-004**: Hint line MUST be automatically removed when permission request is resolved (approved, rejected, or cancelled)
- **FR-005**: Hint line MUST NOT appear for non-edit tool permissions (e.g., bash execution requests)
- **FR-006**: Hint line MUST NOT appear when diff preview is disabled in configuration
- **FR-007**: System MUST use the existing permission button cleanup mechanism to remove hint line (no separate cleanup logic)
- **FR-008**: Hint line MUST be inserted as part of the permission button display operation (lines added to buffer, not virtual text)

### Key Entities

- **Permission Request**: Represents a tool call requiring user approval, has properties including tool type (edit, bash, etc.) and options (allow/reject)
- **Hint Line**: A text line showing available keybindings, appears below permission buttons, removed automatically with buttons
- **Diff Preview**: Visual representation of file changes for edit operations, determines whether navigation keybindings are available

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users can view available navigation keybindings without leaving the permission request interface
- **SC-002**: Hint line appears within 200ms of permission buttons being displayed (same rendering operation)
- **SC-003**: Hint line and permission buttons are removed together in under 50ms (single cleanup operation)
- **SC-004**: Navigation keybindings shown in hint line work correctly for 100% of edit permissions with diff preview

## Assumptions

- Permission button display and removal use line-based operations (append lines, delete line range)
- Edit tool permissions always include diff information when diff preview is enabled
- Existing keybindings (`]c`, `[c`) are set up by HunkNavigation module when diff preview is active
- Comment highlight group is available in theme for low-contrast text styling
- Permission button cleanup operates on a line range (start_row to end_row), which can include additional lines
