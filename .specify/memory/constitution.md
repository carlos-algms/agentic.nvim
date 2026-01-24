<!--
Sync Impact Report:
- Version change: 1.0.0 → 1.1.0
- Modified principles: None
- Added sections:
  - VIII. Test-Driven Development (TDD)
- Removed sections: None
- Templates requiring updates:
  - ✅ plan-template.md - Already has test-first references
  - ✅ spec-template.md - Already supports test scenarios
  - ✅ tasks-template.md - Already has test task structure
- Follow-up TODOs: None
-->

# agentic.nvim Constitution

## Core principles

### I. YAGNI (You Aren't Gonna Need It)

Build only what is needed now:

- **DO NOT** create features or functions "just in case"
- **DO NOT** add abstractions for hypothetical future requirements
- Three similar lines of code is better than a premature helper function
- Delete unused code immediately - no commented-out code blocks
- If a feature is not explicitly requested, do not build it

**Rationale**: Premature abstractions and speculative features create technical
debt, obscure intent, and make code harder to maintain.

### II. Simplicity over cleverness

Start simple and stay simple:

- Prefer standard Neovim APIs over custom implementations
- Avoid over-engineering - only make changes directly requested or clearly
  necessary
- Do not add error handling for scenarios that cannot happen
- Trust internal code and framework guarantees; only validate at system
  boundaries (user input, external APIs)

**Rationale**: Complex solutions have hidden costs in maintenance, debugging,
and onboarding. Simplicity enables velocity.

### III. No assumptions - verify first

**CRITICAL: No assumptions or ambiguous definitions tolerated.**

Before implementing, suggesting, or deciding:

- **MUST** read official documentation (Neovim docs, library docs, protocol
  specs)
- **MUST** research online (best practices, how other plugins solve similar
  problems)
- **MUST** examine real-world examples (reference implementations, popular
  plugins)
- **MUST** verify APIs exist for Neovim v0.11.0+

**Forbidden behaviors**:

- "This probably works like X"
- "I assume this field exists"
- "Based on similar projects..." (without actually reading them)
- Guessing parameter types or return values

**Rationale**: Assumptions lead to bugs, incorrect implementations, and wasted
effort. Investigation is always cheaper than debugging wrong assumptions.

### IV. DRY (Don't Repeat Yourself) - with judgment

Avoid code duplication, but not at all costs:

- Extract repeated logic into helper functions when pattern is stable
- Use `before_each` / `after_each` in tests for common setup/teardown
- Share utilities across modules when genuinely reusable
- **BUT**: Duplication is better than the wrong abstraction

**Rationale**: Premature DRY creates coupling and makes code harder to change.
Wait for patterns to emerge before abstracting.

### V. Decoupling through callbacks

**Modules should not know about each other unless absolutely necessary.**

- **PREFER** callbacks over passing class instances
- **ALLOWED**: Static module imports for stateless utilities
- **ALLOWED**: Instance methods wrapped as callbacks (black boxes to receiver)
- **AVOID**: Direct class-to-class dependencies

**Rationale**: Loose coupling enables independent testing, reuse in different
contexts, and explicit dependency graphs.

### VI. Multi-tabpage safety (NON-NEGOTIABLE)

**EVERY feature MUST be multi-tab safe.**

- One session instance per tabpage via `SessionRegistry`
- **NEVER** use module-level shared state for per-tabpage runtime data
- Module-level constants OK for truly global config
- Namespaces are global; extmarks are buffer-scoped
- Buffer-local keymaps only (never global keymaps)

**Rationale**: This is a core architectural constraint. Violating it breaks the
plugin for users with multiple tabpages.

### VII. Validate before commit

**ALWAYS run validations after ANY Lua file changes:**

```bash
make validate
```

This runs: format, luals (type checking), luacheck (linting), test.

- All checks MUST pass before considering work complete
- Log files in `.local/` directory for failure diagnosis
- Do not skip validation steps

**Rationale**: Automated validation catches errors early and maintains codebase
quality. Skipping validation creates debt that compounds.

### VIII. Test-Driven Development (TDD)

**Tests MUST be written before implementation for new functionality.**

- **MUST NOT** implement a feature if tests cannot be written first
- Write test → verify it fails → implement → verify it passes
- User may explicitly waive TDD for specific features when requested

**When tests are NOT required**:

- Reusing existing tested functions in new locations
- Pure wiring/glue code that calls already-tested components
- Trivial changes with no new logic (renaming, moving files)
- User explicitly requests skipping tests for a feature

**Rationale**: TDD ensures code is testable by design, catches regressions
early, and documents expected behavior. Writing tests after implementation often
leads to tests that verify implementation rather than requirements.

## Architecture constraints

**Neovim requirements**:

- Neovim v0.11.0+ required (verify APIs exist for this version)
- LuaJIT 2.1 (Lua 5.1 features only)

**ACP protocol**:

- Single ACP provider instance shared across all tabpages
- One ACP session ID per tabpage
- Providers spawn as external CLI subprocesses

**UI layout**:

- Widget opens on right side only (currently)
- Multiple stacked windows: Chat, Todo, Code snippets, Files, Prompt

**Testing**:

- mini.test framework with Busted-style emulation
- Co-located tests preferred (`<module>.test.lua`)
- Tests MUST clean up all resources (spies, buffers, windows, autocommands)

## Development workflow

### Code style

- **LuaCATS annotations** for type checking
- **Luacheck** for linting
- **StyLua** for formatting (configured in `.stylua.toml`)
- **Visibility prefixes**: `_*` = private, `__*` = protected, no prefix = public

### Logging

- **NEVER** use `vim.notify` directly - use `Logger.notify()` (prevents fast
  context errors)
- `Logger.debug()` for debug messages (requires `Config.debug = true`, and read
  by `:messages`)
- `Logger.debug_to_file()` persistent logs, only used for messages exchanged
  with the ACP provider

### Git workflow

- **NEVER** commit to `main` branch directly
- **NEVER** use `git revert`, `git checkout <file>`, or `git reset` to undo
  files (may lose prior changes)
- Stage specific files (avoid `git add -A`)
- No commits without explicit user request

## Governance

This constitution supersedes all other practices. Amendments require:

1. Documentation of the change and rationale
1. Review of impact on existing code
1. Update to this constitution with version increment

**Compliance**:

- All PRs/reviews MUST verify compliance with these principles
- Complexity MUST be justified in code comments or PR description
- Use `AGENTS.md` for runtime development guidance

---

**Version**: 1.1.0 | **Ratified**: 2026-01-24 | **Last Amended**: 2026-01-24
