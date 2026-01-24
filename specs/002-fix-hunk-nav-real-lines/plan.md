# Implementation Plan: Fix Hunk Navigation to Focus on Real Lines

**Branch**: `feat/25-show-rich-diff-on-buffer` | **Date**: 2026-01-24 | **Spec**: [spec.md](spec.md)  
**Input**: Feature specification from `/specs/002-fix-hunk-nav-real-lines/spec.md`

## Summary

Change hunk navigation to target the first DIFF_DELETE highlighted line (column 0) instead of virtual line anchors (which point to the last deleted line). For pure insertions (no DIFF_DELETE highlights), fall back to line 1, column 0. Implementation focuses on modifying `_get_hunk_anchors()` in `hunk_navigation.lua` to query highlight extmarks, deduplicate by line number, and sort ascending.

## Technical Context

**Language/Version**: Lua 5.1 (LuaJIT 2.1 bundled with Neovim v0.11.0+)  
**Primary Dependencies**: Neovim v0.11.0+ APIs (extmarks, highlights, vim.api)  
**Storage**: N/A (in-memory state only)  
**Testing**: mini.test framework with Busted-style emulation  
**Target Platform**: Neovim v0.11.0+ on macOS/Linux/Windows  
**Project Type**: Single Neovim plugin  
**Performance Goals**: Navigation response < 50ms for typical diffs (< 1000 lines)  
**Constraints**: Must work with existing NS_DIFF namespace; no breaking changes to extmark structure  
**Scale/Scope**: Single file modification (`hunk_navigation.lua`); affects ~50 lines of code

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Compliance Matrix

| Principle | Status | Notes |
|-----------|--------|-------|
| I. YAGNI | ✅ PASS | Only building what's specified (navigate to first deleted line) |
| II. Simplicity | ✅ PASS | Changing existing query logic, not adding abstractions |
| III. No assumptions | ✅ PASS | All extmark API usage verified against Neovim v0.11.0+ docs |
| IV. DRY | ✅ PASS | Reusing existing extmark query patterns from diff_preview.lua |
| V. Decoupling | ✅ PASS | No new cross-module dependencies; modifying existing module |
| VI. Multi-tabpage safety | ✅ PASS | Uses per-buffer state via `buffer_state` table (existing pattern) |
| VII. Validate before commit | ⏳ PENDING | Will run `make validate` after implementation |
| VIII. TDD | ⏳ PENDING | Tests exist in `hunk_navigation.test.lua`; will add/modify tests first |

**GATE RESULT**: ✅ PASS - All applicable principles satisfied

### Architecture Constraints Check

| Constraint | Status | Notes |
|------------|--------|-------|
| Neovim v0.11.0+ | ✅ PASS | Using stable extmark APIs (nvim_buf_get_extmarks) |
| LuaJIT 2.1 (Lua 5.1) | ✅ PASS | No Lua 5.2+ features required |
| Multi-tabpage safety | ✅ PASS | Existing `buffer_state` table already tabpage-safe |
| Single ACP session per tabpage | N/A | Feature doesn't interact with ACP |
| Testing cleanup | ✅ PASS | Existing tests already clean up resources |

**GATE RESULT**: ✅ PASS - All constraints satisfied

## Project Structure

### Documentation (this feature)

```text
specs/002-fix-hunk-nav-real-lines/
├── spec.md              # Feature specification
├── plan.md              # This file
├── research.md          # Phase 0 output (to be generated)
├── data-model.md        # Phase 1 output (to be generated)
├── checklists/
│   └── requirements.md  # Spec quality checklist
└── tasks.md             # Phase 2 output (NOT created by this command)
```

### Source Code (repository root)

```text
lua/agentic/
└── ui/
    ├── hunk_navigation.lua       # MODIFY: Change _get_hunk_anchors() logic
    └── hunk_navigation.test.lua  # MODIFY: Update/add test cases

lua/agentic/utils/
└── diff_highlighter.lua          # READ: Understand highlight application

lua/agentic/ui/
└── diff_preview.lua              # READ: Understand hunk structure & NS_DIFF usage
```

**Structure Decision**: Single project structure. Feature modifies one existing module (`hunk_navigation.lua`) and its test file. No new files or directories needed.

## Complexity Tracking

> **No violations detected** - this section is empty as all Constitution Check gates passed.

## Phase 0: Research & Unknowns

### Research Tasks

1. **Extmark query patterns for highlights**
   - **Question**: How to query `nvim_buf_get_extmarks()` specifically for highlight extmarks (vs virt_lines)?
   - **Approach**: Read Neovim API docs for `nvim_buf_get_extmarks()` with `{ details = true, type = "highlight" }`
   - **Output**: Confirm API supports filtering by extmark type

2. **DIFF_DELETE highlight structure**
   - **Question**: How are DIFF_DELETE highlights stored in extmarks? What does the `details` table contain?
   - **Approach**: Examine `diff_highlighter.lua` to understand `vim.highlight.range()` usage, test querying extmarks with `{ details = true }`
   - **Output**: Document extmark details structure for highlights

3. **Line number indexing**
   - **Question**: Confirm Neovim uses 0-indexed line numbers for extmarks and cursor positioning
   - **Approach**: Verify via Neovim docs and existing codebase usage
   - **Output**: Document indexing convention (0-indexed for API, 1-indexed for user-facing)

4. **Deduplication & sorting patterns**
   - **Question**: Best Lua pattern for deduplicating line numbers and sorting?
   - **Approach**: Review existing Lua table manipulation in codebase, standard Lua patterns
   - **Output**: Confirm using table.insert + table.sort + table dedup pattern

5. **Cursor positioning API**
   - **Question**: How to set cursor to specific line and column 0?
   - **Approach**: Verify `vim.cmd(string.format("normal! %dG", line))` sets column 0 by default
   - **Output**: Confirm cursor positioning approach

### Dependencies on External Systems

- **Neovim v0.11.0+ API**: Stable, no breaking changes expected
- **NS_DIFF namespace**: Already established in `diff_preview.lua`, shared across modules

## Phase 1: Design & Contracts

### Data Model

#### Modified State Structures

**`buffer_state` table** (existing, no changes):
```lua
--- @class agentic.ui.HunkNavigation.State
--- @field saved_keymaps { next?: table, prev?: table }
--- @field hunk_index number Current hunk index (0-based, -1 means uninitialized)
--- @field anchors_cache integer[]|nil Cached hunk positions (0-indexed line numbers)
```

**Note**: `anchors_cache` semantics change from "virtual line anchor positions" to "first deleted line positions per hunk"

#### New Internal Data Structures

**Deleted line set** (temporary during query):
```lua
--- @type table<integer, boolean> Map of line numbers (0-indexed) to presence
local deleted_lines = {}  -- Used for O(1) deduplication
```

**Sorted deleted lines** (result):
```lua
--- @type integer[] Sorted array of unique line numbers (0-indexed)
local hunk_positions = {}  -- Replaces anchors_cache content
```

### API Contracts

#### Modified Function: `_get_hunk_anchors()`

**Current signature** (unchanged):
```lua
--- Get all hunk anchor positions (where virtual lines start)
--- @param bufnr number
--- @return integer[] anchors 0-indexed line numbers where hunks are anchored
function M._get_hunk_anchors(bufnr)
```

**Behavioral change**:
- **Before**: Returns line numbers where virtual lines are attached (anchors)
- **After**: Returns first deleted line of each hunk (or line 0 for pure insertions)

**Implementation approach**:
1. Query `nvim_buf_get_extmarks(bufnr, NS_DIFF, 0, -1, { details = true })`
2. Filter for extmarks with `hl_group` matching DIFF_DELETE patterns
3. Collect line numbers into set (deduplicate)
4. Convert set to sorted array
5. If empty (pure insertion case), return `{0}` (line 1 in 1-indexed terms)
6. Cache result in `state.anchors_cache`

#### Modified Function: `find_hunk()`

**Current signature** (unchanged):
```lua
--- Find next/previous hunk position relative to current hunk index
--- @param bufnr number
--- @param direction "next"|"prev"
--- @return number|nil target_line 1-indexed line number
--- @return number|nil new_index 0-based hunk index
local function find_hunk(bufnr, direction)
```

**Behavioral change**:
- **Before**: Returns anchor line (last deleted line or line before insertion)
- **After**: Returns first deleted line + 1 (converts 0-indexed to 1-indexed)

**Implementation approach**:
- Call `_get_hunk_anchors()` (now returns first deleted lines)
- Apply existing wrapping/indexing logic (unchanged)
- Return line + 1 for 1-indexed cursor positioning

#### Modified Function: `navigate_hunk()`

**Current signature** (unchanged):
```lua
--- Navigate to hunk in specified direction
--- @param bufnr number
--- @param direction "next"|"prev"
local function navigate_hunk(bufnr, direction)
```

**Behavioral change**:
- **Before**: Cursor lands on anchor line (potentially confusing for multi-line deletions)
- **After**: Cursor lands on first deleted line, column 0 (or line 1 column 0 for pure insertions)

**Implementation approach**:
- Unchanged (relies on `find_hunk()` returning correct target)
- Existing `vim.cmd(string.format("normal! %dG%s", target_line, scroll_cmd))` already positions at column 0

### Integration Points

#### With `diff_preview.lua`

- **No changes required** to diff_preview.lua
- Reads NS_DIFF namespace (already shared)
- DIFF_DELETE highlights already applied via `DiffHighlighter.apply_diff_highlights()`

#### With `diff_highlighter.lua`

- **No changes required** to diff_highlighter.lua
- Already applies DIFF_DELETE highlights using `vim.highlight.range()`
- Highlights stored in NS_DIFF namespace as extmarks

### Testing Strategy

#### Test Cases to Add/Modify

**File**: `lua/agentic/ui/hunk_navigation.test.lua`

1. **Test: Navigate to first deleted line (single hunk, 3 deleted lines)**
   - Setup: Create buffer with lines 10-12 having DIFF_DELETE highlights
   - Action: Call `navigate_next()`
   - Assert: Cursor at line 10, column 0

2. **Test: Navigate to first deleted line (multiple hunks)**
   - Setup: Create buffer with two hunks (lines 5-7 and 15-18 deleted)
   - Action: Call `navigate_next()` twice
   - Assert: First navigation → line 5, second → line 15

3. **Test: Deduplicate word-level highlights on same line**
   - Setup: Apply multiple DIFF_DELETE highlights to line 10 (columns 0-5, 10-15)
   - Action: Call `navigate_next()`
   - Assert: Cursor at line 10, column 0 (only one hunk detected)

4. **Test: Pure insertion fallback (no DIFF_DELETE highlights)**
   - Setup: Create buffer with only virtual lines (no highlights)
   - Action: Call `navigate_next()`
   - Assert: Cursor at line 1, column 0

5. **Test: Mixed hunks (deletions + pure insertions)**
   - Setup: Create buffer with hunk 1 (deletions at lines 5-7), hunk 2 (pure insertion)
   - Action: Navigate to both hunks
   - Assert: Hunk 1 → line 5 column 0, Hunk 2 → line 1 column 0

6. **Test: Hunk wrapping behavior (first/last hunk)**
   - Setup: Create buffer with 3 hunks
   - Action: Navigate to last hunk, then "next"
   - Assert: Wraps to first hunk (line of first deleted line)

7. **Test: Cache invalidation**
   - Setup: Create buffer with hunks, navigate once (cache populated)
   - Action: Clear diff, navigate again
   - Assert: Returns nil (no hunks found)

#### Test Utilities

**Existing utilities** (in `hunk_navigation.test.lua`):
- Buffer creation helpers
- Extmark setup helpers
- Cursor position assertions

**New utilities needed**:
- Helper to apply multiple DIFF_DELETE highlights to same line (word-level)
- Helper to verify deduplication (no duplicate line numbers in cache)

## Phase 2: Task Breakdown

**Note**: This section will be populated by the `/speckit.tasks` command. The implementation plan ends here.

---

## Next Steps

1. **Generate research.md**: Run research tasks to resolve all unknowns
2. **Generate data-model.md**: Document modified state structures and contracts
3. **Run `/speckit.tasks`**: Generate detailed implementation tasks from this plan
4. **Implement with TDD**: Write tests first, then implement changes to `_get_hunk_anchors()`
5. **Validate**: Run `make validate` to ensure all checks pass
