--- @class agentic.acp.SlashCommand
--- @field name string Command name without `/` prefix
--- @field description string

--- @class agentic.acp.SlashCommands
--- @field commands agentic.acp.SlashCommand[]
local SlashCommands = {}
SlashCommands.__index = SlashCommands

--- @return agentic.acp.SlashCommands
function SlashCommands:new()
    local instance = setmetatable({ list = {} }, self)
    return instance
end

--- Replace all commands with new list (keeps only name and description)
--- Validates each command has required fields, skips invalid commands
--- @param commands agentic.acp.AvailableCommand[]
function SlashCommands:setCommands(commands)
    self.commands = {}

    for _, cmd in ipairs(commands) do
        if cmd.name and cmd.description then
            table.insert(self.commands, {
                name = cmd.name,
                description = cmd.description,
            })
        end
    end
end

return SlashCommands

