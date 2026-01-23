# Change: Add Dynamic Height Calculation for Code Selection Window

## Why

The code selection window currently uses a fixed height of 15 lines, which wastes vertical space when showing small snippets (e.g., 3 lines) and truncates larger snippets unnecessarily. This inconsistency creates a poor user experience compared to the todos window, which already implements dynamic sizing.

Additionally, both the code and todos windows use the same height calculation logic (`line_count + 1, capped at max_height`), which violates DRY principles and creates maintenance overhead.

## What Changes

- Add `max_height` configuration option for the code selection window in `config_default.lua`
- **Extract height calculation into reusable helper method** `_calculate_dynamic_height(bufnr, max_height)` 
- Refactor todos window to use the new helper method (eliminate code duplication)
- Implement dynamic height for code window using the same helper method
- Add comprehensive unit tests for the height calculation logic

## Impact

- **Affected specs**: `ui-layout` (new capability)
- **Affected code**:
  - `lua/agentic/config_default.lua` - Add `windows.code.max_height` field
  - `lua/agentic/ui/chat_widget.lua` - Add `_calculate_dynamic_height()` helper, refactor both windows to use it
- **Code quality**: Eliminates duplication, centralizes height calculation logic
