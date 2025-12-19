# Default tools; override like: make NVIM=/opt/homebrew/bin/nvim
NVIM     ?= nvim
LUALS    ?= $(shell which lua-language-server 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/lua-language-server")
LUACHECK ?= luacheck
STYLUA   ?= stylua

export VIMRUNTIME := $(strip $(shell \
	"$(NVIM)" --headless -c 'echo $$VIMRUNTIME' -c q 2>&1 \
))

# Bail out if still empty
ifeq ($(VIMRUNTIME),)
$(error Could not determine VIMRUNTIME. Check that '$(NVIM)' is on PATH and runnable)
endif

PROJECT ?= lua/
LOGDIR  ?= .luals-log

.PHONY: print-vimruntime luals luacheck format-check format check clean-luals-log

print-vimruntime:
	@echo "VIMRUNTIME=$(VIMRUNTIME)"

# Lua Language Server headless diagnosis report
luals:
	"$(LUALS)" --check "$(PROJECT)" --checklevel=Warning --configpath="$(CURDIR)/.luarc.json"

# Luacheck linter
luacheck:
	"$(LUACHECK)" .

# StyLua formatting check
format-check:
	"$(STYLUA)" --check .

# StyLua formatting (apply)
format:
	"$(STYLUA)" .

# Convenience aggregator
check: luals luacheck format-check