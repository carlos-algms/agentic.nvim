--- Neovim completion item structure (vim.fn.complete() dictionary format)
--- For complete list of properties, see |complete-items| in insert.txt help manual
--- @class agentic.acp.CompletionItem
--- @field word string The text to insert (mandatory)
--- @field menu string Description shown in completion menu
--- @field kind string Type/category of completion item
--- @field icase number 1 for case-insensitive, 0 for case-sensitive

--- @class agentic.acp.SlashCommands
--- @field commands agentic.acp.CompletionItem[]
local SlashCommands = {}
SlashCommands.__index = SlashCommands

--- Weak map: bufnr -> SlashCommands instance
--- @type table<number, agentic.acp.SlashCommands>
local instances_by_buffer = setmetatable({}, { __mode = "v" })

--- @param bufnr integer The input buffer number, the same as in the ChatWidget class instance
--- @return agentic.acp.SlashCommands
function SlashCommands:new(bufnr)
    local instance = setmetatable({ commands = {} }, self)
    instance:_setup_completion(bufnr)
    return instance
end

--- Replace all commands with new list in completion format
--- Validates each command has required fields, skips invalid commands and commands with spaces
--- Filters out `clear` command (handled by specific agents internally)
--- Automatically adds `/new` command if not provided by agent
--- @param commands agentic.acp.AvailableCommand[]
function SlashCommands:setCommands(commands)
    self.commands = {}
    local has_new_command = false

    for _, cmd in ipairs(commands) do
        if
            cmd.name
            and cmd.description
            and not cmd.name:match("%s")
            and cmd.name ~= "clear"
        then
            if cmd.name == "new" then
                has_new_command = true
            end

            --- @type agentic.acp.CompletionItem
            local completion_item = {
                word = cmd.name,
                menu = cmd.description,
                kind = "Slash",
                icase = 1,
            }
            table.insert(self.commands, completion_item)
        end
    end

    -- Add /new command if not provided by agent
    if not has_new_command then
        --- @type agentic.acp.CompletionItem
        local new_command = {
            word = "new",
            menu = "Start a new session",
            kind = "Slash",
            icase = 1,
        }
        table.insert(self.commands, new_command)
    end
end

--- Setup native Neovim completion for slash commands in the input buffer
--- Uses completefunc with <C-x><C-u> trigger
--- Neovim handles fuzzy filtering automatically via completeopt
--- @param bufnr integer The input buffer number
--- @private
function SlashCommands:_setup_completion(bufnr)
    vim.bo[bufnr].completeopt = "menu,menuone,noinsert,popup,fuzzy"

    -- Include `-` as keyword character so completion doesn't close when typing it
    vim.bo[bufnr].iskeyword = vim.bo[bufnr].iskeyword .. ",-"

    -- Store instance for completefunc access
    instances_by_buffer[bufnr] = self

    -- Set completefunc to return our commands
    vim.bo[bufnr].completefunc =
        "v:lua.require'agentic.acp.slash_commands'._complete_func"

    vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = bufnr,
        callback = function()
            if #self.commands == 0 then
                return
            end

            local cursor = vim.api.nvim_win_get_cursor(0)
            local row = cursor[1]
            local col = cursor[2]

            if row ~= 1 or col < 1 then
                return
            end

            local line = vim.api.nvim_get_current_line()

            if not line:match("^/") or line:match("%s") then
                return
            end

            -- Feed <C-x><C-u> to trigger completefunc
            vim.api.nvim_feedkeys(
                vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true),
                "n",
                false
            )
        end,
    })
end

--- Completion function for completefunc
--- @param findstart number 1 to find start of completion, 0 to return matches
--- @param base string The text to match when findstart=0
--- @return number|table Start column when findstart=1, completion items when findstart=0
function SlashCommands._complete_func(findstart, base)
    if findstart == 1 then
        -- Return the column where the completion starts (after the "/")
        return 1
    end

    local bufnr = vim.api.nvim_get_current_buf()
    local instance = instances_by_buffer[bufnr]
    -- Return the completion items
    if instance and instance.commands then
        return instance.commands
    end
    return {}
end

return SlashCommands
