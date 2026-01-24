# Data Model: Fix Hunk Navigation to Focus on Real Lines

**Feature**: 002-fix-hunk-nav-real-lines  
**Date**: 2026-01-24  
**Status**: Design Phase

## Overview

This document defines the data structures and state management for the hunk navigation fix. The core change is modifying how hunk positions are identified: from virtual line anchors to first deleted lines with DIFF_DELETE highlights.

## State Management

### Module-Level State

**Location**: `lua/agentic/ui/hunk_navigation.lua`

```lua
--- Module-level state storage (per-buffer)
--- @type table<number, agentic.ui.HunkNavigation.State>
local buffer_state = {}
```

**Rationale**: Per-buffer state enables multi-tabpage safety. Each buffer can be open in multiple tabpages, and navigation state is independent per buffer.

### Buffer State Structure

**Existing structure** (no changes to type definition):

```lua
--- Per-buffer state for hunk navigation
--- @class agentic.ui.HunkNavigation.State
--- @field saved_keymaps { next?: table, prev?: table } Saved keymaps for restoration
--- @field hunk_index number Current hunk index (0-based, -1 means uninitialized)
--- @field anchors_cache integer[]|nil Cached hunk positions (0-indexed line numbers)
```

**Semantic change** (behavior only):
- **Before**: `anchors_cache` contains line numbers where virtual lines are attached (typically last deleted line)
- **After**: `anchors_cache` contains line numbers of first deleted line per hunk (or line 0 for pure insertions)

**Why no type change needed**: Both interpretations use `integer[]` representing 0-indexed line numbers. The cache key and structure remain identical; only the query logic changes.

## Data Flow

### Hunk Position Detection

**Input**: Buffer number (bufnr)

**Process**:

1. **Query extmarks** from NS_DIFF namespace:
   ```lua
   vim.api.nvim_buf_get_extmarks(
       bufnr,
       NS_DIFF,
       0,
       -1,
       { details = true, type = "highlight" }
   )
   ```

2. **Filter for DIFF_DELETE highlights**:
   ```lua
   -- Extmark structure:
   -- [extmark_id, row, col, details]
   -- details = { hl_group = "AgenticDiffDelete", end_row = N, end_col = N, ... }
   
   for _, extmark in ipairs(extmarks) do
       local _, row, _, details = unpack(extmark)
       if details and details.hl_group == Theme.HL_GROUPS.DIFF_DELETE then
           -- row is 0-indexed line number
           deleted_lines[row] = true  -- Deduplicate via set
       end
   end
   ```

3. **Convert set to sorted array**:
   ```lua
   local hunk_positions = {}
   for line_num in pairs(deleted_lines) do
       table.insert(hunk_positions, line_num)
   end
   table.sort(hunk_positions)
   ```

4. **Handle pure insertion edge case**:
   ```lua
   if #hunk_positions == 0 then
       -- No DIFF_DELETE highlights found (pure insertion or file creation)
       hunk_positions = { 0 }  -- Line 1 in 1-indexed terms
   end
   ```

**Output**: Sorted array of 0-indexed line numbers

**Caching**: Result stored in `state.anchors_cache` until invalidated by `clear_state()`

### Navigation Flow

**Input**: Buffer number, direction ("next" | "prev")

**Process**:

1. **Get hunk positions** (from cache or fresh query):
   ```lua
   local hunk_positions = M._get_hunk_anchors(bufnr)
   ```

2. **Calculate target index** with wrapping:
   ```lua
   local current_index = state.hunk_index  -- 0-based
   local new_index
   
   if direction == "next" then
       new_index = (current_index + 1) % #hunk_positions
   else
       new_index = current_index <= 0 and #hunk_positions - 1 or current_index - 1
   end
   ```

3. **Get target line** (convert 0-indexed to 1-indexed):
   ```lua
   local target_line = hunk_positions[new_index + 1] + 1
   ```

4. **Calculate scroll command**:
   ```lua
   local scroll_cmd = M.get_scroll_cmd(bufnr, winid, target_line - 1)
   -- Returns "zt", "zz", or "" based on hunk size vs window height
   ```

5. **Move cursor** (column 0 implicit):
   ```lua
   vim.cmd(string.format("normal! %dG%s", target_line, scroll_cmd))
   -- %dG moves to line (1-indexed), first non-blank column
   ```

**Output**: Cursor positioned at target line, column 0

**State update**: `state.hunk_index = new_index`

## Data Structures

### Temporary Structures

**Deleted lines set** (used during deduplication):

```lua
--- @type table<integer, boolean>
local deleted_lines = {}
```

**Purpose**: O(1) deduplication when multiple highlight extmarks exist on same line (word-level highlights)

**Lifecycle**: Created in `_get_hunk_anchors()`, destroyed when function exits

### Persistent Structures

**Hunk positions cache**:

```lua
--- @type integer[]|nil
state.anchors_cache = { 10, 25, 47 }  -- Example: hunks at lines 10, 25, 47 (0-indexed)
```

**Purpose**: Avoid repeated extmark queries during navigation

**Invalidation**: Cleared by `clear_state(bufnr)` when diff preview is removed

**Lifecycle**: Created on first navigation, reused until invalidation

## Indexing Conventions

### Line Numbers

**API (extmarks, highlights)**: 0-indexed
- Line 1 in editor = index 0
- Line 10 in editor = index 9

**Cursor positioning**: 1-indexed
- `normal! 10G` moves to line 10 (what user sees)

**Conversion**:
```lua
-- API to cursor
local cursor_line = api_line + 1

-- Cursor to API
local api_line = cursor_line - 1
```

### Column Numbers

**API**: 0-indexed, inclusive start, exclusive end
- `{ start_col = 0, end_col = 5 }` highlights columns 0-4

**Cursor**: 1-indexed for display, but `normal! G` positions at column 0 (first non-blank)

**Navigation target**: Always column 0 (first column)

## Edge Cases

### Pure Insertion (File Creation)

**Scenario**: No DIFF_DELETE highlights found

**Data state**:
```lua
hunk_positions = { 0 }  -- Single hunk at line 0 (line 1 in 1-indexed)
```

**Navigation result**: Cursor at line 1, column 0

### Multiple Highlights Per Line

**Scenario**: Word-level highlights create multiple extmarks on same line

**Data state**:
```lua
-- Before deduplication (from extmark query):
-- extmarks = {
--   [1] = { id=10, row=5, col=0, details={ hl_group="AgenticDiffDelete" } },
--   [2] = { id=11, row=5, col=8, details={ hl_group="AgenticDiffDeleteWord" } }
-- }

-- After deduplication:
deleted_lines = { [5] = true }  -- Only line 5, not two entries
hunk_positions = { 5 }
```

**Navigation result**: Cursor at line 6 (5+1), column 0 (visits line once)

### Empty Buffer

**Scenario**: Buffer with no extmarks (no diff preview active)

**Data state**:
```lua
hunk_positions = {}  -- Empty array
```

**Navigation result**: Returns `nil, nil` from `find_hunk()`, shows "No hunks found" message

### Single-Line Hunk

**Scenario**: Hunk with one deleted line

**Data state**:
```lua
hunk_positions = { 10 }  -- Single hunk at line 10
```

**Navigation result**: 
- "Next" from hunk index 0 → wraps to index 0 (same hunk)
- Cursor stays at line 11, column 0

## Data Constraints

### Invariants

1. **Sorted order**: `hunk_positions` is always sorted ascending
   - Rationale: Enables predictable top-to-bottom navigation

2. **Uniqueness**: Each line number appears at most once in `hunk_positions`
   - Rationale: Prevents duplicate hunk visits from word-level highlights

3. **0-indexed storage**: `hunk_positions` contains 0-indexed line numbers
   - Rationale: Matches Neovim API conventions; converted to 1-indexed only for cursor commands

4. **Non-negative**: All line numbers >= 0
   - Rationale: Neovim buffers use 0-indexed line numbers, negative values invalid

5. **Fallback line**: Pure insertions use line 0 (not empty array)
   - Rationale: Ensures navigation always has a target (line 1 for user)

### Validation

No explicit validation needed - constraints enforced by implementation:
- `table.sort()` ensures sorted order
- Set-based deduplication ensures uniqueness
- Extmark API returns only valid line numbers (>= 0)
- Fallback logic ensures non-empty result

## Performance Considerations

### Time Complexity

**Query**: O(n) where n = number of extmarks in NS_DIFF
- Single pass through extmarks
- Hash table insertion: O(1) per extmark
- Sorting: O(m log m) where m = unique deleted lines (typically m << n)

**Navigation**: O(1)
- Array lookup by index
- Simple arithmetic for wrapping

### Space Complexity

**Cache**: O(m) where m = number of hunks
- `anchors_cache` stores one integer per hunk
- Typical: 1-20 hunks per file

**Temporary**: O(n) during query
- `deleted_lines` set can hold up to n entries (one per extmark)
- Freed immediately after query completes

### Optimization Notes

- **Caching**: Avoids repeated extmark queries (expensive Neovim API call)
- **Set-based deduplication**: O(n) vs O(n²) for array-based deduplication
- **Lazy invalidation**: Cache persists until diff cleared, not per-navigation

## Compatibility

**Neovim Version**: Requires v0.11.0+ for extmark `type` filter
- `{ type = "highlight" }` parameter introduced in v0.5.0, stable in v0.11.0

**Lua Version**: Compatible with LuaJIT 2.1 (Lua 5.1)
- Uses only Lua 5.1 features (table.insert, table.sort, pairs)

**Breaking Changes**: None
- External API unchanged (`navigate_next()`, `navigate_prev()`)
- Internal state structure unchanged (only semantic change to `anchors_cache`)
