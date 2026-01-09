local Logger = require("agentic.utils.logger")

--- @class agentic.Clipboard
local M = {}

--- @class agentic.Clipboard.SetupOpts
--- @field is_widget_open fun(): boolean Callback to check if the Chat widget is visible
--- @field on_paste fun(file_path: string): boolean Callback when file is pasted, returns success

--- Check if img-clip plugin is installed
--- @return boolean
function M.is_img_clip_installed()
    local ok = pcall(require, "img-clip")
    return ok
end

--- Show a floating message explaining img-clip is not installed
function M.show_img_clip_not_installed_message()
    local FloatingMessage = require("agentic.ui.floating_message")
    FloatingMessage.show({
        title = " Agentic.nvim - Image Clipboard ",

        body = {
            "# Failed to paste image from clipboard",
            "It seems you're trying to paste an image, but **hakonharnes/img-clip.nvim** isn't installed.",
            "",
            "You can install it by adding as a dependency to Agentic.nvim in your plugin manager.",
            "",
            "```lua",
            "{",
            '  "carlos-algms/agentic.nvim",',
            "  dependencies = {",
            "    {",
            '      "hakonharnes/img-clip.nvim",',
            "    },",
            "  },",
            "}",
            "```",
            "",
            "Restart Neovim and try pasting the image again.",
            "",
            "For more info: https://github.com/HakonHarnes/img-clip.nvim",
        },
    })
end

--- Paste image from clipboard using img-clip plugin
--- @return string|nil file path of saved image or nil on failure
function M.paste_image()
    if not M.is_img_clip_installed() then
        M.show_img_clip_not_installed_message()
        return
    end

    -- Prefer /tmp on Unix systems (Linux/macOS) for cleaner paths
    local tmp_dir = "/tmp"
    local stat = vim.uv.fs_stat(tmp_dir)
    if not stat or stat.type ~= "directory" then
        -- Fallback to system temp dir (Windows or unusual systems)
        -- Or current working directory if temp dir is unavailable (very unlikely)
        tmp_dir = vim.uv.os_tmpdir() or vim.fn.getcwd()
    end

    local file_name = "pasted_image_"
        .. vim.fn.strftime("%Y%m%d_%H%M%S")
        .. ".png"

    local file_path = vim.fs.joinpath(tmp_dir, file_name)

    Logger.debug("clipboard: saving image to", file_path)

    local ImgClipClipboard = require("img-clip.clipboard")
    local ok = ImgClipClipboard.save_image(file_path)

    if not ok then
        Logger.debug(
            "clipboard: failed to save image from clipboard",
            file_path
        )
        Logger.notify(
            "Failed to paste image from clipboard, not an image",
            vim.log.levels.ERROR
        )
        return nil
    end

    return file_path
end

--- Setup image paste/drag-and-drop support via vim.paste override
--- @param opts agentic.Clipboard.SetupOpts
function M.setup(opts)
    -- luacheck: ignore 122 (setting read-only field paste of global vim)
    vim.paste = (function(original_paste)
        --- @param lines string[]
        --- @param phase -1|1|2|3
        return function(lines, phase)
            if not opts.is_widget_open() then
                return original_paste(lines, phase)
            end

            local line = lines[1]

            -- Only handle single-line pastes that look like file paths
            if not line or line == "" or #lines > 1 then
                return original_paste(lines, phase)
            end

            -- Verify file exists
            local stat = vim.uv.fs_stat(line)
            if not stat or stat.type ~= "file" then
                Logger.debug("clipboard: file does not exist", line)
                return original_paste(lines, phase)
            end

            if opts.on_paste(line) then
                return true
            end

            Logger.debug("clipboard: on_paste returned false", line)
            return original_paste(lines, phase)
        end
    end)(vim.paste)
end

return M
