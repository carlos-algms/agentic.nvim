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

### Requirement: Auto-scroll decision SHALL be evaluated at scroll time, not at write time

The system SHALL evaluate whether to auto-scroll at the moment
the scroll would execute (after debounce delay), not when content
is first written to the buffer. This ensures the decision reflects
the user's current cursor position, not a stale snapshot.

#### Scenario: User moves cursor up between write and scroll execution

- **WHEN** a message chunk is written to the buffer
- **AND** the user moves the cursor up before the debounce delay
  elapses
- **THEN** auto-scroll does NOT execute because the cursor check
  happens after the delay

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

