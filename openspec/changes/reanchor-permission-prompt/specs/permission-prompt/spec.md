## ADDED Requirements

### Requirement: Permission prompt reanchoring

The system SHALL reanchor (remove and re-render at the buffer bottom)
the active permission prompt whenever new content is appended to the
chat buffer while a permission request is pending, so the buttons
remain visible to the user.

#### Scenario: New tool call arrives while permission prompt is pending

- **WHEN** a permission prompt is displayed in the chat buffer
- **AND** a new tool call block is written to the buffer
- **THEN** the permission buttons are removed from their old position
- **AND** re-rendered at the new buffer bottom
- **AND** keymap bindings (1-4) remain functional

#### Scenario: Tool call update arrives while permission prompt is pending

- **WHEN** a permission prompt is displayed in the chat buffer
- **AND** an existing tool call block is updated in the buffer
- **THEN** the permission buttons are moved to the new buffer bottom

#### Scenario: Full message arrives while permission prompt is pending

- **WHEN** a permission prompt is displayed in the chat buffer
- **AND** a full agent message is written to the buffer
- **THEN** the permission buttons are moved to the new buffer bottom

#### Scenario: Message chunk arrives while permission prompt is pending

- **WHEN** a permission prompt is displayed in the chat buffer
- **AND** a message chunk is appended to the buffer
- **THEN** the permission buttons are moved to the new buffer bottom

#### Scenario: No reanchor when no permission is pending

- **WHEN** no permission prompt is currently displayed
- **AND** new content is appended to the buffer
- **THEN** no reanchor operation occurs

#### Scenario: Reanchor does not trigger recursion

- **WHEN** the reanchor operation modifies the buffer (remove + append)
- **THEN** the content-appended callback does not fire during reanchor
- **AND** no infinite loop occurs

#### Scenario: Completing permission clears reanchor hook

- **WHEN** the user selects a permission option
- **THEN** the content-appended callback is cleared
- **AND** subsequent buffer appends do not trigger reanchor logic
