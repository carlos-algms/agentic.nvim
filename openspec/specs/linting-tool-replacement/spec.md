# linting-tool-replacement Specification

## Purpose
TBD - created by archiving change migrate-to-selene. Update Purpose after archive.
## Requirements
### Requirement: Selene must be the primary Lua linting tool

All Lua linting operations MUST use selene instead of luacheck.

#### Scenario: Developer runs linting locally

**Given** a developer has selene installed via Mason

**When** they run `make selene`

**Then** selene should execute on all Lua files

**And** results should be displayed in the terminal

**And** exit code should reflect linting status (0 = pass, non-zero = fail)

---

#### Scenario: Developer runs validation suite

**Given** selene is configured correctly

**When** developer runs `make validate`

**Then** selene should be executed as part of the suite

**And** results should be written to `.local/agentic_selene_output.log`

**And** validation should fail if selene detects errors

---

#### Scenario: CI pipeline runs linting

**Given** selene is installed in GitHub Actions

**When** lint job executes

**Then** selene should run on all Lua files

**And** job should fail if linting errors are found

**And** results should be visible in workflow logs

---

#### Scenario: Docker image includes selene

**Given** Docker image is built from `repro/Dockerfile`

**When** container runs `selene --version`

**Then** it should output selene version 0.30.0 or newer

**And** selene should be in PATH

---

### Requirement: Selene configuration must match luacheck strictness

Selene MUST enforce the same or stricter linting rules as luacheck did.

#### Scenario: Selene configuration enforces type checking

**Given** `selene.toml` exists in project root

**When** code contains incorrect standard library usage

**Then** selene should report an error with lint
`incorrect_standard_library_use`

**And** error should be actionable and clear

---

#### Scenario: Selene respects file exclusions

**Given** `selene.toml` has `exclude = ["lazy_repro", "deps", ".local"]`

**When** selene runs on the project

**Then** files in excluded directories should not be linted

**And** linting should complete successfully on non-excluded files

---

#### Scenario: Selene uses Lua 5.1 + vim + busted standard libraries

**Given** `selene.toml` has `std = "lua51+vim+busted"`

**When** code uses vim global

**Then** selene should not report it as undefined

**And** test files using busted globals (describe, it) should pass

---

### Requirement: Inline lint directives must use selene syntax

All inline comments for suppressing lints MUST use selene's `allow` syntax.

#### Scenario: Inline directive suppresses specific lint

**Given** file contains `-- selene: allow(empty_if)`

**When** code has intentional empty if block below comment

**Then** selene should not report error for that line

**And** same lint should still be reported elsewhere in file if applicable

---

#### Scenario: No luacheck directives remain in code

**Given** all files have been migrated

**When** search for "luacheck:" in lua/ and tests/

**Then** zero results should be found

**And** all previous suppressions should use selene syntax

---

### Requirement: Makefile must provide selene targets

Makefile MUST expose selene functionality through standard targets.

#### Scenario: Run selene on entire codebase

**Given** SELENE variable points to selene binary

**When** developer runs `make selene`

**Then** selene should execute on entire project

**And** output should be displayed

**And** exit code should match selene's exit code

---

#### Scenario: Run selene on specific file

**Given** developer specifies FILE variable

**When** developer runs `make selene-file FILE=lua/agentic/init.lua`

**Then** selene should execute only on specified file

**And** output should be displayed

**And** exit code should match selene's exit code

---

#### Scenario: Check target includes selene

**Given** developer wants to run all checks

**When** developer runs `make check`

**Then** selene should run along with luals and format-check

**And** execution should stop on first failure

---

### Requirement: CI must cache selene binary

GitHub Actions MUST cache selene to improve build performance.

#### Scenario: First CI run downloads and caches selene

**Given** cache for selene does not exist

**When** lint job runs

**Then** selene should be downloaded from GitHub releases

**And** binary should be cached with key `selene-{os}-{version}`

**And** binary should be added to PATH

**And** lint job should complete successfully

---

#### Scenario: Subsequent CI runs use cached selene

**Given** cache for selene exists

**When** lint job runs

**Then** selene should be restored from cache

**And** download step should be skipped

**And** lint job should complete faster than first run

---

### Requirement: Docker image must include selene

Docker image MUST have selene installed and ready to use.

#### Scenario: Docker image builds with selene

**Given** Dockerfile includes selene installation

**When** image is built with `docker build -t agentic-nvim-dev repro/`

**Then** build should complete without errors

**And** image should include selene binary

**And** selene should be in PATH at `/usr/local/bin/selene`

---

#### Scenario: Selene works inside container

**Given** Docker container is running

**When** user runs `make selene` inside container

**Then** selene should execute on project files

**And** linting should complete successfully

**And** results should be displayed

---

#### Scenario: Docker supports multi-architecture

**Given** Dockerfile has architecture detection

**When** image is built on ARM64 (aarch64)

**Then** selene-linux-aarch64 binary should be downloaded

**When** image is built on x86_64

**Then** selene-linux-x86_64 binary should be downloaded

**And** both architectures should work correctly

---

### Requirement: Documentation must reflect selene usage

All documentation MUST reference selene instead of luacheck.

#### Scenario: AGENTS.md documents selene

**Given** AGENTS.md contains development instructions

**When** developer reads linting section

**Then** instructions should reference selene

**And** make targets should be `make selene`

**And** no luacheck references should exist (except historical)

---

#### Scenario: Docker README documents selene

**Given** repro/README.md documents Docker usage

**When** user reads command examples

**Then** examples should use `make selene`

**And** tool versions should list selene 0.30.0

**And** no luacheck references should exist

---

#### Scenario: Workflow triggers include selene.toml

**Given** GitHub Actions workflow has path triggers

**When** `selene.toml` is modified

**Then** workflow should trigger automatically

**And** lint job should run

---

