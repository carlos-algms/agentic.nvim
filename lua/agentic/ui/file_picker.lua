local FileSystem = require("agentic.utils.file_system")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.ui.FilePicker
--- @field _files table[]
local FilePicker = {}
FilePicker.__index = FilePicker

--- Buffer-local storage (weak values for automatic cleanup)
local instances_by_buffer = setmetatable({}, { __mode = "v" })

--- @param bufnr number
--- @return agentic.ui.FilePicker|nil
function FilePicker.new(bufnr)
    if not Config.file_picker.enabled then
        return nil
    end

    --- @type agentic.ui.FilePicker
    local instance = setmetatable({ _files = {} }, FilePicker)
    instance:_setup_completion(bufnr)
    return instance
end

--- Sets up omnifunc completion and @ trigger detection
--- @param bufnr number
function FilePicker:_setup_completion(bufnr)
    vim.bo[bufnr].omnifunc =
        "v:lua.require'agentic.ui.file_picker'._complete_func"
    vim.bo[bufnr].iskeyword = vim.bo[bufnr].iskeyword .. ",@"
    instances_by_buffer[bufnr] = self

    -- Space after <C-y> ensures completion menu closes and user is ready to type `@` again and start a new completion
    vim.keymap.set("i", "<Tab>", function()
        if vim.fn.pumvisible() == 1 then
            return "<C-y> "
        else
            return "<Tab>"
        end
    end, { buffer = bufnr, expr = true, noremap = true })

    vim.keymap.set("i", "<CR>", function()
        if vim.fn.pumvisible() == 1 then
            return "<C-y> "
        else
            return "<CR>"
        end
    end, { buffer = bufnr, expr = true, noremap = true })

    local last_at_pos = nil

    vim.api.nvim_create_autocmd("TextChangedI", {
        buffer = bufnr,
        callback = function()
            local cursor = vim.api.nvim_win_get_cursor(0)
            local line = vim.api.nvim_get_current_line()
            local before_cursor = line:sub(1, cursor[2])

            -- Match @ at start of line or after whitespace (space/tab)
            local at_match = before_cursor:match("^@[^%s]*$")
                or before_cursor:match("[%s]@[^%s]*$")

            if at_match then
                local at_pos = before_cursor:reverse():find("@")
                local current_pos = cursor[2] - at_pos

                -- Only scan if this is a new @ position
                if current_pos ~= last_at_pos then
                    last_at_pos = current_pos
                    self:_scan_files()
                end

                -- Set popup menu width a % of editor width
                -- Neovim will auto-reposition ("nudge") the menu to fit on screen
                vim.opt_local.pumwidth = math.floor(vim.o.columns * 0.6)

                vim.api.nvim_feedkeys(
                    vim.api.nvim_replace_termcodes(
                        "<C-x><C-o>",
                        true,
                        false,
                        true
                    ),
                    "n",
                    false
                )
            else
                last_at_pos = nil
            end
        end,
    })
end

function FilePicker:_scan_files()
    local scan_root = self:_get_scan_root()
    local cmd_parts = self:_build_scan_command(scan_root)

    if cmd_parts then
        Logger.debug("[FilePicker] Starting sync scan:", vim.inspect(cmd_parts))
        local start_time = vim.loop.hrtime()

        local output = vim.fn.system(cmd_parts)
        local elapsed = (vim.loop.hrtime() - start_time) / 1e6

        Logger.debug(
            "[FilePicker] Command completed in",
            string.format("%.2fms", elapsed),
            "exit_code:",
            vim.v.shell_error
        )

        if vim.v.shell_error == 0 and output ~= "" then
            local files = {}
            for line in output:gmatch("[^\n]+") do
                if line ~= "" then
                    local relative_path = FileSystem.to_smart_path(line)
                    table.insert(files, {
                        word = "@" .. relative_path,
                        menu = "File",
                        kind = "@",
                        icase = 1,
                    })
                end
            end

            self._files = files
        end
    else
        Logger.debug("[FilePicker] Using glob fallback (synchronous)")
        local files = {}
        local glob_files = vim.fn.glob(scan_root .. "/**/*", false, true)
        Logger.debug("[FilePicker] Glob returned", #glob_files, "paths")

        for _, path in ipairs(glob_files) do
            if
                vim.fn.isdirectory(path) == 0 and not self:_should_exclude(path)
            then
                local relative_path = FileSystem.to_smart_path(path)
                table.insert(files, {
                    word = "@" .. relative_path,
                    menu = "File",
                    kind = "@",
                    icase = 1,
                })
            end
        end

        self._files = files
    end
end

--- @param scan_root string
--- @return table|nil command
function FilePicker:_build_scan_command(scan_root)
    if vim.fn.executable("rg") == 1 then
        return {
            "rg",
            "--files",
            "--color",
            "never",
            "--no-require-git",
            "--hidden",
            "--glob",
            "!.git/",
            scan_root,
        }
    end

    if vim.fn.executable("fd") == 1 then
        return {
            "fd",
            "--type",
            "f",
            "--color",
            "never",
            "--hidden",
            "--exclude",
            ".git",
            "--base-directory",
            scan_root,
        }
    end

    if vim.fn.executable("git") == 1 then
        local _ = vim.fn.system("git rev-parse --git-dir 2>/dev/null")
        if vim.v.shell_error == 0 then
            return { "git", "ls-files", "-co", "--exclude-standard" }
        end
    end

    return nil
end

--- used exclusively with glob fallback to exclude common unwanted files
local exclude_patterns = {
    "%.git/",
    "node_modules/",
    "%.pyc$",
    "%.swp$",
    "__pycache__/",
    "dist/",
    "build/",
    "vendor/",
    "%.next/",
    -- Java/JVM
    "target/",
    "%.gradle/",
    "%.m2/",
    -- Ruby
    "%.bundle/",
    -- Build/Cache
    "%.cache/",
    ".turbo/",
    "out/",
    -- Coverage
    "coverage/",
    ".nyc_output/",
    -- Package managers
    "%.npm/",
    "%.yarn/",
    "%.pnpm%-store/",
    "bower_components/",
}

--- Checks if path should be excluded from the file list
--- Necessary when using glob fallback, since it can't exclude files
--- @param path string
--- @return boolean
function FilePicker:_should_exclude(path)
    for _, pattern in ipairs(exclude_patterns) do
        if path:match(pattern) then
            return true
        end
    end

    return false
end

--- Gets the root directory to scan for files
--- @return string
function FilePicker:_get_scan_root()
    local git_root = vim.fn.system("git rev-parse --show-toplevel 2>/dev/null")
    if vim.v.shell_error == 0 and git_root ~= "" then
        return (git_root:gsub("\n", ""))
    end
    return vim.fn.getcwd()
end

--- Omnifunc completion function (called by Neovim)
--- @param findstart number 1 for finding start position, 0 for returning matches
--- @param _base string The text to complete
--- @return number|table
function FilePicker._complete_func(findstart, _base)
    if findstart == 1 then
        local line = vim.api.nvim_get_current_line()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local before_cursor = line:sub(1, cursor[2])

        local at_pos = before_cursor:reverse():find("@")
        if at_pos then
            local start_col = cursor[2] - at_pos
            return start_col
        end
        -- Return -3: Cancel silently and leave completion mode (see :h complete-functions)
        return -3
    else
        local bufnr = vim.api.nvim_get_current_buf()
        local instance = instances_by_buffer[bufnr]
        if not instance then
            Logger.debug("[FilePicker] No instance found for buffer:", bufnr)
            return {}
        end

        -- Return all files - Neovim handles fuzzy filtering
        return instance._files
    end
end

return FilePicker
