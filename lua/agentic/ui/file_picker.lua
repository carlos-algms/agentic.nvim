local FileSystem = require("agentic.utils.file_system")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local KeymapFallback = require("agentic.utils.keymap_fallback")

--- @class agentic.ui.FilePicker
--- @field _files table[]
local FilePicker = {}
FilePicker.__index = FilePicker

FilePicker.CMD_RG = {
    "rg",
    "--files",
    "--color",
    "never",
    "--hidden",
    "--glob",
    "!.git/",
}

FilePicker.CMD_FD = {
    "fd",
    "--type",
    "f",
    "--color",
    "never",
    "--hidden",
    "--exclude",
    ".git/",
}

FilePicker.CMD_GIT = { "git", "ls-files", "-co", "--exclude-standard" }

--- Buffer-local storage (weak values for automatic cleanup)
local instances_by_buffer = setmetatable({}, { __mode = "v" })

--- @param bufnr number
--- @return agentic.ui.FilePicker|nil
function FilePicker:new(bufnr)
    if not Config.file_picker.enabled then
        return nil
    end

    --- @type agentic.ui.FilePicker
    local instance = setmetatable({ _files = {} }, self)
    instance:_setup_completion(bufnr)
    return instance
end

--- Completion menu accept sequence
--- Space after <C-y> ensures completion menu closes and user is ready to start a new completion
local COMPLETION_ACCEPT =
    vim.api.nvim_replace_termcodes("<C-y> ", true, true, true)

--- Sets up omnifunc completion and @ trigger detection
--- @param bufnr number
function FilePicker:_setup_completion(bufnr)
    vim.bo[bufnr].omnifunc =
        "v:lua.require'agentic.ui.file_picker'.complete_func"
    vim.bo[bufnr].iskeyword = vim.bo[bufnr].iskeyword .. ",@"
    instances_by_buffer[bufnr] = self

    local prev_tab_map = KeymapFallback.get_existing_mapping("i", "<Tab>")

    vim.keymap.set("i", "<Tab>", function()
        if vim.fn.pumvisible() == 1 then
            return COMPLETION_ACCEPT
        end

        -- Always check for existing mapping to handle lazy-loaded plugins
        -- the check is very fast and Tab isn't pressed frequently to cause noticeable lag
        prev_tab_map = KeymapFallback.get_existing_mapping("i", "<Tab>")
            or prev_tab_map
        return KeymapFallback.execute_fallback(prev_tab_map, "<Tab>")
    end, {
        buffer = bufnr,
        expr = true,
        replace_keycodes = false, -- Needed to avoid double-escaping, as it's true by default when expr=true
        desc = KeymapFallback.MARKER .. " Tab completion fallback",
    })

    local prev_cr_map = KeymapFallback.get_existing_mapping("i", "<CR>")

    vim.keymap.set("i", "<CR>", function()
        if vim.fn.pumvisible() == 1 then
            return COMPLETION_ACCEPT
        end

        -- Always check for existing mapping to handle lazy-loaded plugins
        prev_cr_map = KeymapFallback.get_existing_mapping("i", "<CR>")
            or prev_cr_map
        return KeymapFallback.execute_fallback(prev_cr_map, "<CR>")
    end, {
        buffer = bufnr,
        expr = true,
        replace_keycodes = false,
        desc = KeymapFallback.MARKER .. " CR completion fallback",
    })

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
                    self:scan_files()
                end

                if self._files and #self._files > 0 then
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
                end
            else
                last_at_pos = nil
            end
        end,
    })
end

function FilePicker:scan_files()
    local commands = self:_build_scan_commands()

    -- Try each command until one succeeds
    for _, cmd_parts in ipairs(commands) do
        Logger.debug("[FilePicker] Trying command:", vim.inspect(cmd_parts))
        local start_time = vim.loop.hrtime()

        local output = vim.fn.system(cmd_parts)
        local elapsed = (vim.loop.hrtime() - start_time) / 1e6

        Logger.debug(
            string.format(
                "[FilePicker] Command completed in %.2fms, exit_code: %d",
                elapsed,
                vim.v.shell_error
            )
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

            table.sort(files, function(a, b)
                return a.word < b.word
            end)

            self._files = files
            return files
        end
    end

    -- Fallback to glob if all commands failed
    Logger.debug("[FilePicker] All commands failed, using glob fallback")
    local files = {}
    local seen = {}
    -- Get all files including hidden files (dotfiles) and files inside hidden directories
    -- Note: vim.fn.glob() doesn't support brace expansion, so we need separate calls
    local glob_files = vim.fn.glob("**/*", false, true) -- Regular files
    local hidden_files = vim.fn.glob("**/.*", false, true) -- Dotfiles at any depth
    local files_in_hidden = vim.fn.glob("**/.*/**/*", false, true) -- Files inside dot dirs
    vim.list_extend(glob_files, hidden_files)
    vim.list_extend(glob_files, files_in_hidden)
    Logger.debug("[FilePicker] Glob returned", #glob_files, "paths")

    for _, path in ipairs(glob_files) do
        if vim.fn.isdirectory(path) == 0 and not self:_should_exclude(path) then
            local relative_path = FileSystem.to_smart_path(path)
            if not seen[relative_path] then
                seen[relative_path] = true
                table.insert(files, {
                    word = "@" .. relative_path,
                    menu = "File",
                    kind = "@",
                    icase = 1,
                })
            end
        end
    end

    table.sort(files, function(a, b)
        return a.word < b.word
    end)

    self._files = files
    return files
end

--- Builds list of all available scan commands to try in order
--- All commands run in current working directory by default
--- @return table[] commands List of command arrays to try
function FilePicker:_build_scan_commands()
    local commands = {}

    if vim.fn.executable(FilePicker.CMD_RG[1]) == 1 then
        table.insert(commands, vim.list_extend({}, FilePicker.CMD_RG))
    end

    if vim.fn.executable(FilePicker.CMD_FD[1]) == 1 then
        table.insert(commands, vim.list_extend({}, FilePicker.CMD_FD))
    end

    if vim.fn.executable(FilePicker.CMD_GIT[1]) == 1 then
        local _ = vim.fn.system("git rev-parse --git-dir 2>/dev/null")
        if vim.v.shell_error == 0 then
            table.insert(commands, vim.list_extend({}, FilePicker.CMD_GIT))
        end
    end

    return commands
end

--- used exclusively with glob fallback to exclude common unwanted files
FilePicker.GLOB_EXCLUDE_PATTERNS = {
    "^%.$",
    "^%.%.$",
    "%.git/",
    "%.DS_Store$",
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
    "%.turbo/",
    "out/",
    -- Coverage
    "coverage/",
    "%.nyc_output/",
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
    for _, pattern in ipairs(FilePicker.GLOB_EXCLUDE_PATTERNS) do
        if path:match(pattern) then
            return true
        end
    end

    return false
end

--- Omnifunc completion function (called by Neovim)
--- @param findstart number 1 for finding start position, 0 for returning matches
--- @param _base string The text to complete
--- @return number|table
function FilePicker.complete_func(findstart, _base)
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
