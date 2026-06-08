local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("Clipboard", function()
    --- @type agentic.Clipboard
    local Clipboard
    --- @type TestSpy
    local show_spy

    local original_clipboard_image
    local original_floating_message

    before_each(function()
        package.loaded["agentic.ui.clipboard"] = nil
        original_clipboard_image = package.loaded["agentic.ui.clipboard_image"]
        original_floating_message =
            package.loaded["agentic.ui.floating_message"]
        show_spy = spy.new()

        package.loaded["agentic.ui.floating_message"] = {
            show = show_spy,
        }
    end)

    after_each(function()
        package.loaded["agentic.ui.clipboard"] = nil
        package.loaded["agentic.ui.clipboard_image"] = original_clipboard_image
        package.loaded["agentic.ui.floating_message"] =
            original_floating_message
    end)

    --- @param platform string
    local function load_with_platform(platform)
        package.loaded["agentic.ui.clipboard_image"] = {
            get_platform = function()
                return platform
            end,
        }
        Clipboard = require("agentic.ui.clipboard")
    end

    it(
        "shows Windows PowerShell guidance when Windows support is missing",
        function()
            load_with_platform("win")

            Clipboard.show_clipboard_tool_missing_message()

            local opts = show_spy.calls[1][1]
            assert.is_true(
                vim.tbl_contains(
                    opts.body,
                    "Ensure `powershell.exe` is available in PATH."
                )
            )
        end
    )

    it("shows WSL interop guidance when WSL support is missing", function()
        load_with_platform("wsl")

        Clipboard.show_clipboard_tool_missing_message()

        local opts = show_spy.calls[1][1]
        assert.is_true(
            vim.tbl_contains(
                opts.body,
                "Ensure Windows interop is enabled and `powershell.exe` and `wslpath` are available."
            )
        )
    end)
end)
