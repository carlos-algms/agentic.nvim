--[[
  CRITICAL: Type annotations in this file are essential for Lua Language Server support.
  DO NOT REMOVE them. Only update them if the underlying types change.
--]]

--- @class agentic.acp.ClientInfo
--- @field name string
--- @field version string

--- @class agentic.acp.ClientCapabilities
--- @field fs agentic.acp.FileSystemCapability
--- @field terminal boolean

--- @class agentic.acp.InitializeParams
--- @field protocolVersion number
--- @field clientInfo agentic.acp.ClientInfo
--- @field clientCapabilities agentic.acp.ClientCapabilities

--- @class agentic.acp.FileSystemCapability
--- @field readTextFile boolean
--- @field writeTextFile boolean

--- @class agentic.acp.AgentCapabilities
--- @field loadSession boolean
--- @field promptCapabilities agentic.acp.PromptCapabilities

--- @class agentic.acp.PromptCapabilities
--- @field image boolean
--- @field audio boolean
--- @field embeddedContext boolean

--- @class agentic.acp.AuthMethod
--- @field id string
--- @field name string
--- @field description? string

--- @class agentic.acp.McpServer
--- @field name string
--- @field command string
--- @field args string[]
--- @field env agentic.acp.EnvVariable[]

--- @class agentic.acp.EnvVariable
--- @field name string
--- @field value string

--- @alias agentic.acp.StopReason
--- | "end_turn"
--- | "max_tokens"
--- | "max_turn_requests"
--- | "refusal"
--- | "cancelled"

--- @alias agentic.acp.ToolKind
--- | "read"
--- | "edit"
--- | "delete"
--- | "move"
--- | "search"
--- | "execute"
--- | "think"
--- | "fetch"
--- | "WebSearch"
--- | "SlashCommand"
--- | "SubAgent"
--- | "other"
--- | "create"
--- | "write"
--- | "Skill"
--- | "switch_mode"

--- @alias agentic.acp.ToolCallStatus
--- | "pending"
--- | "in_progress"
--- | "completed"
--- | "failed"

--- @alias agentic.acp.PlanEntryStatus
--- | "pending"
--- | "in_progress"
--- | "completed"

--- @alias agentic.acp.PlanEntryPriority
--- | "high"
--- | "medium"
--- | "low"

--- @class agentic.acp.RawInput
--- @field file_path string
--- @field new_string? string
--- @field old_string? string
--- @field replace_all? boolean
--- @field description? string
--- @field command? string
--- @field url? string Usually from the fetch tool
--- @field prompt? string Usually accompanying the fetch tool, not the web_search
--- @field query? string Usually from the web_search tool
--- @field timeout? number

--- @class agentic.acp.ToolCall
--- @field toolCallId string
--- @field rawInput? agentic.acp.RawInput

--- @class agentic.acp.ToolCallRegularContent
--- @field type "content"
--- @field content agentic.acp.Content

--- @class agentic.acp.ToolCallDiffContent
--- @field type "diff"
--- @field path string
--- @field oldText string
--- @field newText string

--- @alias agentic.acp.ACPToolCallContent
--- | agentic.acp.ToolCallRegularContent
--- | agentic.acp.ToolCallDiffContent

--- @class agentic.acp.ToolCallLocation
--- @field path string
--- @field line? number

--- @class agentic.acp.PlanEntry
--- @field content string
--- @field priority agentic.acp.PlanEntryPriority
--- @field status agentic.acp.PlanEntryStatus

--- @class agentic.acp.AvailableCommand
--- @field name string
--- @field description string
--- @field input? table<string, any>

--- @class agentic.acp.AgentMode
--- @field id string
--- @field name string
--- @field description? string

--- @class agentic.acp.Model
--- @field modelId string
--- @field name string
--- @field description string

--- @class agentic.acp.ModesInfo
--- @field availableModes agentic.acp.AgentMode[]
--- @field currentModeId string

--- @class agentic.acp.ModelsInfo
--- @field availableModels agentic.acp.Model[]
--- @field currentModelId string

--- @class agentic.acp.ConfigOption.Option
--- @field description string
--- @field name string
--- @field value string

--- @alias agentic.acp.ConfigOption.Category
--- | "mode"
--- | "model"
--- | "thought_level"

--- @class agentic.acp.ConfigOption
--- @field id string
--- @field category agentic.acp.ConfigOption.Category
--- @field currentValue string
--- @field description string
--- @field name string
--- @field options agentic.acp.ConfigOption.Option[]

--- @class agentic.acp.SessionCreationResponse
--- @field sessionId string
--- @field modes? agentic.acp.ModesInfo
--- @field models? agentic.acp.ModelsInfo
--- @field configOptions? agentic.acp.ConfigOption[]

--- @class agentic.acp.ResponseRaw
--- @field id? number
--- @field jsonrpc string
--- @field method string
--- @field result? table
--- @field params? { sessionId: string, update: agentic.acp.SessionUpdateMessage }
--- @field error? agentic.acp.ACPError

--- @class agentic.acp.ToolCallMessage
--- @field sessionUpdate "tool_call"
--- @field toolCallId string
--- @field title string most likely the command to be executed
--- @field kind agentic.acp.ToolKind
--- @field status agentic.acp.ToolCallStatus
--- @field content? agentic.acp.ACPToolCallContent[]
--- @field locations? agentic.acp.ToolCallLocation[]
--- @field rawInput? agentic.acp.RawInput

--- @class agentic.acp.ToolCallUpdate
--- @field sessionUpdate "tool_call_update"
--- @field toolCallId string
--- @field status? agentic.acp.ToolCallStatus
--- @field content? agentic.acp.ACPToolCallContent[]
--- @field rawOutput? table Not all providers are sending it, seems non standard

--- @class agentic.acp.PlanUpdate
--- @field sessionUpdate "plan"
--- @field entries agentic.acp.PlanEntry[]

--- @class agentic.acp.AvailableCommandsUpdate
--- @field sessionUpdate "available_commands_update"
--- @field availableCommands agentic.acp.AvailableCommand[]

--- @class agentic.acp.CurrentModeUpdate
--- @field sessionUpdate "current_mode_update"
--- @field currentModeId string

--- @class agentic.acp.UsageUpdate
--- @field sessionUpdate "usage_update"
--- @field used number Tokens currently in context
--- @field size number Total context window size in tokens
--- @field cost? { amount: number, currency: string } Cumulative session cost

--- @class agentic.acp.ConfigOptionsUpdate
--- @field sessionUpdate "config_option_update"
--- @field configOptions agentic.acp.ConfigOption[]

--- @alias agentic.acp.SessionUpdateMessage
--- | agentic.acp.UserMessageChunk
--- | agentic.acp.AgentMessageChunk
--- | agentic.acp.AgentThoughtChunk
--- | agentic.acp.ToolCallMessage
--- | agentic.acp.ToolCallUpdate
--- | agentic.acp.PlanUpdate
--- | agentic.acp.AvailableCommandsUpdate
--- | agentic.acp.CurrentModeUpdate
--- | agentic.acp.UsageUpdate
--- | agentic.acp.ConfigOptionsUpdate

--- @class agentic.acp.PermissionOption
--- @field optionId string
--- @field name string
--- @field kind "allow_once" | "allow_always" | "reject_once" | "reject_always"

--- @class agentic.acp.RequestPermission
--- @field options agentic.acp.PermissionOption[]
--- @field sessionId string
--- @field toolCall agentic.acp.ToolCall

--- @class agentic.acp.RequestPermissionOutcome
--- @field outcome "cancelled" | "selected"
--- @field optionId? string

--- @alias agentic.acp.ClientConnectionState
--- | "disconnected"
--- | "connecting"
--- | "connected"
--- | "initializing"
--- | "ready"
--- | "error"

--- @class agentic.acp.ACPError
--- @field code number
--- @field message string
--- @field data? any

--- @alias agentic.acp.ClientHandlers.on_session_update fun(update: agentic.acp.SessionUpdateMessage): nil
--- @alias agentic.acp.ClientHandlers.on_request_permission fun(request: agentic.acp.RequestPermission, callback: fun(option_id: string | nil)): nil
--- @alias agentic.acp.ClientHandlers.on_error fun(err: agentic.acp.ACPError): nil

--- @class agentic.Selection
--- @field lines string[] The selected code lines
--- @field start_line integer Starting line number (1-indexed)
--- @field end_line integer Ending line number (1-indexed, inclusive)
--- @field file_path string Relative file path
--- @field file_type string File type/extension

--- Handlers for a specific session. Each session subscribes with its own handlers.
--- @class agentic.acp.ClientHandlers
--- @field on_session_update agentic.acp.ClientHandlers.on_session_update
--- @field on_request_permission agentic.acp.ClientHandlers.on_request_permission
--- @field on_error agentic.acp.ClientHandlers.on_error
--- @field on_tool_call fun(tool_call: agentic.ui.MessageWriter.ToolCallBlock): nil
--- @field on_tool_call_update fun(tool_call: agentic.ui.MessageWriter.ToolCallBase): nil

--- @class agentic.acp.ACPProviderConfig
--- @field name? string Provider name
--- @field transport_type? agentic.acp.TransportType
--- @field command? string Command to spawn agent (for stdio)
--- @field args? string[] Arguments for agent command
--- @field env? table<string, string|nil> Environment variables
--- @field timeout? number Request timeout in milliseconds
--- @field reconnect? boolean Enable auto-reconnect
--- @field max_reconnect_attempts? number Maximum reconnection attempts
--- @field auth_method? string Authentication method
--- @field default_mode? string Default mode ID to set on session creation
