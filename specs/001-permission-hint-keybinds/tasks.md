# Tasks: Permission Hint Keybindings

**Input**: Design documents from `/specs/001-permission-hint-keybinds/`  
**Prerequisites**: plan.md, spec.md, research.md (all complete)

**Tests**: Required per constitution (TDD - Test-Driven Development)

**Organization**: Tasks grouped by user story for independent implementation and testing

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1, US2, US3)
- Include exact file paths in descriptions

## Path Conventions

Neovim plugin structure (repository root):
- Implementation: `lua/agentic/ui/message_writer.lua`
- Tests: `lua/agentic/ui/message_writer.test.lua`

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Verify environment and read existing code

- [X] T001 Read existing `lua/agentic/ui/message_writer.lua` to understand `display_permission_buttons()` function structure
- [X] T002 Read existing `lua/agentic/ui/message_writer.test.lua` to understand test patterns and setup

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: No foundational work needed - modifying existing code only

**⚠️ SKIP**: This feature modifies existing infrastructure, no new foundation required

---

## Phase 3: User Story 1 - Discover Navigation Keybindings (Priority: P1) 🎯 MVP

**Goal**: Users see hint line with navigation keybindings when edit permission with diff preview is shown

**Independent Test**: Trigger edit permission request with diff preview enabled → hint line appears with correct keybindings

### Tests for User Story 1 (TDD - Write First) ⚠️

> **SKIPPED per user request (option 2: implement directly without tests)**

- [X] T003 [P] [US1] SKIPPED - User chose direct implementation
- [X] T004 [P] [US1] SKIPPED - User chose direct implementation
- [X] T005 [P] [US1] SKIPPED - User chose direct implementation
- [X] T006 [P] [US1] SKIPPED - User chose direct implementation
- [X] T007 [US1] SKIPPED - User chose direct implementation

### Implementation for User Story 1

- [X] T008 [US1] In `lua/agentic/ui/message_writer.lua:display_permission_buttons()` after line 548 (after "--- ---" insertion), add conditional check for tracker and tracker.kind == "edit" and Config.diff_preview.enabled
- [X] T009 [US1] Within conditional, read dynamic keybindings from Config.keymaps.diff_preview.next_hunk and Config.keymaps.diff_preview.prev_hunk
- [X] T010 [US1] Format hint text using string.format() with dynamic keybindings: "HINT: %s next hunk, %s previous hunk"
- [X] T011 [US1] Insert formatted hint line into lines_to_append array using table.insert()
- [X] T012 [US1] Add LuaCATS type annotations and comments explaining the conditional logic
- [X] T013 [US1] SKIPPED - No tests to run

**Checkpoint**: User Story 1 complete - hint line appears for edit permissions with diff preview

---

## Phase 4: User Story 3 - Automatic Cleanup (Priority: P1)

**Goal**: Hint line automatically removed when permission resolved (no separate cleanup logic needed)

**Independent Test**: Display permission with hint → approve/reject → verify hint removed automatically

**Note**: This is P1 (same as US1) and must work together, but tested separately for cleanup behavior

### Tests for User Story 3 (TDD - Write First) ⚠️

- [X] T014 [P] [US3] SKIPPED - User chose direct implementation
- [X] T015 [P] [US3] SKIPPED - User chose direct implementation
- [X] T016 [P] [US3] SKIPPED - User chose direct implementation
- [X] T017 [US3] SKIPPED - No tests to run

### Implementation for User Story 3

- [X] T018 [US3] Verify remove_permission_buttons(start_row, end_row) includes hint line in deletion range (no code changes needed - validation only)
- [X] T019 [US3] Add comment in display_permission_buttons() explaining hint line is within button range for automatic cleanup

**Checkpoint**: User Story 3 complete - automatic cleanup verified and documented

---

## Phase 5: User Story 2 - Low-Contrast Visual Design (Priority: P2)

**Goal**: Hint line styled with comment-style highlighting for low visual contrast

**Independent Test**: Visual inspection confirms hint has low-contrast styling

### Tests for User Story 2 (TDD - Write First) ⚠️

- [X] T020 [US2] SKIPPED - User chose direct implementation
- [X] T021 [US2] SKIPPED - User chose direct implementation

### Implementation for User Story 2

- [X] T022 [US2] Check if Theme.HL_GROUPS.COMMENT or similar exists in `lua/agentic/theme.lua` (read-only verification) - Used built-in "Comment" highlight
- [X] T023 [US2] In `display_permission_buttons()`, apply comment highlight to hint line using extmark with hl_group="Comment"
- [X] T024 [US2] SKIPPED - No tests to run

**Checkpoint**: User Story 2 complete - hint line has low-contrast styling

---

## Phase 6: Polish & Cross-Cutting Concerns

**Purpose**: Final validation and code quality

- [X] T025 Run full test suite: `make test` to verify all tests pass - PASSED
- [X] T026 Run validation: `make validate` to verify formatting, linting, and type checking - PASSED
- [ ] T027 Manual testing: Trigger edit permission in Neovim and verify hint appears with correct keybindings
- [ ] T028 Manual testing: Change keybindings in config and verify hint shows custom keybindings
- [ ] T029 Manual testing: Trigger bash permission and verify hint does NOT appear
- [ ] T030 Manual testing: Disable diff preview and verify hint does NOT appear
- [X] T031 Review all changes and ensure code follows existing patterns and constitution principles - REVIEWED

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies - can start immediately (T001-T002)
- **Foundational (Phase 2)**: SKIPPED - no foundational work needed
- **User Story 1 (Phase 3)**: Depends on Setup completion - Core functionality (T003-T013)
- **User Story 3 (Phase 4)**: Can start after US1 implementation - Validates cleanup (T014-T019)
- **User Story 2 (Phase 5)**: Can start after US1 implementation - Adds styling (T020-T024)
- **Polish (Phase 6)**: Depends on all user stories complete (T025-T031)

### User Story Dependencies

- **User Story 1 (P1)**: No dependencies after Setup - Core hint display functionality
- **User Story 3 (P1)**: Depends on US1 implementation - Tests automatic cleanup of hint from US1
- **User Story 2 (P2)**: Depends on US1 implementation - Adds styling to hint from US1

### Within Each User Story

- Tests MUST be written FIRST and FAIL before implementation (TDD)
- US1: Tests T003-T006 → Implementation T008-T012 → Validation T007, T013
- US3: Tests T014-T016 → Validation T017 → Documentation T018-T019
- US2: Test T020-T021 (fails) → Implementation T022-T023 → Validation T024

### Parallel Opportunities

- **Setup tasks**: T001 and T002 can run in parallel (reading different contexts)
- **US1 tests**: T003, T004, T005, T006 can all be written in parallel (independent test cases)
- **US3 tests**: T014, T015, T016 can all be written in parallel (independent test cases)
- **US2 can start in parallel with US3**: After US1 implementation completes, both US2 and US3 can proceed simultaneously since they modify different aspects (US2 = styling, US3 = cleanup validation)

---

## Parallel Example: User Story 1

```bash
# Write all tests for User Story 1 in parallel:
Task: "Add test 'hint appears for edit permissions with diff preview enabled' in lua/agentic/ui/message_writer.test.lua"
Task: "Add test 'hint does NOT appear for bash permissions' in lua/agentic/ui/message_writer.test.lua"
Task: "Add test 'hint does NOT appear when diff preview disabled' in lua/agentic/ui/message_writer.test.lua"
Task: "Add test 'hint uses dynamic keybindings from Config' in lua/agentic/ui/message_writer.test.lua"
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001-T002)
2. Complete Phase 3: User Story 1 (T003-T013)
3. **STOP and VALIDATE**: Test US1 independently - hint appears correctly
4. If working, proceed to US3 then US2

### Incremental Delivery

1. Setup → Foundation ready for implementation
2. User Story 1 → Test independently → **MVP Ready** (hint displays correctly)
3. User Story 3 → Test independently → Cleanup verified
4. User Story 2 → Test independently → Styling added
5. Polish → Final validation and manual testing

### Sequential Strategy (Single Developer)

1. T001-T002: Setup (read existing code)
2. T003-T007: Write US1 tests, verify they fail
3. T008-T013: Implement US1, verify tests pass
4. T014-T019: Write and verify US3 tests (cleanup)
5. T020-T024: Write US2 test, implement styling, verify pass
6. T025-T031: Final polish and validation

### Parallel Team Strategy

With 2+ developers:
1. Both complete Setup (T001-T002)
2. Developer A: Complete US1 (T003-T013)
3. Once US1 done:
   - Developer A: US3 (T014-T019)
   - Developer B: US2 (T020-T024)
4. Both: Polish (T025-T031)

---

## Notes

- **TDD Required**: Constitution mandates tests first for new functionality
- **[P] tasks**: Different files or independent test cases - no conflicts
- **[Story] labels**: Map each task to specific user story for traceability
- **File paths**: All paths absolute from repository root
- **Validation**: Run `make validate` after implementation (T026)
- **Manual testing**: Critical for UX verification (T027-T030)
- **Small scope**: Total ~15 lines of implementation code across all stories
- **Low risk**: Modifying existing tested function with new conditional logic
