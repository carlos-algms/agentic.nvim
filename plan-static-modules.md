# Static Module Conversion Analysis

Investigation of SessionManager's child classes for potential conversion to
static modules using `vim.b`, `vim.w`, or `vim.t` for state storage.

## Summary Table

| Module            | Difficulty      | Recommendation     | Primary Blocker       |
| ----------------- | --------------- | ------------------ | --------------------- |
| SlashCommands     | **Easy**        | ✅ Recommended     | None                  |
| FilePicker        | **Medium**      | ✅ Feasible        | Closure state (minor) |
| AgentModes        | **Medium**      | ⚠️ Partial         | Callback storage      |
| FileList          | **Medium**      | ❌ Not recommended | Callback storage      |
| CodeSelection     | **Medium**      | ❌ Not recommended | Callback storage      |
| MessageWriter     | **Medium-Hard** | ❌ Not recommended | Complex nested state  |
| PermissionManager | **Hard**        | ❌ Not recommended | Callback queue        |
| StatusAnimation   | **Hard**        | ❌ Not recommended | Timer userdata        |

---

## Easy Conversions

### 1. SlashCommands ✅

**Current state:**

- `commands` - Array of completion items
- `instances_by_buffer` - Module-level weak map (workaround for `complete_func`)

**Why easy:**

- Single property (`commands`) that's a simple array
- Already uses buffer-local settings (`vim.bo[bufnr]`)
- `instances_by_buffer` hack would be eliminated

**Conversion example:**

```lua
-- Before
function SlashCommands:new(bufnr)
    self = setmetatable({ commands = {} }, self)
    instances_by_buffer[bufnr] = self
    return self
end

function SlashCommands:setCommands(commands)
    self.commands = commands
end

-- After
function SlashCommands.setup(bufnr)
    vim.b[bufnr].agentic_slash_commands = {}
    -- setup completion...
end

function SlashCommands.setCommands(bufnr, commands)
    vim.b[bufnr].agentic_slash_commands = commands
end

function SlashCommands.complete_func(findstart, _base)
    if findstart == 1 then return 1 end
    local bufnr = vim.api.nvim_get_current_buf()
    return vim.b[bufnr].agentic_slash_commands or {}
end
```

**SessionManager change:**

```lua
-- Before
self.slash_commands = SlashCommands:new(self.widget.buf_nrs.input)

-- After
SlashCommands.setup(self.widget.buf_nrs.input)
-- Store bufnr for later calls
self._input_bufnr = self.widget.buf_nrs.input
```

---

## Medium Conversions

### 2. FilePicker ⚠️

**Current state:**

- `_files` - Cached file list
- `instances_by_buffer` - Module-level weak map
- Closure state: `last_at_pos`, `prev_tab_map`, `prev_cr_map`

**Why medium:**

- Single main property, but has closure-captured state in `_setup_completion`
- Closure state can remain as closures (already buffer-isolated via autocmd)

**Conversion example:**

```lua
-- Before
function FilePicker:scan_files()
    -- ...
    self._files = files
end

-- After
function FilePicker.scan_files(bufnr)
    -- ...
    vim.b[bufnr].agentic_file_picker_files = files
end

function FilePicker.setup(bufnr)
    vim.b[bufnr].agentic_file_picker_files = {}
    -- Closure state can stay in closures since autocmd is buffer-local
end
```

---

### 3. AgentModes ⚠️ (Partial)

**Current state:**

- `_modes` - Array of available modes
- `current_mode_id` - Currently active mode
- `_set_mode_callback` - Callback to SessionManager

**Why medium:**

- Data (`_modes`, `current_mode_id`) fits `vim.t[tabpage]` naturally
- Callback is the blocker - cannot store functions in `vim.t`

**Hybrid approach:**

```lua
-- Data in vim.t
function AgentModes.set_modes(tabpage, modes_info)
    vim.t[tabpage].agentic_modes = modes_info.availableModes
    vim.t[tabpage].agentic_current_mode_id = modes_info.currentModeId
end

function AgentModes.get_mode(tabpage, mode_id)
    local modes = vim.t[tabpage].agentic_modes or {}
    for _, mode in ipairs(modes) do
        if mode.id == mode_id then return mode end
    end
end

-- Callback passed as parameter each time
function AgentModes.show_mode_selector(tabpage, set_mode_callback)
    local modes = vim.t[tabpage].agentic_modes or {}
    -- ... vim.ui.select using set_mode_callback
end
```

**SessionManager change:**

```lua
-- Before
self.agent_modes = AgentModes:new(self.widget.buf_nrs, function(mode_id)
    self:_handle_mode_change(mode_id)
end)

-- After
AgentModes.setup_keybindings(self.widget.buf_nrs, self.tab_page_id, function(mode_id)
    self:_handle_mode_change(mode_id)
end)
-- Direct access: vim.t[self.tab_page_id].agentic_current_mode_id
```

---

## Not Recommended Conversions

### 4. FileList ❌

**Blocker:** `_on_change` callback cannot be stored in `vim.b`

**Current state:**

- `_files` - Array of file paths (serializable ✅)
- `_bufnr` - Buffer number
- `_on_change` - Callback to SessionManager (not serializable ❌)

**Why not recommended:**

- Would require callback registry pattern, adding complexity without benefit
- Current instance-based approach already provides buffer isolation

---

### 5. CodeSelection ❌

**Blocker:** Same as FileList - callback storage

**Current state:**

- `_selections` - Array of selections (serializable ✅)
- `_bufnr` - Buffer number
- `_on_change` - Callback (not serializable ❌)

**Why not recommended:**

- Same pattern as FileList
- Converting one without the other creates inconsistency

---

### 6. MessageWriter ❌

**Blockers:**

- `tool_call_blocks` - Frequently mutated nested tables with reference semantics
- High-frequency state access during streaming

**Current state:**

- `bufnr` - Buffer number
- `tool_call_blocks` - Complex nested state (tool call tracking)
- `_last_message_type` - Simple string

**Why not recommended:**

- `vim.b` serializes tables on every access (performance hit)
- Reference semantics lost - must read-modify-write entire table
- Already buffer-scoped, no isolation benefit from conversion

---

### 7. PermissionManager ❌

**Blocker:** Core functionality depends on callback queue

**Current state:**

- `queue` - Array of `{toolCallId, request, callback}` (callbacks ❌)
- `current_request` - Contains callback function (❌)
- `message_writer` - External dependency
- `keymap_info` - Serializable (but minor)

**Why not recommended:**

- Primary purpose is managing async queue with callbacks
- Functions are fundamentally not serializable in `vim.b`/`vim.t`

---

### 8. StatusAnimation ❌

**Blocker:** Timer userdata cannot be stored in `vim.b`

**Current state:**

- `_bufnr` - Buffer number
- `_state` - Animation state string (serializable ✅)
- `_spinner_idx` - Frame index (serializable ✅)
- `_extmark_id` - Extmark ID (serializable ✅)
- `_next_frame_handle` - **Timer userdata** (not serializable ❌)

**Why not recommended:**

- `vim.defer_fn` returns `uv.uv_timer_t` userdata
- Userdata cannot be stored in `vim.b`
- Timer handle needed for `.stop()` and `.close()` calls

---

## Common Blockers

### 1. Callback Functions

Most classes use callbacks for change notifications. `vim.b`/`vim.w`/`vim.t`
only store serializable values (strings, numbers, booleans, tables of
primitives).

**Workarounds (all add complexity):**

- Module-level callback registry keyed by bufnr/tabpage
- Event-based pattern with `nvim_exec_autocmds`
- Return-value pattern (caller handles side effects)

### 2. Userdata (Timers, etc.)

Neovim userdata objects (timers, handles) cannot be stored in scoped variables.

### 3. Reference Semantics

`vim.b` creates copies on read. Code relying on in-place mutations needs
refactoring to read-modify-write pattern.

---

## Recommended Approach

1. **Convert SlashCommands first** - Easiest win, eliminates
   `instances_by_buffer` hack
2. **Consider FilePicker** - Similar pattern, medium effort
3. **Leave callback-based classes as instances** - The callback pattern is
   appropriate for their use cases
4. **Leave timer-based classes as instances** - Userdata storage is a
   fundamental limitation

The current architecture is actually well-designed for its requirements. Most
classes are already buffer/tabpage-scoped through instance ownership. Converting
to static modules would trade one form of state management for another without
significant simplification.
