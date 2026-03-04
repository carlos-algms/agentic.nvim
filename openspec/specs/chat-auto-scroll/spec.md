# chat-auto-scroll Specification

## Purpose
TBD - created by archiving change fix-chat-auto-scroll. Update Purpose after archive.
## Requirements
### Requirement: Auto-scroll SHALL follow streaming content when user cursor is at the bottom

The chat buffer SHALL automatically scroll to the latest content
while the agent is streaming, as long as the cursor position in
the chat window is within `auto_scroll.threshold` lines of the
buffer's last line.

#### Scenario: User cursor is near bottom of chat during streaming

- **WHEN** the agent streams a message chunk
- **AND** the cursor is within `threshold` lines of the buffer end
- **THEN** the chat window scrolls to show the new content at the
  bottom

#### Scenario: User moves cursor up during streaming

- **WHEN** the agent streams a message chunk
- **AND** the user has moved the cursor up so it is more than
  `threshold` lines from the buffer end
- **THEN** the chat window does NOT scroll
- **AND** the user's cursor and viewport position are preserved

#### Scenario: Chat window is not visible

- **WHEN** the agent streams a message chunk
- **AND** the chat buffer has no visible window (e.g., tabpage is
  hidden)
- **THEN** auto-scroll SHALL still be considered active
- **AND** when the user returns to the chat tabpage, the viewport
  shows the latest content

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

- **WHEN** the timer has scrolled and reset
  `_should_auto_scroll` to `nil`
- **AND** the user scrolls up before the next write
- **AND** the next write triggers `_auto_scroll`
- **THEN** re-evaluation returns `false`
- **AND** auto-scroll does NOT execute

#### Scenario: Permission buttons do not break auto-scroll

- **WHEN** the user's cursor is at the bottom of the chat buffer
- **AND** `_should_auto_scroll` is `true`
- **AND** permission buttons are displayed (adding multiple
  lines)
- **THEN** `_should_auto_scroll` remains `true` (not
  re-evaluated)
- **AND** auto-scroll executes when the timer fires

### Requirement: Auto-scroll SHALL debounce during rapid streaming

The system SHALL debounce auto-scroll so that rapid sequential
content writes produce at most one scroll action per debounce
window, preventing scroll jitter and redundant viewport jumps.

#### Scenario: Multiple chunks arrive within debounce window

- **WHEN** three message chunks arrive within 150ms
- **THEN** only one scroll action executes (the last scheduled one)
- **AND** the viewport shows the latest content

### Requirement: Auto-scroll SHALL resume after user submits a new prompt

The system SHALL resume auto-scrolling after the user submits a
new prompt, because the chat widget scrolls to the bottom on
submit, placing the cursor back within threshold range.

#### Scenario: User submits prompt after scrolling up

- **WHEN** the user had moved the cursor up to read previous
  messages
- **AND** the user submits a new prompt
- **THEN** the chat window scrolls to the bottom
- **AND** subsequent streaming content auto-scrolls normally

### Requirement: Auto-scroll threshold SHALL be user-configurable

The `auto_scroll.threshold` config option SHALL control how many
lines from the buffer end the cursor must be for auto-scroll to
engage. Setting threshold to 0 or nil SHALL disable auto-scroll
entirely.

#### Scenario: Default threshold

- **WHEN** no custom config is provided
- **THEN** auto-scroll engages when the cursor is within 10 lines
  of the buffer end

#### Scenario: Threshold set to 0

- **WHEN** `auto_scroll.threshold` is set to `0`
- **THEN** auto-scroll is disabled entirely

### Requirement: Scroll timer SHALL be cleaned up on destroy

The debounce timer created by MessageWriter SHALL be stopped and
closed when the MessageWriter instance is destroyed, preventing
orphaned libuv handles from leaking memory.

#### Scenario: Session is destroyed

- **WHEN** the SessionManager is destroyed (e.g., tabpage closes)
- **THEN** the MessageWriter's scroll timer is stopped and closed
- **AND** no orphaned timer handles remain

