--- Platform-aware clipboard image probe and save.
--- macOS uses osascript, Windows/WSL uses powershell.exe, Linux uses
--- wl-paste (Wayland) or xclip (X11). No external Neovim plugin
--- dependencies.
--- @class agentic.ui.ClipboardImage
local M = {}

--- @alias agentic.ui.ClipboardImage.Platform
--- | "mac"
--- | "win"
--- | "linux_wayland"
--- | "linux_x11"
--- | "unknown"

--- Run a shell command and return success flag + stdout.
--- Tests stub this directly to avoid mutating the read-only
--- `vim.v.shell_error`. Routes every system call through one boundary.
--- @param cmd string|string[]
--- @return boolean ok
--- @return string stdout
function M._run(cmd)
    local stdout = vim.fn.system(cmd)
    local ok = vim.v.shell_error == 0
    return ok, stdout
end

--- Detect the host platform for clipboard image operations.
--- @return agentic.ui.ClipboardImage.Platform platform
function M.get_platform()
    if vim.fn.has("mac") == 1 then
        return "mac"
    end

    if vim.fn.has("win32") == 1 then
        return "win"
    end

    if vim.fn.has("wsl") == 1 and vim.fn.executable("powershell.exe") == 1 then
        return "win"
    end

    if vim.fn.has("linux") == 1 or vim.fn.has("wsl") == 1 then
        local wayland = vim.env.WAYLAND_DISPLAY
        if wayland and wayland ~= "" then
            return "linux_wayland"
        end
        return "linux_x11"
    end

    return "unknown"
end

--- Check whether the host platform's clipboard tools are reachable.
--- @return boolean supported
function M.is_supported()
    local platform = M.get_platform()

    if platform == "mac" then
        return true
    end

    if platform == "win" then
        return vim.fn.executable("powershell.exe") == 1
    end

    if platform == "linux_wayland" then
        return vim.fn.executable("wl-paste") == 1
    end

    if platform == "linux_x11" then
        return vim.fn.executable("xclip") == 1
    end

    return false
end

--- Check whether the system clipboard currently contains a PNG image.
--- @return boolean has_image
function M.has_image()
    return false
end

--- Save the clipboard PNG image to the given path.
--- @param path string
--- @return boolean ok
--- @return string|nil err
function M.save(path)
    local _ = path
    return false, "not implemented"
end

return M
