# Spec: Diff View Configuration

## Context

Users need to configure which diff preview mode they prefer: inline (virtual
lines), split (side-by-side buffers), or both.

## ADDED Requirements

### Requirement: Support diff preview mode configuration

The plugin MUST allow users to configure the diff preview mode via the
`diff_preview.mode` configuration field.

#### Scenario: Default mode is inline

**Given** a user has not configured `diff_preview.mode`
**When** the plugin loads
**Then** `Config.diff_preview.mode` MUST default to `"inline"`
**And** diff previews MUST use inline virtual line display

#### Scenario: Configure split mode

**Given** a user sets `diff_preview.mode = "split"` in their config
**When** an edit permission request with diff arrives
**Then** the plugin MUST display the diff in side-by-side split view
**And** NOT display inline virtual lines

#### Scenario: Configure both modes

**Given** a user sets `diff_preview.mode = "both"` in their config
**When** an edit permission request with diff arrives
**Then** the plugin MUST display both inline virtual lines AND side-by-side
split view

#### Scenario: Invalid mode value

**Given** a user sets `diff_preview.mode = "invalid"` in their config
**When** the plugin loads
**Then** the plugin MUST fall back to `"inline"` mode
**And** log a warning about the invalid configuration

### Requirement: Type-safe mode configuration

The configuration MUST enforce valid mode values through LuaCATS type
annotations.

#### Scenario: Type annotation defines allowed modes

**Given** the config type definitions
**When** a developer inspects `agentic.UserConfig.DiffPreview`
**Then** the `mode` field MUST be typed as
`"inline" | "split" | "both" | nil`
**And** Lua Language Server MUST provide autocomplete for valid values

### Requirement: Backwards compatibility

Existing configurations without the `mode` field MUST continue to work without
errors.

#### Scenario: Config without mode field

**Given** a user's config does NOT specify `diff_preview.mode`
**When** the plugin loads
**Then** the plugin MUST NOT throw an error
**And** MUST default to `"inline"` mode
**And** diff preview behavior MUST remain unchanged from previous versions

## Cross-References

- Depends on: N/A (foundational requirement)
- Required by: `split-view-display` spec (needs mode to determine behavior)
