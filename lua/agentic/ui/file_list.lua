local FileSystem = require("agentic.utils.file_system")
local BufHelpers = require("agentic.utils.buf_helpers")

--- @class agentic.ui.FileList
--- @field _files string[]
--- @field _bufnr integer the same buffer number as the ChatWidget's files buffer
--- @field _on_change fun(fileList: agentic.ui.FileList)
local FileList = {}
FileList.__index = FileList

--- @param bufnr integer The files buffer number from ChatWidget
--- @param on_change fun(fileList: agentic.ui.FileList) Callback to trigger when file list changes (e.g., update header)
--- @return agentic.ui.FileList
function FileList:new(bufnr, on_change)
    local instance = setmetatable({
        _files = {},
        _bufnr = bufnr,
        _on_change = on_change,
    }, self)

    instance:_setup_keybindings()

    return instance
end

--- Add a file to the list if not already present
--- @param file_path string
--- @return boolean success
function FileList:add(file_path)
    for _, path in ipairs(self._files) do
        if path == file_path then
            return true
        end
    end

    local _ok, stat = pcall(vim.uv.fs_stat, file_path)

    if stat and stat.type == "file" then
        table.insert(self._files, file_path)
        self:_render()
        return true
    end

    return false
end

--- @param index integer
function FileList:remove_file_at(index)
    if index < 1 or index > #self._files then
        return
    end

    table.remove(self._files, index)
    self:_render()
end

--- @return string[]
function FileList:get_files()
    return vim.deepcopy(self._files)
end

function FileList:clear()
    self._files = {}
    self:_render()
end

--- @return boolean
function FileList:is_empty()
    return #self._files == 0
end

--- @private
function FileList:_render()
    local lines = {}

    for _, file in ipairs(self._files) do
        table.insert(lines, "-   " .. FileSystem.to_smart_path(file))
    end

    BufHelpers.with_modifiable(self._bufnr, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end)

    self._on_change(self)
end

--- @private
function FileList:_setup_keybindings()
    BufHelpers.keymap_set(self._bufnr, "n", "d", function()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local line = cursor[1]

        local line_content =
            vim.api.nvim_buf_get_lines(self._bufnr, line - 1, line, false)[1]

        if line_content and line_content:match("%S") then -- Check if line is not empty
            self:remove_file_at(line)
        end
    end, { nowait = true })

    BufHelpers.keymap_set(self._bufnr, "v", "d", function()
        local start_pos = vim.fn.getpos("v")
        local end_pos = vim.fn.getpos(".")
        local start_line = start_pos[2]
        local end_line = end_pos[2]

        -- Ensure start_line is always smaller than end_line (handle backward selection)
        if start_line > end_line then
            start_line, end_line = end_line, start_line
        end

        -- Remove files in reverse order to maintain correct indices
        for line = end_line, start_line, -1 do
            local line_content = vim.api.nvim_buf_get_lines(
                self._bufnr,
                line - 1,
                line,
                false
            )[1]

            if line_content and line_content:match("%S") then
                self:remove_file_at(line)
            end
        end

        -- Exit visual mode
        BufHelpers.feed_ESC_key()
    end, { nowait = true })
end

return FileList
