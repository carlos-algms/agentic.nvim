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
	total_start=$$(date +%s); \
	start=$$(date +%s); \
	make format > .local/agentic_format_output.log 2>&1; \
	rc_format=$$?; \
	echo "format: $$rc_format (took $$(($$(date +%s) - start))s) - log: .local/agentic_format_output.log"; \
	start=$$(date +%s); \
	make luals > .local/agentic_luals_output.log 2>&1; \
	rc_luals=$$?; \
	echo "luals: $$rc_luals (took $$(($$(date +%s) - start))s) - log: .local/agentic_luals_output.log"; \
	start=$$(date +%s); \
	make luacheck > .local/agentic_luacheck_output.log 2>&1; \
	rc_luacheck=$$?; \
	echo "luacheck: $$rc_luacheck (took $$(($$(date +%s) - start))s) - log: .local/agentic_luacheck_output.log"; \
	start=$$(date +%s); \
	make test > .local/agentic_test_output.log 2>&1; \
	rc_test=$$?; \
	echo "test: $$rc_test (took $$(($$(date +%s) - start))s) - log: .local/agentic_test_output.log"; \
	echo "Total: $$(($$(date +%s) - total_start))s"; \
	if [ $$rc_format -ne 0 ] || [ $$rc_luals -ne 0 ] || [ $$rc_luacheck -ne 0 ] || [ $$rc_test -ne 0 ]; then \
		echo "Validation failed! Check log files for details."; \
		exit 1; \
	fi

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