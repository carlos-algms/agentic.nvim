# Research Findings: Hunk Navigation Implementation

## 1. Query nvim_buf_get_extmarks() for Highlight Extmarks

### API Signature
```lua
nvim_buf_get_extmarks({buffer}, {ns_id}, {start}, {end}, {opts})
```

### Parameters
- `{buffer}`: Buffer id, or 0 for current buffer
- `{ns_id}`: Namespace id from `nvim_create_namespace()` or -1 for all namespaces
- `{start}`: Start of range: a 0-indexed (row, col) or valid extmark id
- `{end}`: End of range (inclusive): a 0-indexed (row, col) or valid extmark id
- `{opts}`: Optional parameters:
  - `limit`: Maximum number of marks to return
  - `details`: Whether to include the details dict
  - `hl_name`: Whether to include highlight group name instead of id (true if omitted)
  - `overlap`: Also include marks which overlap the range
  - **`type`**: Filter marks by type: **"highlight"**, "sign", "virt_text" and "virt_lines"

### Return Value
List of `[extmark_id, row, col]` tuples in "traversal order" when `details = false`.

When `details = true`, returns `[extmark_id, row, col, details]` where `details` is a table.

### Filter by Type
**✅ CONFIRMED**: The API supports filtering by extmark type using `{ type = "highlight" }`.

Example for highlights:
```lua
local extmarks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    NS_DIFF,
    0,
    -1,
    { details = true, type = "highlight" }
)
```

Example for virtual lines (current implementation):
```lua
local extmarks = vim.api.nvim_buf_get_extmarks(
    bufnr,
    NS_DIFF,
    0,
    -1,
    { details = true, type = "virt_lines" }
)
```

### Source Documentation
- `/opt/homebrew/Cellar/neovim/0.11.5_1/share/nvim/runtime/doc/api.txt`
- Search for `*nvim_buf_get_extmarks()*`

---

## 2. Highlight Extmark Details Structure

### vim.highlight.range() → vim.hl.range()

**IMPORTANT**: `vim.highlight` is deprecated in Neovim. The module is now `vim.hl`.

From `/opt/homebrew/Cellar/neovim/0.11.5_1/share/nvim/runtime/lua/vim/_editor.lua`:
```lua
vim.highlight = vim._defer_deprecated_module('vim.highlight', 'vim.hl')
```

### vim.hl.range() Signature
```lua
vim.hl.range(bufnr, ns, higroup, start, finish, opts?)
```

Parameters:
- `bufnr` (integer): Buffer number to apply highlighting to
- `ns` (integer): Namespace to add highlight to
- `higroup` (string): Highlight group to use for highlighting
- `start` (integer[]|string): Start of region as a (line, column) tuple (0-indexed) or string accepted by `getpos()`
- `finish` (integer[]|string): End of region as a (line, column) tuple (0-indexed) or string accepted by `getpos()`
- `opts?` (vim.hl.range.Opts): Optional parameters
  - `regtype?` (string): Type of range (default: 'v' i.e. charwise)
  - `inclusive?` (boolean): Whether range is end-inclusive (default: false)
  - `priority?` (integer): Highlight priority (default: `vim.hl.priorities.user`)
  - `timeout?` (integer): Time in ms before highlight is cleared (default: -1 no timeout)

### Implementation Details

From `/opt/homebrew/Cellar/neovim/0.11.5_1/share/nvim/runtime/lua/vim/hl.lua`:
- `vim.hl.range()` internally uses `nvim_buf_set_extmark()` to create highlight extmarks
- The function converts 0-indexed positions to 1-indexed for internal use
- Highlights are created as extmarks with `hl_group` attribute

### Extmark Details Structure for Highlights

When querying with `{ details = true, type = "highlight" }`, the details table contains:
- `hl_group` (string): Name of the highlight group (when `hl_name = true`, default)
- `end_row` (integer): Ending line of the mark, 0-based inclusive
- `end_col` (integer): Ending col of the mark, 0-based exclusive
- `priority` (integer): Priority value for the highlight group

Example usage from `/opt/homebrew/Cellar/neovim/0.11.5_1/share/nvim/runtime/lua/vim/diagnostic.lua`:
```lua
vim.hl.range(
    bufnr,
    underline_ns,
    higroup,
    { diagnostic.lnum, diagnostic.col },
    { diagnostic.end_lnum, diagnostic.end_col },
    { priority = get_priority(diagnostic.severity) }
)
```

### Existing Usage in agentic.nvim

From `lua/agentic/utils/diff_highlighter.lua`:
```lua
vim.highlight.range(
    bufnr,
    ns_id,
    Theme.HL_GROUPS.DIFF_DELETE,  -- "AgenticDiffDelete"
    { line_number, 0 },
    { line_number, #old_line }
)
```

This creates a highlight extmark with:
- `hl_group = "AgenticDiffDelete"`
- `end_row = line_number`
- `end_col = #old_line`

---

## 3. Neovim Line/Column Indexing Conventions

### API Indexing (0-indexed)

From `/opt/homebrew/Cellar/neovim/0.11.5_1/share/nvim/runtime/doc/api.txt`:

> Most of the API uses 0-based indices, and ranges are end-exclusive. For the end of a range, -1 denotes the last line/column.

### Functions Using 0-indexed

- `nvim_buf_get_extmarks()` - 0-indexed rows and columns
- `nvim_buf_set_extmark()` - 0-indexed rows and columns
- `nvim_buf_get_lines()` - 0-indexed rows
- `nvim_buf_clear_namespace()` - 0-indexed rows
- `vim.hl.range()` - 0-indexed positions when using tuple form `{row, col}`

### Exceptions (1-indexed lines, 0-indexed columns)

The following use "mark-like" indexing (1-based lines, 0-based columns):
- `nvim_get_mark()`
- `nvim_buf_get_mark()`
- `nvim_buf_set_mark()`
- `nvim_win_get_cursor()` - Returns (row, col) tuple, row is 1-indexed
- `nvim_win_set_cursor()` - Expects (row, col) tuple, row is 1-indexed

### Extmark Position Semantics

From the documentation:

> Extmark position works like a "vertical bar" cursor: it exists between characters.

Example:
```
 f o o b a r      line contents
 0 1 2 3 4 5      character positions (0-based)
0 1 2 3 4 5 6     extmark positions (0-based)
```

### Current Implementation

From `lua/agentic/ui/hunk_navigation.lua`:
```lua
-- Virtual lines appear below anchor (0-indexed)
local anchor_line
if old_count == 0 then
    -- Pure insertion: anchor is line before insertion point
    -- start_line is 1-indexed, -1 for 0-indexed, -1 for line above = -2
    anchor_line = math.max(0, block.start_line - 2)
else
    -- Modification/deletion: anchor is the last deleted line
    -- end_line is 1-indexed, -1 for 0-indexed
    anchor_line = math.max(0, block.end_line - 1)
end
```

---

## 4. Lua Patterns for Deduplicating and Sorting Integer Arrays

### Pattern 1: Set-based Deduplication (Most Efficient)

```lua
local function deduplicate_and_sort(array)
    local set = {}
    for _, value in ipairs(array) do
        set[value] = true
    end
    
    local result = {}
    for value in pairs(set) do
        table.insert(result, value)
    end
    
    table.sort(result)
    return result
end
```

**Pros**: 
- O(n) deduplication using hash table lookup
- Memory efficient for sparse data
- Simple to understand

**Cons**: 
- Iteration order of `pairs()` is not deterministic (but we sort anyway)

### Pattern 2: Sort-then-deduplicate (Used in existing codebase)

```lua
local function deduplicate_and_sort(array)
    table.sort(array)
    
    local result = {}
    local last_value = nil
    for _, value in ipairs(array) do
        if value ~= last_value then
            table.insert(result, value)
            last_value = value
        end
    end
    
    return result
end
```

**Pros**: 
- O(n log n) due to sort, then O(n) for dedup
- Doesn't require extra hash table

**Cons**: 
- Slightly more complex logic

### Pattern 3: Direct Insertion (Current Implementation)

From `lua/agentic/ui/hunk_navigation.lua`:
```lua
local anchors = {}
for _, extmark in ipairs(extmarks) do
    local _, row, _, details = unpack(extmark)
    if details and details.virt_lines and #details.virt_lines > 0 then
        table.insert(anchors, row)
    end
end

table.sort(anchors)
```

**Current behavior**: 
- Inserts all matching rows (may have duplicates if multiple extmarks on same line)
- Sorts array at the end
- No explicit deduplication

### Recommended Pattern for Implementation

For highlight extmarks, use **Pattern 1 (Set-based)** because:
1. Multiple highlight extmarks can exist on the same line (e.g., DIFF_DELETE + DIFF_DELETE_WORD)
2. We need unique line numbers for navigation
3. Set-based deduplication is most efficient and clear

Example implementation:
```lua
function M._get_hunk_anchors(bufnr)
    local state = get_state(bufnr)
    if state.anchors_cache then
        return state.anchors_cache
    end

    local extmarks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        NS_DIFF,
        0,
        -1,
        { details = true, type = "highlight" }
    )

    -- Use set for deduplication (multiple highlights per line)
    local line_set = {}
    for _, extmark in ipairs(extmarks) do
        local _, row, _, details = unpack(extmark)
        if details and details.hl_group and details.hl_group:match("^AgenticDiff") then
            line_set[row] = true
        end
    end

    -- Convert set to sorted array
    local anchors = {}
    for line_number in pairs(line_set) do
        table.insert(anchors, line_number)
    end
    table.sort(anchors)

    state.anchors_cache = anchors
    return anchors
end
```

### Examples from Existing Codebase

From `lua/agentic/ui/hunk_navigation.lua` (line 59):
```lua
table.sort(anchors)
```

From `lua/agentic/ui/tool_call_diff.lua` (line 179):
```lua
table.sort(minimized, function(a, b)
    return a.start_line < b.start_line
end)
```

From `lua/agentic/ui/permission_manager.lua` (line 96):
```lua
table.sort(sorted, function(a, b)
    return a.tracker.timestamp < b.tracker.timestamp
end)
```

---

## 5. Cursor Positioning with Normal Commands

### G Motion

From `/opt/homebrew/Cellar/neovim/0.11.5_1/share/nvim/runtime/doc/motion.txt`:

```
*G*
G           Goto line [count], default last line, on the first
            non-blank character |linewise|.  If 'startofline' not
            set, keep the same column.
            G is one of the |jump-motions|.
```

### :normal Command

From `/opt/homebrew/Cellar/neovim/0.11.5_1/share/nvim/runtime/doc/various.txt`:

```
:norm[al][!] {commands}                 *:norm* *:normal*
            Execute Normal mode commands {commands}.  This makes
            it possible to execute Normal mode commands typed on
            the command-line.  {commands} are executed like they
            are typed.  For undo all commands are undone together.
            Execution stops when an error is encountered.

            If the [!] is given, mappings will not be used.
            Without it, when this command is called from a
            non-remappable mapping (|:noremap|), the argument can
            be mapped anyway.

            {commands} should be a complete command.  If
            {commands} does not finish a command, the last one
            will be aborted as if <Esc> or <C-C> was typed.
```

### Positioning Cursor to Line N, Column 0

**Using `G` motion:**
```lua
-- Go to line N (1-indexed), cursor on first non-blank character
vim.cmd(string.format("normal! %dG", target_line))
```

**Using `gg` for column 0:**
```lua
-- Go to line N (1-indexed), column 0
vim.cmd(string.format("normal! %dgg0", target_line))
```

**Using API (more precise control):**
```lua
-- nvim_win_set_cursor expects (row, col) where row is 1-indexed, col is 0-indexed
vim.api.nvim_win_set_cursor(winid, {target_line, 0})
```

### Current Implementation

From `lua/agentic/ui/hunk_navigation.lua` (line 128):
```lua
vim.cmd(string.format("normal! %dG%s", target_line, scroll_cmd))
```

Where:
- `target_line` is 1-indexed (converted from 0-indexed anchor: `anchors[new_index + 1] + 1`)
- `scroll_cmd` is "zt", "zz", or "" for centering

**Analysis:**
- `%dG` goes to line N, first non-blank character
- If line starts with whitespace, cursor won't be at column 0
- For diff navigation, first non-blank is probably desired behavior
- If column 0 is needed, append `0` to the command: `"%dG0%s"`

### Scrolling Commands

From the documentation:
- `zt` - Position cursor line at top of window
- `zz` - Position cursor line at center of window
- `zb` - Position cursor line at bottom of window

### Recommendation

Current implementation using `normal! %dG%s` is correct:
1. `G` positions to line N (1-indexed)
2. Goes to first non-blank character (desired for code navigation)
3. Appends scroll command (`zt` or `zz`) for centering
4. Uses `!` to avoid triggering user mappings

If column 0 is explicitly needed:
```lua
vim.cmd(string.format("normal! %dG0%s", target_line, scroll_cmd))
```

---

## Summary of Key Findings

1. **✅ CONFIRMED**: `nvim_buf_get_extmarks()` supports `{ type = "highlight" }` filter
2. **✅ CONFIRMED**: Highlight extmarks have `details.hl_group` field containing highlight group name
3. **✅ CONFIRMED**: Neovim API uses 0-indexed lines/columns (except cursor/mark functions which use 1-indexed lines)
4. **✅ RECOMMENDED**: Use set-based deduplication for line numbers due to multiple highlights per line
5. **✅ CONFIRMED**: Current `normal! %dG%s` implementation is correct for navigation

## Implementation Notes

### Compatibility Check
- Neovim v0.11.0+: ✅ All APIs confirmed available
- LuaJIT 2.1 (Lua 5.1): ✅ No Lua 5.2+ features required
- `vim.highlight.range`: ⚠️ Deprecated, but aliased to `vim.hl.range` (still works)

### Breaking Changes
None identified. The implementation uses stable APIs available in Neovim v0.11.0+.

### Performance Considerations
- Set-based deduplication is O(n) with hash table lookups
- Filtering by `type = "highlight"` reduces extmark processing overhead
- Caching strategy already in place (`state.anchors_cache`)
