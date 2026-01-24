# Feature Specification: Fix Hunk Navigation to Focus on Real Lines

**Feature Branch**: `feat/25-show-rich-diff-on-buffer` (existing branch, not creating new)  
**Created**: 2026-01-24  
**Status**: Draft  
**Input**: User description: "Fix hunk navigation to focus on real lines instead of virtual line anchors. When navigating between diff hunks, jump to the actual buffer line (marked with DIFF_DELETE highlight) rather than the anchor point where virtual lines are attached."

## Clarifications

### Session 2026-01-24

- Q: Should we search for virtual line anchors or DIFF_DELETE highlights? → A: Search for DIFF_DELETE highlights in the same NS_DIFF namespace, not virtual line anchors. Both deletions and insertions use the same namespace.
- Q: How to handle multiple DIFF_DELETE highlights on the same line (word-level highlights)? → A: Deduplicate by line number, keep only unique lines. Navigate to column 0 of each line.
- Q: What order should the lines be in? → A: Sort by line number (top to bottom).
- Q: Where to navigate for pure insertions (file creation, no DIFF_DELETE highlights)? → A: Fall back to line 1, column 0 (first line, first column) instead of anchor position.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Navigate to First Deleted Line (Priority: P1)

When a developer navigates between diff hunks using keyboard shortcuts, the cursor jumps to the first line with DIFF_DELETE highlighting in each hunk. The cursor lands at the beginning of the line (column 0) on the actual deleted content.

**Why this priority**: Core navigation behavior that directly impacts user experience. Currently navigation lands on anchors (last deleted line), causing confusion. Users expect to see the beginning of the change at the start of the line.

**Independent Test**: Can be fully tested by opening a file with diff preview showing a hunk with 3 deleted lines (lines 10, 11, 12) where line 10 has word-level highlights, pressing "next hunk", and verifying cursor lands on line 10, column 0.

**Acceptance Scenarios**:

1. **Given** a hunk with lines 10, 11, 12 marked with DIFF_DELETE highlight, **When** user navigates to this hunk, **Then** cursor moves to line 10, column 0 (first deleted line, first column)

2. **Given** a line with multiple DIFF_DELETE highlights (word-level changes), **When** user navigates to that hunk, **Then** cursor lands on the line's first column, treating all highlights on that line as one line

3. **Given** multiple hunks in sequence, **When** user presses "next hunk" repeatedly, **Then** cursor lands on the first DIFF_DELETE line of each hunk in top-to-bottom order

4. **Given** cursor on a deleted line within a hunk, **When** user presses "previous hunk", **Then** cursor moves to the first DIFF_DELETE line (column 0) of the previous hunk

---

### User Story 2 - Handle Pure Insertion Hunks (Priority: P2)

When a hunk contains only insertions (no DIFF_DELETE highlights, only virtual lines), such as file creation or pure additions, navigation falls back to the first line at column 0.

**Why this priority**: Edge case for complete coverage. Pure insertions and new file creation have no deleted lines to navigate to.

**Independent Test**: Can be tested by creating a diff for a new file (all insertions), navigating to it, and verifying cursor lands on line 1, column 0.

**Acceptance Scenarios**:

1. **Given** a new file creation (only virtual lines, no DIFF_DELETE highlights), **When** user navigates to the first hunk, **Then** cursor moves to line 1, column 0

2. **Given** a pure insertion hunk in an existing file (no DIFF_DELETE highlights), **When** user navigates to it, **Then** cursor moves to line 1, column 0

3. **Given** mixed hunks (some with deletions, some pure insertions), **When** user navigates through all, **Then** deletions navigate to first DIFF_DELETE line, insertions navigate to line 1, column 0

---

### User Story 3 - Preserve Viewport Centering (Priority: P3)

When navigation jumps to the first deleted line at column 0, the viewport centers appropriately based on hunk size (existing centering logic continues to work).

**Why this priority**: Quality-of-life feature. The centering logic already exists, just needs to work with the new navigation target.

**Independent Test**: Navigate to a large hunk and verify viewport uses "zt" positioning with cursor at column 0, navigate to small hunk and verify "zz" centering with cursor at column 0.

**Acceptance Scenarios**:

1. **Given** a large hunk (>50% window height), **When** user navigates to its first deleted line, **Then** viewport positions that line at top ("zt") with cursor at column 0

2. **Given** a small hunk (<50% window height), **When** user navigates to its first deleted line, **Then** viewport centers that line ("zz") with cursor at column 0

3. **Given** a pure insertion hunk, **When** user navigates to it, **Then** viewport centers line 1 appropriately

---

### Edge Cases

- What happens when a line has multiple DIFF_DELETE highlights (word-level)? → Deduplicate by line number, treat as one line, navigate to column 0
- What happens when a hunk has no DIFF_DELETE highlights (pure insertion/file creation)? → Falls back to line 1, column 0
- What happens when navigating at the first/last hunk? → Wraps around (existing behavior preserved)
- What happens when a hunk has multiple consecutive DIFF_DELETE lines? → Cursor moves to the first one (lowest line number), column 0
- What happens when the buffer is not visible? → Shows error message (existing behavior preserved)
- What happens with mixed hunks (some deletions, some pure insertions)? → Deletions navigate to first DIFF_DELETE line column 0, insertions navigate to line 1 column 0

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: System MUST query the NS_DIFF namespace for all highlight extmarks (not just virt_lines extmarks) to identify deleted lines

- **FR-002**: System MUST identify lines with DIFF_DELETE highlighting as deleted lines within hunks

- **FR-003**: System MUST deduplicate DIFF_DELETE highlights by line number (multiple highlights on same line count as one line)

- **FR-004**: System MUST sort deleted lines by line number in ascending order (top to bottom)

- **FR-005**: System MUST navigate to the first (lowest line number) DIFF_DELETE highlighted line in a hunk at column 0

- **FR-006**: System MUST navigate to column 0 for all line-based navigation (deleted lines, and fallback positions)

- **FR-007**: System MUST fall back to line 1, column 0 when a hunk has no DIFF_DELETE highlights (pure insertion or file creation)

- **FR-008**: System MUST preserve existing centering behavior (zt/zz based on hunk size) when positioning the viewport

- **FR-009**: System MUST maintain current hunk wrapping behavior (wrap to first when at last, wrap to last when at first)

### Key Entities *(include if feature involves data)*

- **Hunk**: A contiguous block of changes, consisting of:
  - Zero or more unique lines with DIFF_DELETE highlighting (deduplicated by line number)
  - Optional virtual lines representing inserted content

- **Namespace (NS_DIFF)**: Shared namespace used for both DIFF_DELETE highlight extmarks and virtual line extmarks

- **DIFF_DELETE Highlight**: Applied to buffer lines (or portions of lines for word-level changes) representing content to be removed; multiple highlights on the same line are treated as one line for navigation

- **Line Number**: 0-indexed buffer line position used for sorting and deduplication (note: line 1 in user terms = line 0 in 0-indexed)

- **Column 0**: The first column of a line (0-indexed), where the cursor is positioned during navigation

- **Pure Insertion**: A hunk with no DIFF_DELETE highlights, consisting only of virtual lines (new content being added)

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Users navigate to the first DIFF_DELETE highlighted line at column 0 in 100% of hunks that contain deletions

- **SC-002**: Navigation correctly deduplicates multiple highlights on the same line (no duplicate line visits)

- **SC-003**: Navigation completes without errors for all hunk types (pure deletion, pure insertion, file creation, mixed modification)

- **SC-004**: Lines are visited in correct order (top to bottom, sorted by line number)

- **SC-005**: Cursor always lands at column 0 for all navigation operations

- **SC-006**: Pure insertions and file creation navigate to line 1, column 0 in 100% of cases

- **SC-007**: Viewport centering works correctly for both large and small hunks after navigating to target line

- **SC-008**: Implementation requires only changing the hunk detection logic from "find virt_lines" to "find DIFF_DELETE highlights + deduplicate + sort, fallback to line 1" (simple, focused change)
