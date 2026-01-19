# Default tools; override like: make NVIM=/opt/homebrew/bin/nvim
NVIM     ?= nvim
LUALS    ?= $(shell which lua-language-server 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/lua-language-server")
LUACHECK ?= $(shell which luacheck 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/luacheck")
STYLUA   ?= $(shell which stylua 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/stylua")

PROJECT ?= lua/ tests/
LOGDIR  ?= .luals-log

.PHONY: luals luacheck luacheck-file format-check format format-file check test validate install-hooks

test:
	$(NVIM) --headless -u tests/init.lua -c "lua require('tests.runner').run()"

test-verbose:
	$(NVIM) --headless -u tests/init.lua -c "lua require('tests.runner').run({verbose = true})"

test-file:
	$(NVIM) --headless -u tests/init.lua -c "lua require('tests.runner').run_file('$(FILE)')"

# Lua Language Server headless diagnosis report
luals:
	@VIMRUNTIME=$$($(NVIM) --headless -c 'echo $$VIMRUNTIME' -c q 2>&1); \
	if [ -z "$$VIMRUNTIME" ]; then \
		echo "Error: Could not determine VIMRUNTIME. Check that '$(NVIM)' is on PATH and runnable" >&2; \
		exit 1; \
	fi; \
	for dir in $(PROJECT); do \
		echo "Checking $$dir..."; \
		VIMRUNTIME="$$VIMRUNTIME" "$(LUALS)" --check "$$dir" --checklevel=Warning --configpath="$(CURDIR)/.luarc.json" || exit 1; \
	done

# Luacheck linter
luacheck:
	"$(LUACHECK)" .

# Luacheck a specific file
luacheck-file:
	"$(LUACHECK)" "$(FILE)"

# StyLua formatting check
format-check:
	"$(STYLUA)" --check .

# StyLua formatting (apply)
format:
	"$(STYLUA)" .

# Format a specific file
format-file:
	"$(STYLUA)" "$(FILE)"

# Convenience aggregator, NOT to be used in the CI
check: luals luacheck format-check

# Run all validations with output redirection for AI agents
validate:
	@mkdir -p .local; \
	make luals > .local/agentic_luals_output.log 2>&1; echo "luals: $$?"; \
	make luacheck > .local/agentic_luacheck_output.log 2>&1; echo "luacheck: $$?"; \
	make test > .local/agentic_test_output.log 2>&1; echo "test: $$?"

# Install pre-commit hook locally
install-git-hooks:
	@mkdir -p .git/hooks
	@printf '%s\n' \
		'#!/bin/sh' \
		'set -e' \
		'STYLUA=$$(which stylua 2>/dev/null || echo "$$HOME/.local/share/nvim/mason/bin/stylua")' \
		'STAGED_LUA_FILES=$$(git diff --cached --name-only --diff-filter=ACM | grep "\.lua$$" || true)' \
		'if [ -n "$$STAGED_LUA_FILES" ]; then' \
		'  echo "Running stylua on staged files..."' \
		'  "$$STYLUA" $$STAGED_LUA_FILES' \
		'  git add $$STAGED_LUA_FILES' \
		'fi' \
		> .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "Pre-commit hook installed successfully"
