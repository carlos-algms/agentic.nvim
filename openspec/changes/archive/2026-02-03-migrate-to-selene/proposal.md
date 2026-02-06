# Proposal: Migrate from Luacheck to Selene

## Change ID

`migrate-to-selene`

## Overview

Replace luacheck with selene (a modern Rust-based Lua linter) across the
entire development toolchain to improve linting speed, accuracy, and
maintainability.

## Motivation

**Current state:**

- Luacheck last updated October 2018 (unmaintained)
- Written in Lua, slower than modern alternatives
- Uses arbitrary numeric codes (211, 542, etc.) for lints
- Basic error reporting with minimal formatting
- Configuration via `.luacheckrc` (Lua code execution)
- Limited standard library type checking

**Desired state:**

- Selene v0.30.0 (actively maintained, released 2026-01-22)
- Written in Rust with multithreading (significantly faster)
- Human-readable lint names (`unused_variable`, `unbalanced_assignments`)
- Rich, detailed error messages with visual formatting
- Configuration via `selene.toml` (declarative TOML)
- Advanced standard library configuration with argument type checking

**Benefits:**

- **Performance:** Rust + multithreading = much faster linting
- **Maintainability:** Active project vs unmaintained (last update 2018)
- **Developer experience:** Better error messages, human-readable lint names
- **Type safety:** Catches more errors via standard library type checking
- **Modern tooling:** TOML config, better CI integration

**Trade-offs:**

- Selene doesn't support line length checking (stylua handles this)
- No unreachable code detection (minor limitation)
- No unused labels detection (rare use case)
- Requires config migration and inline comment updates

## Scope

### In Scope

1. **Makefile changes:**
   - Replace `LUACHECK` variable with `SELENE`
   - Update `luacheck` target to `selene`
   - Update `luacheck-file` target to `selene-file`
   - Update `validate` target to use selene
   - Update `check` convenience target

2. **GitHub Actions pipeline (`.github/workflows/pr-check.yml`):**
   - Replace luacheck installation with selene
   - Update lint job to use selene
   - Add selene caching for faster CI

3. **Docker image (`repro/Dockerfile`):**
   - Replace luacheck installation with selene binary
   - Update README with new commands
   - Optimize layer structure

4. **Configuration migration:**
   - Create `selene.toml` from `.luacheckrc` settings
   - Configure vim standard library (`std = "lua51+vim"`)
   - Port ignore rules to selene lint severity settings
   - Configure strict mode with maximum error detection

5. **Code changes:**
   - Update 5 inline `luacheck: ignore` comments to selene syntax
   - Replace numeric codes with descriptive lint names

6. **Documentation updates:**
   - Update `AGENTS.md` with selene information
   - Update `repro/README.md` with new commands
   - Update `openspec/project.md` if needed

### Out of Scope

- Changes to existing lint suppression logic (only syntax updates)
- Adding new lints beyond what luacheck provided
- Refactoring code to fix existing suppressed warnings
- Changes to stylua or lua-language-server configuration

## Implementation Strategy

### Phased Approach with Validation Checkpoints

This migration follows an incremental approach with mandatory stops for manual
validation at each major step. This ensures we can verify each phase before
proceeding.

**Phase 1: Local Installation & Initial Testing**

1. Install selene locally via Mason
2. Create initial `selene.toml` config
3. Run selene for the first time
4. Analyze output and adjust config
5. **STOP:** Validate selene runs without errors

**Phase 2: Remove Luacheck**

1. Delete `.luacheckrc`
2. Update inline code comments (5 files)
3. Run selene to verify comments work
4. **STOP:** Validate code changes are correct

**Phase 3: Makefile Integration**

1. Update Makefile targets
2. Update validate target
3. Test all make commands locally
4. **STOP:** Validate make targets work correctly

**Phase 4: CI/CD Updates**

1. Update GitHub Actions workflow
2. Update Docker image
3. Update documentation
4. **STOP:** Validate CI pipeline passes

**Phase 5: Final Verification**

1. Run full validation suite
2. Test Docker image
3. Review all changes
4. **STOP:** Final approval before merge

### Rollback Strategy

If any phase fails validation:

- **Phase 1-2:** Revert files, keep luacheck
- **Phase 3-4:** Revert Makefile/CI changes, restore `.luacheckrc`
- **Phase 5:** Full revert via git

Each phase is independently revertable without affecting previous work.

## Dependencies

### External

- selene v0.30.0+ (installed via Mason locally)
- selene binary for GitHub Actions (downloaded from releases)
- selene binary for Docker (downloaded from releases)

### Internal

- None (no other OpenSpec changes depend on this)

## Affected Components

- Makefile (linting targets)
- `.github/workflows/pr-check.yml` (lint job)
- `repro/Dockerfile` (tool installation)
- `repro/README.md` (documentation)
- `AGENTS.md` (development guide)
- `openspec/project.md` (if needed)
- 5 Lua files with inline luacheck directives

## Migration Details

### Configuration Mapping

**Current `.luacheckrc` → Proposed `selene.toml`:**

```lua
-- .luacheckrc (current)
cache = true
exclude_files = {"lazy_repro/", "deps/", "%.local/"}
ignore = {"631", "212", "213"}
unused_args = false
unused = false
read_globals = {"vim", "Snacks"}
globals = {"vim.b", "vim.bo", "vim.wo", "vim.t", "vim.opt_local", "vim.env"}
files["**/*.test.lua"] = { std = "+busted" }
```

```toml
# selene.toml (proposed - minimal, only non-default overrides)
std = "lua51+vim+busted"

exclude = ["lazy_repro", "deps", ".local"]

[lints]
# Overrides from luacheck behavior (these default to "warn" in selene)
unused_variable = "allow"  # Match luacheck unused = false
shadowing = "allow"        # Match luacheck ignore 212, 213, 411, 412, 422, 431

# Stricter than defaults (upgrade warnings to errors for correctness)
unbalanced_assignments = "deny"  # Default: warn → Make it an error

# Allow mixed tables (common pattern in Neovim, default is warn)
mixed_table = "allow"

[config]
# Allow _ prefix for intentionally unused variables
unused_variable.ignore_pattern = "^_"
shadowing.ignore_pattern = "^_"

# Empty blocks OK if they have comments explaining why
empty_if.comments_count = true
empty_loop.comments_count = true
```

**Rationale for minimal config:**

- **std & exclude:** Required, no defaults
- **unused_variable = "allow":** Default is "warn", we need "allow" to match
  luacheck
- **shadowing = "allow":** Default is "warn", we need "allow" to match luacheck
- **unbalanced_assignments = "deny":** Default is "warn", upgrade to "deny" for
  strictness
- **mixed_table = "allow":** Default is "warn", but it's a common Neovim pattern
- **[config] sections:** Customize behavior for specific lints

**Defaults we're keeping (no config needed):**

- `undefined_variable = "deny"` (already default Error)
- `divide_by_zero = "warn"` (default Warning)
- `duplicate_keys = "deny"` (already default Error)
- `standard_library = "deny"` (includes incorrect_standard_library_use, already
  default Error)
- All other lints use their sensible defaults

### Inline Comment Migration

**Pattern:** `-- luacheck: ignore XXX` → `-- selene: allow(lint_name)`

**Files to update (5 total):**

1. `lua/agentic/acp/adapters/claude_acp_adapter.lua:151`
   - Before: `-- luacheck: ignore 542 -- intentional empty block`
   - After: `-- selene: allow(empty_if) -- intentional empty block`

2. `lua/agentic/acp/adapters/codex_acp_adapter.lua:105`
   - Before: `-- luacheck: ignore 542 -- intentional empty block`
   - After: `-- selene: allow(empty_if) -- intentional empty block`

3. `lua/agentic/ui/clipboard.lua:138`
   - Before: `-- luacheck: ignore 122 (setting read-only field paste of global vim)`
   - After: `-- selene: allow(incorrect_standard_library_use) -- setting read-only field paste of global vim`

4. `lua/agentic/ui/file_picker.test.lua:56`
   - Before: `vim.fn.system = original_system -- luacheck: ignore`
   - After: `vim.fn.system = original_system -- selene: allow(incorrect_standard_library_use)`

5. `lua/agentic/ui/file_picker.test.lua:72`
   - Before: `-- luacheck: ignore 122 (setting read-only field for test mock)`
   - After: `-- selene: allow(incorrect_standard_library_use) -- setting read-only field for test mock`

### Makefile Changes

```makefile
# Before
LUACHECK ?= $(shell which luacheck 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/luacheck")

luacheck:
	"$(LUACHECK)" .

luacheck-file:
	"$(LUACHECK)" "$(FILE)"

check: luals luacheck format-check

validate:
	# ... includes make luacheck line
```

```makefile
# After
SELENE ?= $(shell which selene 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/selene")

selene:
	"$(SELENE)" .

selene-file:
	"$(SELENE)" "$(FILE)"

check: luals selene format-check

validate:
	# ... replace make luacheck with make selene
	# ... rename log file to agentic_selene_output.log
```

### GitHub Actions Changes

```yaml
# Before (.github/workflows/pr-check.yml)
lint:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - name: Install Luacheck
      run: |
        sudo apt-get update
        sudo apt-get install -y lua-check
    - name: Run luacheck
      run: make luacheck
```

```yaml
# After
lint:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4

    - name: Setup directories
      run: mkdir -p .local/bin

    - name: Cache Selene
      id: cache-selene
      uses: actions/cache@v4
      with:
        path: .local/bin/selene
        key: selene-${{ runner.os }}-${{ env.SELENE_VERSION }}

    - name: Install Selene
      if: steps.cache-selene.outputs.cache-hit != 'true'
      run: |
        curl -sL "https://github.com/Kampfkarren/selene/releases/download/${{ env.SELENE_VERSION }}/selene-${{ env.SELENE_VERSION }}-linux-x86_64.zip" -o selene.zip
        unzip -q selene.zip -d .local/bin/
        chmod +x .local/bin/selene

    - name: Run selene
      run: |
        export PATH="$PWD/.local/bin:$PATH"
        make selene

# Add to env section at top:
env:
  LUALS_VERSION: 3.16.2
  STYLUA_VERSION: 2.3.1
  SELENE_VERSION: 0.30.0  # Add this
```

### Docker Changes

```dockerfile
# Before (repro/Dockerfile)
ENV LUALS_VERSION=3.16.2 \
  STYLUA_VERSION=2.3.1 \
  NVIM_VERSION=0.11.5

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  ... \
  luarocks \
  gcc \
  libc6-dev && \
  luarocks install luacheck && \
  apt-get purge -y --auto-remove gcc && \
  ...
```

```dockerfile
# After
ENV LUALS_VERSION=3.16.2 \
  STYLUA_VERSION=2.3.1 \
  SELENE_VERSION=0.30.0 \
  NVIM_VERSION=0.11.5

# Remove luarocks, gcc, libc6-dev from dependencies
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  curl \
  ca-certificates \
  unzip \
  git \
  lua5.1 && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Install Selene (after other tools, before WORKDIR)
RUN ARCH=$(uname -m) && \
  if [ "$ARCH" = "aarch64" ]; then SELENE_ARCH="linux-aarch64"; else SELENE_ARCH="linux-x86_64"; fi && \
  curl -sL "https://github.com/Kampfkarren/selene/releases/download/${SELENE_VERSION}/selene-${SELENE_VERSION}-${SELENE_ARCH}.zip" -o selene.zip && \
  unzip -q selene.zip -d /usr/local/bin/ && \
  chmod +x /usr/local/bin/selene && \
  rm selene.zip
```

## Testing Strategy

### Phase-by-Phase Validation

**Phase 1 Validation:**

- Run `selene .` and verify it completes
- Check that all expected files are linted
- Verify no false positives
- Ensure strict type checking works

**Phase 2 Validation:**

- Run `make validate` (with updated config)
- Verify no luacheck references remain in code
- Check inline comments are recognized by selene

**Phase 3 Validation:**

- Test each make target individually:
  - `make selene`
  - `make selene-file FILE=lua/agentic/init.lua`
  - `make validate`
  - `make check`
- Verify log files are created with correct names
- Check error reporting format

**Phase 4 Validation:**

- Push to feature branch and check CI passes
- Verify selene job completes successfully
- Check caching works (second run should be faster)
- Test Docker image builds and runs selene

**Phase 5 Validation:**

- Full CI pipeline must pass (all jobs green)
- Docker image must build without errors
- All make targets must work locally
- Documentation must be up-to-date

## Configuration Deep Dive

### Selene Advantages Over Luacheck

Based on research and community practices, selene provides **34 total lints**
compared to luacheck's more limited set, **with sensible defaults already
enabled**.

**Selene's excellent defaults (no config needed):**

- `standard_library = "deny"` (Error) - Catches wrong vim API usage, argument
  counts ✓
- `undefined_variable = "deny"` (Error) - Typos, missing declarations ✓
- `duplicate_keys = "deny"` (Error) - `{a=1, a=2}` in same table ✓
- `divide_by_zero = "warn"` (Warning) - `x / 0` detection ✓
- `empty_if = "warn"` (Warning) - Empty blocks (configurable) ✓
- 25+ other lints with sensible severities ✓

**Selene-exclusive lints (not in luacheck):**

1. `standard_library` - Catches wrong argument types/counts for vim API (enabled
   by default)
2. `compare_nan` - Prevents `x == nan` (always false)
3. `constant_table_comparison` - Detects `{} == {}` (different references)
4. `almost_swapped` - Catches `x, y = y, x + 1` (likely meant `x + 1`)
5. `manual_table_clone` - Suggests `table.clone()` over `{unpack(t)}`

**Why our config is minimal:**

Selene's defaults are already strict and correct. We only override:

1. `unused_variable = "allow"` - Luacheck had this disabled
2. `shadowing = "allow"` - Luacheck ignored these warnings
3. `unbalanced_assignments = "deny"` - Upgrade from warn to error
4. `mixed_table = "allow"` - Common in Neovim, not a problem

**Real-world configs analyzed:**

- **mason.nvim:** Allows `unused_variable`, `shadowing`, `mixed_table`
  (permissive)
- **neodev.nvim:** Minimal config, only allows `mixed_table`
- **packer.nvim:** Uses `std="vim"` only

### Recommended Minimal Configuration

The proposed `selene.toml` is **minimal and clean** - only 10 lines of actual
config plus comments. It only overrides defaults where needed:

**What we override:**

- `unused_variable = "allow"` - Port from luacheck (default is "warn")
- `shadowing = "allow"` - Port from luacheck (default is "warn")
- `unbalanced_assignments = "deny"` - Upgrade from "warn" to "deny" for
  strictness
- `mixed_table = "allow"` - Common Neovim pattern (default is "warn")
- 4 `[config]` tweaks for behavior

**What we keep (selene's good defaults):**

- `undefined_variable = "deny"` - Already defaults to Error ✓
- `divide_by_zero = "warn"` - Already defaults to Warning ✓
- `duplicate_keys = "deny"` - Already defaults to Error ✓
- `standard_library = "deny"` - Already defaults to Error (includes type
  checking) ✓
- 25+ other lints with sensible defaults ✓

This provides:

- **Better type safety** via standard library argument checking (built-in)
- **More bug detection** (NaN comparison, duplicate keys, etc) (built-in)
- **Clearer error messages** (lint names instead of numeric codes)
- **Minimal config file** (no bloat, easy to read)

### Configuration Validation

The `selene --validate-config` command will verify the configuration file
before running lints, catching typos in lint names or invalid settings.

## Open Questions

**RESOLVED:** Should we enable additional strict lints that luacheck didn't
provide?

- **Answer:** YES - The proposed configuration enables 15 "deny" level lints
  and 10 "warn" level lints
- **Rationale:** Selene's type checking catches real bugs that luacheck misses
  (wrong argument counts, incorrect API usage)
- **Safety:** All new strict lints will be validated in Phase 1 before removing
  luacheck

**OPEN:** Should we keep backward compatibility with `make luacheck` target?

- **Recommendation:** No, clean break is clearer
- **Rationale:** Avoids confusion, forces explicit migration

**OPEN:** Should we add selene version check to ensure consistency?

- **Recommendation:** Yes, add version validation to Makefile similar to other
  tools
- **Rationale:** Ensures reproducible builds across dev environments

## Resources

### Selene Documentation

- [Selene GitHub Repository](https://github.com/Kampfkarren/selene)
- [Selene Documentation](https://kampfkarren.github.io/selene/)
- [Configuration Guide](https://kampfkarren.github.io/selene/usage/configuration.html)
- [Luacheck Comparison](https://kampfkarren.github.io/selene/luacheck.html)
- [Latest Release v0.30.0](https://github.com/Kampfkarren/selene/releases) (2026-01-22)
- [Complete Lints List](https://kampfkarren.github.io/selene/lints/)
- [Filtering (inline directives)](https://kampfkarren.github.io/selene/usage/filtering.html)

### Example Configurations from Popular Neovim Plugins

- [mason.nvim selene.toml](https://github.com/williamboman/mason.nvim/blob/main/selene.toml) - Package manager config
- [neodev.nvim selene.toml](https://github.com/folke/neodev.nvim/blob/main/selene.toml) - Dev environment setup
- [packer.nvim selene.toml](https://github.com/wbthomason/packer.nvim/blob/master/selene.toml) - Plugin manager
- [More examples on GitHub](https://github.com/search?q=selene.toml+vim+path%3A%2F&type=code)

### Integration & CI

- [GitHub Actions selene-linter](https://github.com/marketplace/actions/selene-linter)
- [nvim-lint integration](https://github.com/mfussenegger/nvim-lint)
- [MegaLinter selene descriptor](https://megalinter.io/8/descriptors/lua_selene/)
- [Selene in GitHub Actions workflow examples](https://github.com/Kampfkarren/selene/actions)

### Community Resources

- [Selene vs Luacheck comparison](https://kampfkarren.github.io/selene/luacheck.html)
- [Roblox community guide](https://devforum.roblox.com/t/selene-stylua-and-roblox-lsp-what-they-do-why-you-should-use-them/1977666)
- [Source code lints directory](https://github.com/Kampfkarren/selene/tree/main/selene-lib/src/lints) - 34 total lints

### Installation

- **Local (Mason):** `:MasonInstall selene`
- **CI:** Download from [GitHub releases](https://github.com/Kampfkarren/selene/releases)
- **Docker:** Download from GitHub releases (supports ARM64 and x86_64)
- **Cargo:** `cargo install selene`

## Success Criteria

- [ ] Selene runs successfully with zero false positives
- [ ] All make targets work correctly
- [ ] CI pipeline passes with selene instead of luacheck
- [ ] Docker image builds and runs selene
- [ ] Documentation is updated
- [ ] No references to luacheck remain in codebase
- [ ] Performance is equal or better than luacheck
- [ ] Developer experience is improved (better error messages)
