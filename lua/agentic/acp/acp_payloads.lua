local FileSystem = require("agentic.utils.file_system")

--- @class agentic.acp.ACPPayloads
local M = {}

--- @param text string|string[]
--- @return agentic.acp.UserMessageChunk
function M.generate_user_message(text)
    return M._generate_message_chunk(text, "user_message_chunk") --[[@as agentic.acp.UserMessageChunk]]
end

--- @param text string|string[]
--- @return agentic.acp.AgentMessageChunk
function M.generate_agent_message(text)
    return M._generate_message_chunk(text, "agent_message_chunk") --[[@as agentic.acp.AgentMessageChunk]]
end

--- @param text string|string[]
--- @param role "user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk"
function M._generate_message_chunk(text, role)
    local content_text

    if type(text) == "string" then
        content_text = text
    elseif type(text) == "table" then
        content_text = table.concat(text, "\n")
    else
        content_text = vim.inspect(text)
    end

    return { --- @type agentic.acp.UserMessageChunk|agentic.acp.AgentMessageChunk|agentic.acp.AgentThoughtChunk
        sessionUpdate = role,
        content = {
            type = "text",
            text = content_text,
        },
    }
end

--- @param path string
--- @return agentic.acp.Content
function M.create_file_content(path)
    local abs_path = FileSystem.to_absolute_path(path)
    local uri = "file://" .. abs_path
    local ext = FileSystem.get_file_extension(path)

    local mime = FileSystem.IMAGE_MIMES[ext]

    -- It's an image file
    if mime then
        --- @type agentic.acp.ImageContent
        local content = {
            type = "image",
            mimeType = mime,
            uri = uri,
            data = FileSystem.read_file_base64(abs_path),
        }

        return content
    end

    mime = FileSystem.AUDIO_MIMES[ext]

    -- It's an audio file
    if mime then
        --- @type agentic.acp.AudioContent
        local content = {
            type = "audio",
            mimeType = mime,
            uri = uri,
            data = FileSystem.read_file_base64(abs_path),
        }

        return content
    end

    return M.create_resource_link_content(path)
end

--- @param path string
--- @return agentic.acp.ResourceLinkContent
function M.create_resource_link_content(path)
    local uri = "file://" .. FileSystem.to_absolute_path(path)
    local name = FileSystem.base_name(path)

    --- @type agentic.acp.ResourceLinkContent
    local resource = {
        type = "resource_link",
        uri = uri,
        name = name,
    }

    return resource
end

return M

--- @class agentic.acp.UserMessageChunk
--- @field sessionUpdate "user_message_chunk"
--- @field content agentic.acp.Content

--- @class agentic.acp.AgentMessageChunk
--- @field sessionUpdate "agent_message_chunk"
--- @field content agentic.acp.Content

--- @class agentic.acp.AgentThoughtChunk
--- @field sessionUpdate "agent_thought_chunk"
--- @field content agentic.acp.Content

--- @class agentic.acp.ResourceLinkContent
--- @field type "resource_link"
--- @field uri string
--- @field name string
--- @field description? string
--- @field mimeType? string
--- @field size? number
--- @field title? string
--- @field annotations? agentic.acp.Annotations

--- @class agentic.acp.ResourceContent
--- @field type "resource"
--- @field resource agentic.acp.EmbeddedResource
--- @field annotations? agentic.acp.Annotations

--- @class agentic.acp.EmbeddedResource
--- @field uri string
--- @field text string
--- @field blob? string
--- @field mimeType? string

--- @alias agentic.acp.Annotations.Audience "user" | "assistant"

--- @class agentic.acp.Annotations
--- @field audience? agentic.acp.Annotations.Audience[]
--- @field lastModified? string
--- @field priority? number

--- @class agentic.acp.TextContent
--- @field type "text"
--- @field text string
--- @field annotations? agentic.acp.Annotations

--- @class agentic.acp.ImageContent
--- @field type "image"
--- @field data string
--- @field mimeType string
--- @field uri? string
--- @field annotations? agentic.acp.Annotations

--- @class agentic.acp.AudioContent
--- @field type "audio"
--- @field data string
--- @field mimeType string
--- @field annotations? agentic.acp.Annotations

--- @alias agentic.acp.Content
--- | agentic.acp.TextContent
--- | agentic.acp.ImageContent
--- | agentic.acp.AudioContent
--- | agentic.acp.ResourceLinkContent
--- | agentic.acp.ResourceContent
