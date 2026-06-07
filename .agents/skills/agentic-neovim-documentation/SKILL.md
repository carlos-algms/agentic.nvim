---
name: agentic-neovim-documentation
description:
  Use when neovim documentation is needed for the current task or the user asks
  for specific neovim features or neovim lua apis. It gives instructions on how
  to read current Neovim's documentation locally and offline, and also how to
  read online if it fails
---

# Neovim Documentation Files and help docs

**CRITICAL**: Do NOT run `nvim --headless` or any other `nvim` command to read
help documentation. Use direct file access instead.

Exception: regenerating helptags after a vimdoc edit is allowed and required by
`AGENTS.md` — `timeout 5 nvim --headless -c "helptags doc/" -c "quit"`. That
writes tags, it does not read docs.

**Why:** Running `nvim` commands can hang, cause race conditions, or interfere
with development environment.

## Neovim Documentation Lookup Strategy:

Always prefer reading local documentation files directly from the Neovim runtime
path, because they reflect the exact version installed on the system.

Common path patterns for discovery:

- **macOS (Homebrew):**
  - Runtime docs: `/opt/homebrew/Cellar/neovim/*/share/nvim/runtime/doc/`
  - Note: We don't need the exact version, just use the wildcard `*` to match
    the installed version
- **Linux (Snap):** `/snap/nvim/current/usr/bin/nvim`
  - Runtime docs: `/snap/nvim/current/usr/share/nvim/runtime/doc/`

**If local lookup fails:** Use GitHub raw URLs (least preferred)

```
https://raw.githubusercontent.com/neovim/neovim/refs/tags/v<version>/runtime/doc/<doc-name>.txt
```

**Tip:** Do not assume a file contains what you need, use `rg`, or `grep` on the
`runtime/doc` folder to find the file containing needed info.
