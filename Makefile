# Default tools; override like: make NVIM=/opt/homebrew/bin/nvim
NVIM     ?= nvim
LUALS    ?= $(shell which lua-language-server 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/lua-language-server")
SELENE   ?= $(shell which selene 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/selene")
STYLUA   ?= $(shell which stylua 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/stylua")

PROJECT ?= lua/ tests/
LOGDIR  ?= .luals-log

.PHONY: luals selene selene-file format-check format format-file check test validate install-hooks

test:
	$(NVIM) --headless -i NONE -n -u tests/init.lua -c "lua require('tests.runner').run()"

test-file:
	$(NVIM) --headless -i NONE -n -u tests/init.lua -c "lua require('tests.runner').run_file('$(FILE)')"

# Lua Language Server headless diagnosis report
luals:
	@VIMRUNTIME=$${VIMRUNTIME:-$$($(NVIM) --headless -i NONE -n -u NONE -c 'lua io.stdout:write(vim.env.VIMRUNTIME or "")' -c q 2>/dev/null)}; \
	if [ -z "$$VIMRUNTIME" ]; then \
		echo "Error: Could not determine VIMRUNTIME. Check that '$(NVIM)' is on PATH and runnable" >&2; \
		exit 1; \
	fi; \
	for dir in $(PROJECT); do \
		echo "Checking $$dir..."; \
		VIMRUNTIME="$$VIMRUNTIME" "$(LUALS)" --check "$$dir" --checklevel=Warning --configpath="$(CURDIR)/.luarc.json" || exit 1; \
	done

# Selene linter
selene:
	"$(SELENE)" .

# Selene a specific file
selene-file:
	"$(SELENE)" "$(FILE)"

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
check: format-check luals selene

# Run all validations with output redirection for AI agents
# format runs first (it rewrites files); luals/selene/test then run in parallel
# since they only read. Each parallel job records its rc to a sentinel file.
validate:
	@mkdir -p .local; \
	total_start=$$(date +%s); \
	start=$$(date +%s); \
	$(MAKE) format > .local/agentic_format_output.log 2>&1; \
	rc_format=$$?; \
	echo "format: $$rc_format (took $$(($$(date +%s) - start))s) - log: .local/agentic_format_output.log"; \
	for t in luals selene test; do \
		( start=$$(date +%s); \
		  $(MAKE) $$t > .local/agentic_$${t}_output.log 2>&1; \
		  rc=$$?; \
		  echo "$$rc $$(($$(date +%s) - start))" > .local/agentic_$${t}.rc; \
		  echo "$$t: $$rc (took $$(($$(date +%s) - start))s) - log: .local/agentic_$${t}_output.log" ) & \
	done; \
	wait; \
	echo "Total: $$(($$(date +%s) - total_start))s"; \
	rc_rest=0; \
	for t in luals selene test; do \
		rc=$$(cut -d' ' -f1 .local/agentic_$${t}.rc); \
		[ "$$rc" -ne 0 ] && rc_rest=1; \
		rm -f .local/agentic_$${t}.rc; \
	done; \
	if [ $$rc_format -ne 0 ] || [ $$rc_rest -ne 0 ]; then \
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
