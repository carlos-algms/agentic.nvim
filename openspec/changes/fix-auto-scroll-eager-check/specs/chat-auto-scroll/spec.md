## MODIFIED Requirements

### Requirement: Auto-scroll decision SHALL be evaluated before content is written, not at scroll-execution time

The system SHALL maintain a `_should_auto_scroll` boolean field
with sticky-true semantics: only re-evaluate when the field is
not `true`. Once `true`, the field SHALL remain `true` until the
debounced timer callback consumes it (scrolls and resets to
`nil`).

This sticky-true behavior prevents buffer growth (from tool
calls, permission buttons, or any multi-line write) from
incorrectly flipping a `true` decision to `false`. Buffer writes
can only increase distance-from-bottom, never decrease it.

After the timer callback scrolls and resets the field, the next
`_auto_scroll` call re-evaluates fresh. At that point the cursor
has been moved to the bottom by `normal! G0zb`, so re-evaluation
reflects the correct state.

#### Scenario: Large tool call block does not break auto-scroll

- **WHEN** the user's cursor is at the bottom of the chat buffer
- **AND** `_should_auto_scroll` evaluates to `true`
- **AND** a tool call block writes 30+ lines to the buffer
- **THEN** `_should_auto_scroll` remains `true` (not
  re-evaluated)
- **AND** auto-scroll executes when the timer fires

#### Scenario: User scrolled up before tool call arrives

- **WHEN** the user has scrolled up in the chat buffer
- **AND** `_should_auto_scroll` evaluates to `false`
- **AND** a tool call block writes 30+ lines to the buffer
- **THEN** `_should_auto_scroll` re-evaluates (was not `true`)
  and remains `false`
- **AND** auto-scroll does NOT execute

#### Scenario: Decision resets after scroll executes

- **WHEN** the timer fires and `_should_auto_scroll` is `true`
- **AND** the scroll executes (`normal! G0zb`)
- **THEN** `_should_auto_scroll` is reset to `nil`
- **AND** the next `_auto_scroll` call re-evaluates fresh

#### Scenario: User scrolls up between timer cycles

- **WHEN** the timer has scrolled and reset `_should_auto_scroll`
  to `nil`
- **AND** the user scrolls up before the next write
- **AND** the next write triggers `_auto_scroll`
- **THEN** re-evaluation returns `false`
- **AND** auto-scroll does NOT execute

#### Scenario: Permission buttons do not break auto-scroll

- **WHEN** the user's cursor is at the bottom of the chat buffer
- **AND** `_should_auto_scroll` is `true`
- **AND** permission buttons are displayed (adding multiple lines)
- **THEN** `_should_auto_scroll` remains `true` (not
  re-evaluated)
- **AND** auto-scroll executes when the timer fires
