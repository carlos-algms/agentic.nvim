local Logger = require("agentic.utils.logger")
local BufHelpers = require("agentic.utils.buf_helpers")

--- Image indicator format string
local IMAGE_INDICATOR_FORMAT = "[Image #%d]"

--- @class agentic.ui.ImageData
--- @field data string Base64 encoded image data
--- @field mimeType string e.g., "image/png", "image/jpeg"

--- @class agentic.ui.ImageManager
--- @field _images agentic.ui.ImageData[]
--- @field _bufnr integer The input buffer number
--- @field _on_change fun(imageManager: agentic.ui.ImageManager)
local ImageManager = {}
ImageManager.__index = ImageManager

--- @param bufnr integer The input buffer number from ChatWidget
--- @param on_change fun(imageManager: agentic.ui.ImageManager) Callback when images change
--- @return agentic.ui.ImageManager
function ImageManager:new(bufnr, on_change)
    local Config = require("agentic.config")

    local instance = setmetatable({
        _images = {},
        _bufnr = bufnr,
        _on_change = on_change,
    }, self)

    instance:_setup_keybindings(Config.keymaps.prompt.paste_image)

    return instance
end

--- Validate image size against configured maximum
--- @param size number Size in bytes
--- @return boolean is_valid
--- @return string error_message (only when is_valid is false)
local function validate_image_size(size)
    local Config = require("agentic.config")
    local max_size = Config.image.max_size_bytes

    if size > max_size then
        local max_mb = math.floor(max_size / (1024 * 1024))
        return false, string.format("Image too large (max %dMB)", max_mb)
    end

    return true, ""
end

--- Encode binary data to base64 with performance optimization for large data
--- @param content string Binary content to encode
--- @return string|nil base64_data
local function encode_base64(content)
    -- Use vim.schedule for large images to avoid blocking UI
    if #content > 1024 * 1024 then -- >1MB
        local b64
        vim.schedule(function()
            b64 = vim.base64.encode(content)
        end)
        -- Wait for encoding to complete
        vim.wait(5000, function()
            return b64 ~= nil
        end)
        return b64
    else
        return vim.base64.encode(content)
    end
end

--- Get clipboard image data as base64
--- @return string|nil base64_data
--- @return string|nil mime_type
function ImageManager:_get_clipboard_image()
    -- macOS using pngpaste
    if vim.fn.has("mac") == 1 then
        -- Check if pngpaste is available
        local handle = io.popen("command -v pngpaste 2>/dev/null")
        if not handle then
            Logger.notify(
                "pngpaste not found. Install with: brew install pngpaste",
                vim.log.levels.ERROR
            )
            return nil, nil
        end

        local pngpaste_path = handle:read("*a"):gsub("%s+$", "")
        handle:close()

        if pngpaste_path == "" then
            Logger.notify(
                "pngpaste not found. Install with: brew install pngpaste",
                vim.log.levels.ERROR
            )
            return nil, nil
        end

        -- Create temp file
        local tmpfile = os.tmpname() .. ".png"

        -- Use vim.system() to avoid shell injection
        local result = vim.system({ "pngpaste", tmpfile }, { text = false })
            :wait()

        if result.code ~= 0 then
            pcall(os.remove, tmpfile)
            return nil, nil
        end

        -- Read and base64 encode
        local file = io.open(tmpfile, "rb")
        if not file then
            pcall(os.remove, tmpfile)
            return nil, nil
        end

        local content, err = file:read("*a")
        file:close()

        if not content then
            Logger.debug("Failed to read temporary image file:", err)
            pcall(os.remove, tmpfile)
            return nil, nil
        end

        local ok = pcall(os.remove, tmpfile)
        if not ok then
            Logger.debug("Failed to remove temporary image file:", tmpfile)
        end

        if #content > 0 then
            -- Validate size
            local is_valid, error_msg = validate_image_size(#content)
            if not is_valid then
                Logger.notify(error_msg, vim.log.levels.ERROR)
                return nil, nil
            end

            -- Encode to base64
            local b64 = encode_base64(content)
            return b64, "image/png"
        end

        return nil, nil
    elseif vim.fn.has("unix") == 1 then
        -- Linux - Not currently supported (untested)
        Logger.notify(
            "Image paste is only supported on macOS at this time",
            vim.log.levels.WARN
        )
        return nil, nil
    elseif vim.fn.has("win32") == 1 then
        -- Windows - Not currently supported (untested)
        Logger.notify(
            "Image paste is only supported on macOS at this time",
            vim.log.levels.WARN
        )
        return nil, nil
    end

    return nil, nil
end

--- Add image from clipboard
function ImageManager:paste_from_clipboard()
    local base64_data, mime_type = self:_get_clipboard_image()

    if not base64_data then
        Logger.notify("No image found in clipboard", vim.log.levels.WARN)
        return
    end

    table.insert(self._images, {
        data = base64_data,
        mimeType = mime_type,
    })

    -- Add visual indicator to buffer
    self:_add_indicator()

    -- Trigger change callback
    if self._on_change then
        self._on_change(self)
    end

    Logger.notify(
        string.format("Image added (%d total)", #self._images),
        vim.log.levels.INFO
    )
end

--- Add visual indicator to input buffer
function ImageManager:_add_indicator()
    BufHelpers.with_modifiable(self._bufnr, function(bufnr)
        -- Find window displaying this buffer
        local winid = vim.fn.bufwinid(bufnr)
        if winid == -1 then
            -- Buffer not visible, append to end
            local line_count = vim.api.nvim_buf_line_count(bufnr)
            local last_line = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)[1]
                or ""
            local indicator = " "
                .. string.format(IMAGE_INDICATOR_FORMAT, #self._images)
            vim.api.nvim_buf_set_lines(
                bufnr,
                line_count - 1,
                line_count,
                false,
                { last_line .. indicator }
            )
            return
        end

        -- Get cursor position from the correct window
        local cursor = vim.api.nvim_win_get_cursor(winid)
        local line = cursor[1] - 1
        local col = cursor[2]

        -- Insert image indicator text
        local current_line = vim.api.nvim_buf_get_lines(
            bufnr,
            line,
            line + 1,
            false
        )[1] or ""
        local new_line = current_line:sub(1, col)
            .. string.format(IMAGE_INDICATOR_FORMAT, #self._images)
            .. current_line:sub(col + 1)

        vim.api.nvim_buf_set_lines(bufnr, line, line + 1, false, { new_line })
    end)
end

--- Get all images
--- @return agentic.ui.ImageData[]
function ImageManager:get_images()
    return self._images
end

--- Clear all images
function ImageManager:clear()
    self._images = {}

    if self._on_change then
        self._on_change(self)
    end
end

--- Check if there are any images
--- @return boolean
function ImageManager:is_empty()
    return #self._images == 0
end

--- Setup keybindings for image paste
--- @param keymap_config? string|table The keymap configuration from Config.keymaps.prompt.paste_image
function ImageManager:_setup_keybindings(keymap_config)
    if not keymap_config then
        return
    end

    -- Normalize to array format
    local keymaps = keymap_config
    if type(keymaps) == "string" then
        keymaps = { keymaps }
    end

    -- Set up each keymap
    for _, keymap_entry in ipairs(keymaps) do
        local key, mode
        if type(keymap_entry) == "string" then
            key = keymap_entry
            mode = "n" -- default to normal mode
        else
            key = keymap_entry[1]
            mode = keymap_entry.mode or "n"
        end

        BufHelpers.keymap_set(self._bufnr, mode, key, function()
            self:paste_from_clipboard()
        end, {
            desc = "Paste image from clipboard",
        })
    end
end

return ImageManager
