--- Platform-aware clipboard image probe and save.
--- macOS uses osascript, Windows/WSL uses powershell.exe, Linux uses
--- wl-paste (Wayland) or xclip (X11). No external Neovim plugin
--- dependencies.
--- @class agentic.ui.ClipboardImage
local M = {}

--- @alias agentic.ui.ClipboardImage.Platform
--- | "mac"
--- | "win"
--- | "wsl"
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

    if vim.fn.has("wsl") == 1 then
        return "wsl"
    end

    if vim.fn.has("linux") == 1 then
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

    if platform == "wsl" then
        return vim.fn.executable("powershell.exe") == 1
            and vim.fn.executable("wslpath") == 1
    end

    if platform == "linux_wayland" then
        return vim.fn.executable("wl-paste") == 1
    end

    if platform == "linux_x11" then
        return vim.fn.executable("xclip") == 1
    end

    return false
end

local WIN_HAS_IMAGE_PS = table.concat({
    "Add-Type -AssemblyName System.Windows.Forms;",
    "if ([System.Windows.Forms.Clipboard]::ContainsImage()) { exit 0 }",
    "else { exit 1 }",
}, " ")

--- Check whether the system clipboard currently contains a PNG image.
--- @return boolean has_image
function M.has_image()
    local platform = M.get_platform()

    if platform == "mac" then
        local ok, stdout = M._run({ "osascript", "-e", "clipboard info" })
        return ok and stdout:find("«class PNGf»", 1, true) ~= nil
    end

    if platform == "win" or platform == "wsl" then
        local ok = M._run({
            "powershell.exe",
            "-NoProfile",
            "-Command",
            WIN_HAS_IMAGE_PS,
        })
        return ok
    end

    if platform == "linux_wayland" then
        local ok, stdout = M._run({ "wl-paste", "--list-types" })
        return ok and stdout:find("image/png", 1, true) ~= nil
    end

    if platform == "linux_x11" then
        local ok, stdout = M._run({
            "xclip",
            "-selection",
            "clipboard",
            "-t",
            "TARGETS",
            "-o",
        })
        return ok and stdout:find("image/png", 1, true) ~= nil
    end

    return false
end

local MAC_SAVE_SCRIPT_TEMPLATE = table.concat({
    "set png to the clipboard as «class PNGf»",
    'set f to open for access POSIX file "%s" with write permission',
    "set eof of f to 0",
    "write png to f",
    "close access f",
}, "\n")

local WIN_SAVE_PS_TEMPLATE = table.concat({
    "Add-Type -AssemblyName System.Windows.Forms;",
    "Add-Type -AssemblyName System.Drawing;",
    "$img = [System.Windows.Forms.Clipboard]::GetImage();",
    "if ($img) {",
    "  $img.Save('%s', [System.Drawing.Imaging.ImageFormat]::Png);",
    "  exit 0",
    "} else { exit 1 }",
}, " ")

--- @param path string
--- @return string|nil win_path
--- @return string|nil err
local function to_wsl_windows_path(path)
    local ok, stdout = M._run({ "wslpath", "-w", path })
    if not ok then
        return nil, stdout ~= "" and stdout or "wslpath failed"
    end

    local win_path = stdout:gsub("[\r\n]+$", "")
    if win_path == "" then
        return nil, "wslpath produced empty path"
    end

    return win_path, nil
end

--- Save the clipboard PNG image to the given path.
--- @param path string
--- @return boolean ok
--- @return string|nil err
function M.save(path)
    local platform = M.get_platform()

    if platform == "unknown" then
        return false, "unsupported platform"
    end

    local ok, stdout
    if platform == "mac" then
        local script = string.format(MAC_SAVE_SCRIPT_TEMPLATE, path)
        ok, stdout = M._run({ "osascript", "-e", script })
    elseif platform == "win" or platform == "wsl" then
        local save_path = path
        if platform == "wsl" then
            local win_path, convert_err = to_wsl_windows_path(path)
            if not win_path then
                return false, convert_err
            end
            save_path = win_path
        end

        local ps_path = save_path:gsub("'", "''")
        local ps = string.format(WIN_SAVE_PS_TEMPLATE, ps_path)
        ok, stdout = M._run({
            "powershell.exe",
            "-NoProfile",
            "-Command",
            ps,
        })
    elseif platform == "linux_wayland" then
        ok, stdout =
            M._run("wl-paste --type image/png > " .. vim.fn.shellescape(path))
    elseif platform == "linux_x11" then
        ok, stdout = M._run(
            "xclip -selection clipboard -t image/png -o > "
                .. vim.fn.shellescape(path)
        )
    end

    if not ok then
        return false, stdout ~= "" and stdout or "save failed"
    end

    local stat = vim.uv.fs_stat(path)
    if not stat or stat.size == 0 then
        return false, "clipboard write produced empty file"
    end

    return true, nil
end

return M
