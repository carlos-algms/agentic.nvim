# Tasks: Migrate from Luacheck to Selene

## Task List

This is an ordered sequence of implementation tasks with mandatory validation
checkpoints between major phases.

---

## Phase 1: Local Installation & Initial Testing

### 1.1 Install selene via Mason

**Description:** Install selene locally using Neovim's Mason package manager.

**Steps:**

- Open Neovim and run `:MasonInstall selene`
- Verify installation: run `selene --version` in terminal
- Confirm binary location matches Mason path
  (`~/.local/share/nvim/mason/bin/selene`)

**Validation:**

- `selene --version` outputs `0.30.0` or newer
- Binary is executable and in PATH or Mason directory

**Dependencies:** None

---

### 1.2 Create initial selene.toml configuration

**Description:** Create minimal `selene.toml` config with only necessary
overrides (no bloat).

**Steps:**

- Create `selene.toml` in project root with minimal configuration:
  - `std = "lua51+vim+busted"` for Neovim + test support
  - `exclude` patterns from `.luacheckrc`
  - Override only 4 lint defaults:
    - `unused_variable = "allow"` (luacheck compat, default is "warn")
    - `shadowing = "allow"` (luacheck compat, default is "warn")
    - `unbalanced_assignments = "deny"` (stricter, default is "warn")
    - `mixed_table = "allow"` (Neovim pattern, default is "warn")
  - Add minimal `[config]` section (4 tweaks):
    - `unused_variable.ignore_pattern = "^_"`
    - `shadowing.ignore_pattern = "^_"`
    - `empty_if.comments_count = true`
    - `empty_loop.comments_count = true`
- Copy exact configuration from proposal.md
- Validate with `selene --validate-config`

**Validation:**

- File exists at `/Users/carlos.gomes/projects/wt-agentic/selene.toml`
- TOML syntax is valid (`selene --validate-config` passes)
- File is minimal (~20 lines including comments)
- Only non-default values are configured
- All `.luacheckrc` rules are mapped to selene equivalents

**Dependencies:** Task 1.1

**Files Created:**

- `selene.toml` (minimal clean configuration)

**Note:** Selene's defaults are already strict (type checking, undefined
variables, etc). We only override what's needed for luacheck compatibility and
project-specific patterns.

---

### 1.3 Run selene for the first time

**Description:** Execute selene on the codebase and capture initial output.

**Steps:**

- Run `selene .` from project root
- Capture output to analyze warnings/errors
- Document any unexpected issues
- Compare selene findings vs current luacheck output

**Validation:**

- Selene completes without crashing
- Output format is readable
- Errors match expected patterns from inline luacheck directives
- No false positives on valid code

**Dependencies:** Task 1.2

---

### 1.4 Adjust selene.toml configuration

**Description:** Refine config based on first run results to eliminate false
positives.

**Steps:**

- Analyze errors from task 1.3
- Adjust lint severities if needed
- Fine-tune exclusion patterns
- Add any missing standard library definitions
- Test with `selene .` after each adjustment

**Validation:**

- `selene .` runs clean except for 5 expected errors (inline luacheck
  directives)
- No false positives on valid code
- All files are checked (verify with `--display-style=quiet`)
- Configuration covers all use cases from `.luacheckrc`

**Dependencies:** Task 1.3

---

**MANDATORY CHECKPOINT 1:**

Before proceeding to Phase 2:

- [x] Selene is installed and runs successfully
- [x] `selene.toml` is configured correctly
- [x] Output is clean except for 5 known inline directive locations
- [x] No false positives detected
- [x] User approves configuration

---

## Phase 2: Remove Luacheck

### 2.1 Update inline code comments (5 files)

**Description:** Replace all `luacheck: ignore` comments with selene
equivalents.

**Steps:**

- Update `lua/agentic/acp/adapters/claude_acp_adapter.lua:151`
  - `-- luacheck: ignore 542` → `-- selene: allow(empty_if)`
- Update `lua/agentic/acp/adapters/codex_acp_adapter.lua:105`
  - `-- luacheck: ignore 542` → `-- selene: allow(empty_if)`
- Update `lua/agentic/ui/clipboard.lua:138`
  - `-- luacheck: ignore 122` →
    `-- selene: allow(incorrect_standard_library_use)`
- Update `lua/agentic/ui/file_picker.test.lua:56`
  - `-- luacheck: ignore` → `-- selene: allow(incorrect_standard_library_use)`
- Update `lua/agentic/ui/file_picker.test.lua:72`
  - `-- luacheck: ignore 122` →
    `-- selene: allow(incorrect_standard_library_use)`

**Validation:**

- All 5 files updated correctly
- `selene .` runs with zero errors
- Comments are recognized by selene
- Grep confirms no remaining luacheck directives:
  `rg "luacheck:" lua/ tests/`

**Dependencies:** Phase 1 completed

**Files Modified:**

- `lua/agentic/acp/adapters/claude_acp_adapter.lua`
- `lua/agentic/acp/adapters/codex_acp_adapter.lua`
- `lua/agentic/ui/clipboard.lua`
- `lua/agentic/ui/file_picker.test.lua`

---

### 2.2 Delete .luacheckrc

**Description:** Remove luacheck configuration file now that selene is working.

**Steps:**

- Delete `.luacheckrc` file
- Run `selene .` to confirm it still works
- Verify no tools depend on `.luacheckrc`

**Validation:**

- File deleted: `ls .luacheckrc` returns "No such file"
- `selene .` runs successfully without errors
- No git grep matches for `.luacheckrc` in documentation or scripts

**Dependencies:** Task 2.1

**Files Deleted:**

- `.luacheckrc`

---

### 2.3 Verify selene recognizes all inline directives

**Description:** Confirm selene properly handles all inline allow directives.

**Steps:**

- Run `selene .` on entire codebase
- Verify exit code is 0
- Check that previously suppressed warnings don't appear
- Test with `--display-style=json` to verify structure

**Validation:**

- `selene .` exits with code 0
- No warnings about unknown directives
- All 5 inline directives are effective
- JSON output (if used) is well-formed

**Dependencies:** Task 2.2

---

**MANDATORY CHECKPOINT 2:**

Before proceeding to Phase 3:

- [x] All inline luacheck comments are updated
- [x] `.luacheckrc` is deleted
- [x] `selene .` runs clean (exit code 0)
- [x] No luacheck references remain in code
- [x] User approves changes

---

## Phase 3: Makefile Integration

### 3.1 Update Makefile variables

**Description:** Replace LUACHECK variable with SELENE in Makefile.

**Steps:**

- Replace `LUACHECK ?= ...` with `SELENE ?= ...`
- Update path to check for selene in Mason directory
- Keep same fallback pattern as other tools

**Validation:**

- `make selene` (after task 3.2) resolves correct binary path
- Variable expansion works: `make -n selene` shows correct path
- Works with custom path: `make SELENE=/custom/path selene`

**Dependencies:** Phase 2 completed

**Files Modified:**

- `Makefile`

---

### 3.2 Update Makefile targets

**Description:** Rename luacheck targets to selene equivalents.

**Steps:**

- Rename `luacheck:` target to `selene:`
- Rename `luacheck-file:` target to `selene-file:`
- Update `.PHONY` declaration
- Update commands to use `$(SELENE)` instead of `$(LUACHECK)`

**Validation:**

- `make selene` runs successfully
- `make selene-file FILE=lua/agentic/init.lua` works
- `make -n selene` shows correct command
- Tab completion works (if supported by shell)

**Dependencies:** Task 3.1

**Files Modified:**

- `Makefile`

---

### 3.3 Update validate target

**Description:** Replace luacheck references in validate target with selene.

**Steps:**

- Change `make luacheck` to `make selene` in validate script
- Rename log file from `agentic_luacheck_output.log` to
  `agentic_selene_output.log`
- Update variable name `rc_luacheck` to `rc_selene`
- Update output message to say "selene:" instead of "luacheck:"
- Update final check condition to use `rc_selene`

**Validation:**

- `make validate` runs all checks including selene
- Log file is created at `.local/agentic_selene_output.log`
- Exit codes are reported correctly
- Total time is displayed
- Validation fails if selene fails

**Dependencies:** Task 3.2

**Files Modified:**

- `Makefile`

---

### 3.4 Update check convenience target

**Description:** Update the `check` target to use selene instead of luacheck.

**Steps:**

- Replace `luacheck` with `selene` in `check` target dependencies

**Validation:**

- `make check` runs luals, selene, and format-check in order
- Stops on first failure
- All three tools execute when run

**Dependencies:** Task 3.2

**Files Modified:**

- `Makefile`

---

### 3.5 Test all make targets

**Description:** Comprehensive test of all modified make targets.

**Steps:**

- Test `make selene` on clean code (should pass)
- Test `make selene-file FILE=<path>` on individual file
- Test `make validate` full suite
- Test `make check` target
- Test with custom SELENE path override
- Test error scenarios (introduce lint error, verify detection)

**Validation:**

- All targets work correctly
- Error messages are clear and helpful
- Log files are created in correct locations
- Exit codes are correct (0 for success, non-zero for failure)

**Dependencies:** Tasks 3.1-3.4

---

**MANDATORY CHECKPOINT 3:**

Before proceeding to Phase 4:

- [x] All Makefile targets updated
- [x] `make validate` works correctly
- [x] Log files are created with correct names
- [x] All make targets tested and working
- [x] User approves Makefile changes

---

## Phase 4: CI/CD Updates

### 4.1 Update GitHub Actions environment variables

**Description:** Add SELENE_VERSION to workflow environment variables.

**Steps:**

- Add `SELENE_VERSION: 0.30.0` to `env:` section in
  `.github/workflows/pr-check.yml`
- Place it after STYLUA_VERSION for consistency

**Validation:**

- YAML syntax is valid
- Environment variable is accessible in all jobs
- Version number is correct (latest stable)

**Dependencies:** Phase 3 completed

**Files Modified:**

- `.github/workflows/pr-check.yml`

---

### 4.2 Update lint job in GitHub Actions

**Description:** Replace luacheck installation and execution with selene in CI
pipeline.

**Steps:**

- Remove "Install Luacheck" step (apt-get install lua-check)
- Add "Setup directories" step: `mkdir -p .local/bin`
- Add "Cache Selene" step with `actions/cache@v4`
  - Path: `.local/bin/selene`
  - Key: `selene-${{ runner.os }}-${{ env.SELENE_VERSION }}`
- Add "Install Selene" step (conditional on cache miss)
  - Download from GitHub releases
  - Extract to `.local/bin/`
  - Make executable
- Update "Run luacheck" step to "Run selene"
  - Add PATH export: `export PATH="$PWD/.local/bin:$PATH"`
  - Change command: `make selene`

**Validation:**

- YAML syntax is valid
- Workflow validates with `actionlint` (if available)
- Job steps are in correct order
- Cache key is unique per version
- Download URL is correct

**Dependencies:** Task 4.1

**Files Modified:**

- `.github/workflows/pr-check.yml`

---

### 4.3 Update workflow trigger paths

**Description:** Update paths that trigger workflow to include selene.toml.

**Steps:**

- Add `selene.toml` to `paths:` list in `pull_request` trigger
- Add `selene.toml` to `paths:` list in `push` trigger
- Remove `.luacheckrc` if present in paths

**Validation:**

- YAML syntax is valid
- Paths list includes all linter config files:
  - `selene.toml`
  - `.luarc.json`
  - `stylua.toml`

**Dependencies:** Task 4.1

**Files Modified:**

- `.github/workflows/pr-check.yml`

---

### 4.4 Update Dockerfile

**Description:** Replace luacheck installation with selene in Docker image.

**Steps:**

- Add `SELENE_VERSION=0.30.0` to ENV declarations
- Remove `luarocks`, `gcc`, `libc6-dev` from apt-get install
- Remove `luarocks install luacheck` command
- Remove `apt-get purge -y --auto-remove gcc` (no longer needed)
- Add selene installation layer:
  - Detect architecture (aarch64 vs x86_64)
  - Download appropriate binary from GitHub
  - Extract to `/usr/local/bin/`
  - Make executable
  - Clean up zip file

**Validation:**

- Dockerfile builds successfully: `docker build -t test repro/`
- Image includes selene: `docker run --rm test selene --version`
- Image size is reasonable (check with `docker images`)
- Both ARM64 and x86_64 architectures supported

**Dependencies:** Task 4.1

**Files Modified:**

- `repro/Dockerfile`

---

### 4.5 Update Docker README

**Description:** Update documentation with selene commands.

**Steps:**

- Replace references to luacheck with selene in `repro/README.md`
- Update version numbers in "Tools Included" section
- Update command examples:
  - `make luacheck` → `make selene`
- Update "Run All Checks" section
- Add note about selene version matching CI

**Validation:**

- All command examples are correct
- Version numbers match Dockerfile
- Markdown formatting is valid
- Links work (if any)

**Dependencies:** Task 4.4

**Files Modified:**

- `repro/README.md`

---

### 4.6 Update AGENTS.md documentation

**Description:** Update development guide with selene information.

**Steps:**

- Find all references to luacheck in `AGENTS.md`
- Replace luacheck mentions with selene
- Update "Type Checking" or "Linting" section if exists
- Update any example commands
- Add selene-specific notes if needed

**Validation:**

- No mentions of luacheck remain (verify with `rg luacheck AGENTS.md`)
- All make command examples are updated
- Markdown formatting is correct
- Instructions are clear and accurate

**Dependencies:** Task 4.4

**Files Modified:**

- `AGENTS.md`

---

### 4.7 Test Docker image locally

**Description:** Build and test Docker image with selene.

**Steps:**

- Build image: `docker build -t agentic-nvim-dev repro/`
- Run `selene --version` in container
- Run `make selene` in container with project mounted
- Test all validation commands from README
- Check image size vs previous version

**Validation:**

- Image builds without errors
- Selene is installed and functional
- All make targets work inside container
- Image size is comparable or smaller than before

**Dependencies:** Task 4.4

---

### 4.8 Test CI pipeline on feature branch

**Description:** Push changes to feature branch and verify CI passes.

**Steps:**

- Commit all changes to feature branch
- Push to GitHub
- Monitor GitHub Actions workflow
- Check that lint job completes successfully
- Verify caching works (check second run is faster)
- Review workflow logs for any issues

**Validation:**

- All CI jobs pass (format, lint, test, typecheck)
- Lint job uses selene successfully
- Cache is saved and restored correctly
- No errors or warnings in workflow logs
- Execution time is comparable or faster than luacheck

**Dependencies:** Tasks 4.1-4.7

---

**MANDATORY CHECKPOINT 4:**

Before proceeding to Phase 5:

- [x] GitHub Actions workflow updated and passes
- [x] Docker image builds successfully with selene
- [x] Documentation is updated
- [x] CI pipeline tested on feature branch
- [x] All jobs are green
- [x] User approves CI/CD changes

---

## Phase 5: Final Verification

### 5.1 Run full validation suite locally

**Description:** Execute complete validation to ensure everything works
together.

**Steps:**

- Run `make validate` from clean state
- Verify all checks pass:
  - format (stylua)
  - luals (type checking)
  - selene (linting)
  - test (unit tests)
- Check log files are created correctly
- Verify exit codes and timing

**Validation:**

- `make validate` exits with code 0
- All four checks pass
- Log files exist and contain expected output
- Total execution time is displayed
- No errors or warnings

**Dependencies:** Phase 4 completed

---

### 5.2 Verify no luacheck references remain

**Description:** Search entire codebase for any remaining luacheck references.

**Steps:**

- Run `rg luacheck` in project root
- Check results:
  - Ignore results in git history
  - Ignore results in this OpenSpec proposal
  - Flag any remaining code or config references
- Run `rg ".luacheckrc"` to verify config file is not referenced
- Check all documentation files manually if needed

**Validation:**

- No luacheck references in active code
- No luacheck references in Makefile
- No luacheck references in CI workflows
- No luacheck references in Docker files
- Only references should be in git history and OpenSpec docs

**Dependencies:** Task 5.1

---

### 5.3 Test Docker image end-to-end

**Description:** Final comprehensive test of Docker image.

**Steps:**

- Build fresh image: `docker build --no-cache -t agentic-nvim-dev repro/`
- Run interactive shell: `docker run --rm -it -v "$(pwd):/workspace"
  agentic-nvim-dev`
- Inside container:
  - Run `selene --version`
  - Run `make selene`
  - Run `make validate` (full suite)
  - Run `make format-check`
- Test non-interactive: `docker run --rm -v "$(pwd):/workspace"
  agentic-nvim-dev make selene`

**Validation:**

- Image builds successfully from scratch
- All tools work correctly
- Project validation passes inside container
- Non-interactive execution works
- Performance is acceptable

**Dependencies:** Task 5.2

---

### 5.4 Review all changed files

**Description:** Final review of all modifications before approval.

**Steps:**

- Review `git diff` for all changed files:
  - `selene.toml` (new)
  - `.luacheckrc` (deleted)
  - `Makefile`
  - `.github/workflows/pr-check.yml`
  - `repro/Dockerfile`
  - `repro/README.md`
  - `AGENTS.md`
  - 5 Lua files with inline comments
- Verify changes match proposal
- Check for any unintended modifications
- Confirm code formatting (stylua) is applied
- Review commit messages for clarity

**Validation:**

- All changes are intentional and documented
- No debug code or temporary changes remain
- Formatting is consistent
- Commit history is clean
- Ready for final approval

**Dependencies:** Task 5.3

---

### 5.5 Update project.md if needed

**Description:** Update OpenSpec project.md with selene references if
appropriate.

**Steps:**

- Review `openspec/project.md`
- Check if luacheck is mentioned
- Replace with selene if found
- Update any relevant sections about linting tools
- Ensure consistency with other tool documentation

**Validation:**

- No luacheck references in project.md (unless historical)
- Selene is documented if other dev tools are
- Markdown formatting is correct
- Information is accurate

**Dependencies:** Task 5.4

**Files Modified:**

- `openspec/project.md` (conditional)

---

**MANDATORY CHECKPOINT 5 (Final Approval):**

Before merging to main:

- [x] Full validation suite passes locally
- [x] No luacheck references remain in active code
- [x] Docker image works end-to-end
- [x] All changed files reviewed and approved
- [x] CI pipeline is green
- [x] Documentation is complete and accurate
- [x] User gives final approval to merge

---

## Task Summary

**Total Tasks:** 30

**Breakdown by Phase:**

- Phase 1 (Installation & Testing): 4 tasks
- Phase 2 (Remove Luacheck): 3 tasks
- Phase 3 (Makefile): 5 tasks
- Phase 4 (CI/CD): 8 tasks
- Phase 5 (Final Verification): 5 tasks
- Checkpoints: 5 mandatory stops

**Estimated Effort:**

- Phase 1: ~30 minutes
- Phase 2: ~15 minutes
- Phase 3: ~20 minutes
- Phase 4: ~45 minutes
- Phase 5: ~20 minutes
- **Total: ~2 hours** (excluding checkpoint review time)

**Parallelizable Work:**

- None - tasks must be executed sequentially due to dependencies and checkpoints

**Critical Path:**

All tasks are on the critical path due to sequential dependencies. Each phase
must be completed and validated before proceeding to the next.
