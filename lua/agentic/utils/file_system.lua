local Logger = require("agentic.utils.logger")
local BufHelpers = require("agentic.utils.buf_helpers")

--- @class agentic.utils.FileSystem
local FileSystem = {}

--- Read the file content from a buffer if loaded, to get unsaved changes,
--- or from disk otherwise
--- @param abs_path string
--- @return string[]|nil lines
--- @return string|nil error
function FileSystem.read_from_buffer_or_disk(abs_path)
    local bufnr = vim.fn.bufnr(abs_path)

    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        return lines, nil
    end

    local stat = vim.uv.fs_stat(abs_path)
    if stat and stat.type == "directory" then
        return nil, "Cannot read a directory as file: " .. abs_path
    end

    local file, open_err = io.open(abs_path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        content = (content or ""):gsub("\r\n", "\n")
        return vim.split(content, "\n"), nil
    end

    return nil, (open_err or ("Failed to open file: " .. abs_path))
end

--- Save content to disk at the given absolute path
--- @param abs_path string
--- @param content string
--- @return boolean success
--- @return string|nil error
function FileSystem.save_to_disk(abs_path, content)
    local file, open_err = io.open(abs_path, "w")

    if file then
        local ok, err = pcall(file.write, file, content)
        file:close()
        if ok then
            return true, nil
        else
            return false, "Failed to write content: " .. tostring(err)
        end
    end

    return false,
        "Failed to open file for writing: "
            .. abs_path
            .. ". Error: "
            .. tostring(open_err)
end

--- @param abs_path string
--- @param content string
--- @param callback fun(error: string|nil)
function FileSystem.write_file(abs_path, content, callback)
    local saved, err = FileSystem.save_to_disk(abs_path, content)

    if saved then
        local bufnr = vim.fn.bufnr(FileSystem.to_absolute_path(abs_path))

        if bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
            pcall(function()
                BufHelpers.execute_on_buffer(bufnr, function()
                    local view = vim.fn.winsaveview()
                    vim.cmd("checktime")
                    vim.fn.winrestview(view)
                end)
            end)
        end

        callback(nil)
        return
    end

    callback(err or ("Failed to write file: " .. abs_path))
end

--- @param abs_path string
--- @param line? integer
--- @param limit? integer
--- @param callback fun(content: string|nil)
function FileSystem.read_file(abs_path, line, limit, callback)
    local lines, err = FileSystem.read_from_buffer_or_disk(abs_path)
    lines = lines or {}

    if err ~= nil then
        Logger.notify(
            "Agent file read error: " .. err,
            vim.log.levels.ERROR,
            { title = " Read file error" }
        )
        callback(nil)
        return
    end

    if line ~= nil and limit ~= nil then
        lines = vim.list_slice(lines, line, line + limit)
    end

    local content = table.concat(lines, "\n")
    callback(content)
end

--- @param path string
function FileSystem.to_relative_path(path)
    return vim.fn.fnamemodify(path, ":.")
end

--- @param path string
function FileSystem.to_absolute_path(path)
    return vim.fn.fnamemodify(path, ":p")
end

--- @param path string
function FileSystem.base_name(path)
    return vim.fn.fnamemodify(path, ":t")
end

--- Convert a path to a "smart" path, which is:
--- - absolute if outside the current working directory
--- - relative to the current working directory
--- - or uses ~ for home directory
function FileSystem.to_smart_path(path)
    return vim.fn.fnamemodify(path, ":p:~:.")
end

return FileSystem
