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
    return "unknown"
end

--- Check whether the host platform's clipboard tools are reachable.
--- @return boolean supported
function M.is_supported()
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
