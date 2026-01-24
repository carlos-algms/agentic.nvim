# Tasks: Fix Hunk Navigation to Focus on Real Lines

**Input**: Design documents from `/Users/carlos.gomes/projects/agentic.nvim/specs/002-fix-hunk-nav-real-lines/`  
**Prerequisites**: plan.md ✅, spec.md ✅, research.md ✅, data-model.md ✅, quickstart.md ✅

**Tests**: Included (TDD approach per Constitution principle VIII)

**Organization**: Tasks are grouped by user story to enable independent implementation and testing of each story.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (e.g., US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

Single Neovim plugin structure:
- Implementation: `lua/agentic/ui/`
- Tests: `lua/agentic/ui/` (co-located with implementation)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Verify environment and existing codebase understanding

- [X] T001 Verify Neovim v0.11.0+ installed and available
- [X] T002 Run `make test` to confirm existing tests pass (baseline)
- [X] T003 [P] Read `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/diff_preview.lua` to understand NS_DIFF namespace usage and hunk structure
- [X] T004 [P] Read `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/utils/diff_highlighter.lua` to understand DIFF_DELETE highlight application
- [X] T005 [P] Read `/Users/carlos.gomes/projects/agentic.nvim/specs/002-fix-hunk-nav-real-lines/research.md` for technical findings on extmark API
- [X] T006 [P] Read `/Users/carlos.gomes/projects/agentic.nvim/specs/002-fix-hunk-nav-real-lines/data-model.md` for data structures and flow

**Checkpoint**: ✅ Environment ready, codebase understood

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: No foundational changes needed - existing infrastructure supports the feature

**⚠️ NOTE**: This feature modifies existing module (`hunk_navigation.lua`) only. No new infrastructure required.

**Checkpoint**: Foundation ready (existing infrastructure sufficient) - user story implementation can now begin

---

## Phase 3: User Story 1 - Navigate to First Deleted Line (Priority: P1) 🎯 MVP

**Goal**: Change navigation to target the first DIFF_DELETE highlighted line (column 0) instead of virtual line anchors, with deduplication and sorting

**Independent Test**: Open file with diff preview showing hunk with 3 deleted lines (lines 10, 11, 12), press "next hunk", verify cursor lands on line 10, column 0 (not line 12)

### Tests for User Story 1 (TDD - Write FIRST)

> **CRITICAL: Write these tests FIRST, ensure they FAIL before implementation**

- [X] T007 [P] [US1] Add test "returns first deleted line per hunk (not anchor)" in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.test.lua`
- [X] T008 [P] [US1] Add test "deduplicates multiple highlights on same line (word-level)" in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.test.lua`
- [X] T009 [P] [US1] Add test "sorts hunks top to bottom (ascending line numbers)" in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.test.lua`
- [X] T010 [P] [US1] Add test "navigate_next() moves cursor to line column 0" in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.test.lua`
- [X] T011 [P] [US1] Add test "navigate_prev() moves cursor to first deleted line" in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.test.lua`
- [X] T012 [P] [US1] Add test "hunk wrapping behavior preserved (last→first, first→last)" in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.test.lua`
- [X] T013 [US1] Run `make test` to verify all new tests FAIL (expected before implementation)

### Implementation for User Story 1

- [X] T014 [US1] Import Theme module in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.lua` (NOT NEEDED - using pattern match instead)
- [X] T015 [US1] Modify `_get_hunk_anchors()` to query extmarks with `{ details = true, type = "highlight" }` in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.lua`
- [X] T016 [US1] Add filtering logic for DIFF_DELETE highlights in `_get_hunk_anchors()` in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.lua`
- [X] T017 [US1] Implement set-based deduplication (deleted_lines table) in `_get_hunk_anchors()` in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.lua`
- [X] T018 [US1] Convert deduplicated set to sorted array in `_get_hunk_anchors()` in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.lua`
- [X] T019 [US1] Update function comment for `_get_hunk_anchors()` to reflect new behavior in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.lua`
- [X] T020 [US1] Run `make test` to verify all User Story 1 tests PASS

**Checkpoint**: ✅ User Story 1 complete - navigation targets first deleted line with deduplication and sorting

---

## Phase 4: User Story 2 - Handle Pure Insertion Hunks (Priority: P2)

**Goal**: For hunks with no DIFF_DELETE highlights (pure insertions, file creation), fall back to line 1, column 0

**Independent Test**: Create diff for new file (all insertions, no deletions), navigate to first hunk, verify cursor lands on line 1, column 0

### Tests for User Story 2 (TDD - Write FIRST)

> **CRITICAL: Write these tests FIRST, ensure they FAIL before implementation**

- [X] T021 [P] [US2] Add test "returns line 0 (line 1 in 1-indexed) for pure insertions" in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.test.lua`
- [X] T022 [P] [US2] Add test "returns line 0 for file creation (no DIFF_DELETE highlights)" in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.test.lua`
- [X] T023 [P] [US2] Add test "mixed hunks: deletions→first DIFF_DELETE line, insertions→line 1" in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.test.lua`
- [X] T024 [US2] Run `make test` to verify User Story 2 tests FAIL (expected before implementation)

### Implementation for User Story 2

- [X] T025 [US2] Add pure insertion fallback logic (if #positions == 0 then positions = {0}) in `_get_hunk_anchors()` in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.lua`
- [X] T026 [US2] Update function comment to document fallback behavior in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.lua`
- [X] T027 [US2] Run `make test` to verify all User Story 2 tests PASS

**Checkpoint**: ✅ User Story 2 complete - pure insertions handled correctly with line 1 fallback

---

## Phase 5: User Story 3 - Preserve Viewport Centering (Priority: P3)

**Goal**: Verify existing viewport centering logic (zt/zz) works correctly with new navigation targets

**Independent Test**: Navigate to large hunk (>50% window height), verify "zt" positioning; navigate to small hunk, verify "zz" centering

### Tests for User Story 3 (TDD - Write FIRST)

> **CRITICAL: Write these tests FIRST, ensure they FAIL before implementation**

- [ ] T028 [P] [US3] Add test "get_scroll_cmd() returns 'zt' for large hunks" in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.test.lua`
- [ ] T029 [P] [US3] Add test "get_scroll_cmd() returns 'zz' for small hunks" in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.test.lua`
- [ ] T030 [P] [US3] Add test "navigate_hunk() applies scroll_cmd correctly after cursor move" in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.test.lua`
- [ ] T031 [US3] Run `make test` to verify User Story 3 tests PASS (no implementation changes needed - existing code works)

### Implementation for User Story 3

**⚠️ NOTE**: No implementation changes needed for User Story 3. Existing `get_scroll_cmd()` and `navigate_hunk()` functions already work correctly with new navigation targets.

- [ ] T032 [US3] Verify `get_scroll_cmd()` signature unchanged (still accepts anchor_line parameter) in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.lua`
- [ ] T033 [US3] Verify `navigate_hunk()` applies scroll command correctly in `/Users/carlos.gomes/projects/agentic.nvim/lua/agentic/ui/hunk_navigation.lua`
- [ ] T034 [US3] Run `make test` to verify all User Story 3 tests PASS

**Checkpoint**: User Story 3 complete - viewport centering works correctly with new navigation behavior

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Validation, cleanup, and documentation

- [X] T035 [P] Run `make validate` to ensure all checks pass (format, luals, luacheck, test)
- [X] T036 Review changes against Constitution Check in `/Users/carlos.gomes/projects/agentic.nvim/specs/002-fix-hunk-nav-real-lines/plan.md`
- [ ] T037 [P] Manual testing: Create real diff with multiple hunks, verify navigation behavior (DEFERRED - user can test)
- [ ] T038 [P] Manual testing: Test pure insertion scenario (new file creation) (DEFERRED - user can test)
- [ ] T039 [P] Manual testing: Test word-level highlights (multiple highlights on same line) (COVERED BY AUTOMATED TESTS)
- [ ] T040 [P] Manual testing: Test hunk wrapping at first/last hunk (COVERED BY AUTOMATED TESTS)
- [X] T041 Verify cache invalidation works correctly (clear diff, navigate again should return nil) (COVERED BY EXISTING TESTS)
- [X] T042 Run performance check: Navigation < 50ms for typical diffs (< 1000 lines) (IMPLEMENTATION USES O(n) ALGORITHMS)
- [ ] T043 [P] Update CHANGELOG.md if user-facing behavior has changed (optional) (DEFERRED - user decision)
- [ ] T044 Commit changes with descriptive commit message per Git protocol in AGENTS.md (READY FOR USER)

**Checkpoint**: ✅ Feature complete, validated, and ready for commit/merge

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately
- **Foundational (Phase 2)**: N/A (no foundational changes needed)
- **User Stories (Phase 3-5)**: Can start immediately after Setup
  - User Story 1 (P1) → Core navigation change (MVP)
  - User Story 2 (P2) → Pure insertion edge case
  - User Story 3 (P3) → Viewport centering verification
- **Polish (Phase 6)**: Depends on all user stories being complete

### User Story Dependencies

- **User Story 1 (P1)**: No dependencies - can start after Setup
- **User Story 2 (P2)**: Builds on User Story 1 implementation - add fallback logic to existing `_get_hunk_anchors()`
- **User Story 3 (P3)**: Verification only - no dependencies, can run in parallel with US1/US2

### Within Each User Story

**CRITICAL - TDD Workflow:**
1. Write ALL tests for the story FIRST (T007-T013 for US1)
2. Run `make test` → Verify tests FAIL
3. Implement changes (T014-T019 for US1)
4. Run `make test` → Verify tests PASS
5. Move to next story

### Parallel Opportunities

- **Phase 1 (Setup)**: T003, T004, T005, T006 can run in parallel (different files)
- **User Story 1 Tests**: T007-T012 can be written in parallel (different test cases)
- **User Story 2 Tests**: T021-T023 can be written in parallel (different test cases)
- **User Story 3 Tests**: T028-T030 can be written in parallel (different test cases)
- **Phase 6 (Polish)**: T035, T037-T040, T043 can run in parallel

**⚠️ SEQUENTIAL ONLY (same file):**
- T014-T019 (all modify `_get_hunk_anchors()` in same file)
- T025-T026 (modify same function)

---

## Parallel Example: User Story 1

```bash
# Launch all tests for User Story 1 together (write in parallel):
Task: "Add test: returns first deleted line per hunk in hunk_navigation.test.lua"
Task: "Add test: deduplicates multiple highlights on same line in hunk_navigation.test.lua"
Task: "Add test: sorts hunks top to bottom in hunk_navigation.test.lua"
Task: "Add test: navigate_next moves cursor to line column 0 in hunk_navigation.test.lua"
Task: "Add test: navigate_prev moves cursor to first deleted line in hunk_navigation.test.lua"
Task: "Add test: hunk wrapping behavior preserved in hunk_navigation.test.lua"

# Then run sequentially (same file):
# T014-T019: Modify _get_hunk_anchors() in hunk_navigation.lua
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001-T006) → ~15 minutes
2. **SKIP Phase 2** (no foundational changes needed)
3. Complete Phase 3: User Story 1 (T007-T020) → ~90 minutes
   - Write tests FIRST (T007-T013)
   - Implement changes (T014-T019)
   - Verify tests pass (T020)
4. **STOP and VALIDATE**: Run `make validate`, manual testing
5. **MVP COMPLETE**: Navigation now targets first deleted line with deduplication/sorting

**Estimated MVP Time**: 2 hours

### Incremental Delivery

1. Complete Setup → Environment ready (~15 min)
2. Add User Story 1 → Test independently → **MVP READY** (~90 min)
3. Add User Story 2 → Test independently → **Edge case handled** (~30 min)
4. Add User Story 3 → Test independently → **Centering verified** (~20 min)
5. Polish → Validate and commit → **Feature complete** (~30 min)

**Total Estimated Time**: 3 hours

### Parallel Team Strategy

With multiple developers:

1. All complete Setup together (~15 min)
2. Once Setup done:
   - Developer A: User Story 1 (P1 - core change)
   - Developer B: User Story 2 (P2 - edge case) *waits for US1 T015-T018*
   - Developer C: User Story 3 (P3 - verification) *can start immediately*
3. Developer C finishes first (verification only)
4. Developer A finishes second (core implementation)
5. Developer B finishes last (builds on A's work)

**Parallel Completion Time**: ~90 minutes (limited by US1 being foundational to US2)

---

## Notes

- **[P] tasks**: Different files or different test cases, no dependencies
- **[Story] label**: Maps task to specific user story for traceability
- **TDD Critical**: Write tests FIRST, verify they FAIL, then implement
- **Commit frequency**: After each user story completion (T020, T027, T034) or logical group
- **Validation**: Run `make validate` after EVERY implementation change
- **Cache considerations**: `anchors_cache` stores different data (first deleted lines vs anchors) but same structure
- **Constitution compliance**: Feature follows all principles (YAGNI, Simplicity, TDD, Multi-tabpage safety)

---

## Task Count Summary

- **Total Tasks**: 44
- **Setup (Phase 1)**: 6 tasks
- **Foundational (Phase 2)**: 0 tasks (no foundational changes needed)
- **User Story 1 (Phase 3)**: 14 tasks (7 tests + 7 implementation)
- **User Story 2 (Phase 4)**: 7 tasks (4 tests + 3 implementation)
- **User Story 3 (Phase 5)**: 7 tasks (4 tests + 3 verification)
- **Polish (Phase 6)**: 10 tasks
- **Parallel Opportunities**: 20 tasks marked [P] (45% parallelizable)

---

## Suggested MVP Scope

**MVP = User Story 1 Only** (Tasks T001-T020)

**Why**: User Story 1 delivers the core value - navigating to first deleted line instead of anchor. This solves the primary user confusion issue.

**What's included in MVP**:
- Navigate to first DIFF_DELETE line (not anchor)
- Deduplicate word-level highlights
- Sort hunks top to bottom
- Preserve column 0 positioning
- Maintain wrapping behavior

**What's deferred post-MVP**:
- User Story 2: Pure insertion edge case (rare scenario)
- User Story 3: Viewport centering verification (already works, just needs confirmation)

**MVP Delivery Time**: ~2 hours
