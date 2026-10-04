---
name: agentic-vimdoc
description:
  Use when writing or updating agentic.nvim vimdoc (doc/agentic.txt), or after
  changing init.lua, config_default.lua, theme.lua, or README install/keymaps -
  those edits require a matching vimdoc update. Covers the sync table, format
  rules, and the helptags regeneration command.
---

# Vimdoc (`doc/agentic.txt`)

Manually written, NOT auto-generated.

## When vimdoc MUST be updated

| Source file                      | Vimdoc section to update            |
| -------------------------------- | ----------------------------------- |
| `lua/agentic/init.lua`           | Usage (public API functions)        |
| `lua/agentic/config_default.lua` | Configuration, Customization        |
| `lua/agentic/theme.lua`          | Customization (highlight groups)    |
| `README.md` (install/keymaps)    | Installation, Keymaps, Integrations |

## New highlight group

1. Add the name to the `Theme.HL_GROUPS` constant in `lua/agentic/theme.lua`
2. Define its default in `Theme.setup()`
3. Update README.md "Customization (Ricing)": code example and table row
4. Update the vimdoc Customization section

## Format rules

- 78-char width.
- Right-aligned tags `*agentic-section*`.
- Code blocks `>lua` / `<`.
- Function tags `*agentic.function_name()*`.
- Cross-refs `|agentic-section|`.
- Modeline `vim:tw=78:ts=8:ft=help:norl:`.

After editing:

```bash
timeout 5 nvim --headless -c "helptags doc/" -c "quit"
```
