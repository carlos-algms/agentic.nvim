# ui-layout Specification

## Purpose
TBD - created by archiving change add-dynamic-code-window-sizing. Update Purpose after archive.
## Requirements
### Requirement: Code Selection Window Dynamic Sizing

The code selection window SHALL dynamically adjust its height based on buffer content, respecting a user-configurable maximum height limit.

#### Scenario: Small snippet shows compact window

- **WHEN** the code selection buffer contains 3 lines of content
- **THEN** the window height SHALL be 4 lines (3 content + 1 padding for header)

#### Scenario: Large snippet respects max height

- **WHEN** the code selection buffer contains 20 lines of content
- **AND** the configured `max_height` is 15
- **THEN** the window height SHALL be 15 lines (capped at max_height)

#### Scenario: Empty buffer window is not displayed

- **WHEN** the code selection buffer is empty
- **THEN** the code selection window SHALL NOT be displayed

#### Scenario: Single line snippet

- **WHEN** the code selection buffer contains 1 line of content
- **THEN** the window height SHALL be 2 lines (1 content + 1 padding for header)

### Requirement: Code Window Height Configuration

Users SHALL be able to configure the maximum height for the code selection window through the plugin configuration.

#### Scenario: Default max height

- **WHEN** no custom configuration is provided
- **THEN** the code selection window max height SHALL default to 15 lines

#### Scenario: Custom max height

- **WHEN** user sets `windows.code.max_height = 20` in configuration
- **THEN** the code selection window SHALL respect the 20-line maximum

#### Scenario: Configuration validation

- **WHEN** the configuration is loaded
- **THEN** `windows.code.max_height` MUST be a positive integer

