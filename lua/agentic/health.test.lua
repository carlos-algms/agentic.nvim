local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("Health", function()
    --- @type agentic.Health
    local Health

    --- @type TestStub
    local start_stub
    --- @type TestStub
    local ok_stub
    --- @type TestStub
    local warn_stub
    --- @type TestStub
    local error_stub
    --- @type TestStub
    local info_stub
    --- @type TestStub
    local executable_stub

    local original_acp_health
    local original_config
    local original_clipboard_image

    before_each(function()
        package.loaded["agentic.health"] = nil
        original_acp_health = package.loaded["agentic.acp.acp_health"]
        original_config = package.loaded["agentic.config"]
        original_clipboard_image = package.loaded["agentic.ui.clipboard_image"]

        package.loaded["agentic.acp.acp_health"] = {
            is_command_available = function()
                return true
            end,
            is_node_installed = function()
                return true
            end,
        }
        package.loaded["agentic.config"] = {
            provider = "codex",
            acp_providers = {
                codex = {
                    name = "Codex",
                    command = "codex",
                },
            },
        }
        package.loaded["agentic.ui.clipboard_image"] = {
            get_platform = function()
                return "wsl"
            end,
            is_supported = function()
                return false
            end,
        }

        start_stub = spy.stub(vim.health, "start")
        ok_stub = spy.stub(vim.health, "ok")
        warn_stub = spy.stub(vim.health, "warn")
        error_stub = spy.stub(vim.health, "error")
        info_stub = spy.stub(vim.health, "info")
        executable_stub = spy.stub(vim.fn, "executable")

        Health = require("agentic.health")
    end)

    after_each(function()
        start_stub:revert()
        ok_stub:revert()
        warn_stub:revert()
        error_stub:revert()
        info_stub:revert()
        executable_stub:revert()

        package.loaded["agentic.health"] = nil
        package.loaded["agentic.acp.acp_health"] = original_acp_health
        package.loaded["agentic.config"] = original_config
        package.loaded["agentic.ui.clipboard_image"] = original_clipboard_image
    end)

    it("warns when WSL PowerShell interop is missing", function()
        executable_stub:invokes(function(name)
            return name == "wslpath" and 1 or 0
        end)

        Health.check()

        assert
            .spy(warn_stub).was
            .called_with(
                "Clipboard image paste: PowerShell interop (powershell.exe) not found"
            )
    end)

    it("warns when WSL wslpath is missing", function()
        executable_stub:invokes(function(name)
            return name == "powershell.exe" and 1 or 0
        end)

        Health.check()

        assert
            .spy(warn_stub).was
            .called_with("Clipboard image paste: wslpath not found")
    end)

    it("warns when both WSL requirements are missing", function()
        executable_stub:returns(0)

        Health.check()

        assert.spy(warn_stub).was.called_with(
            "Clipboard image paste: PowerShell interop (powershell.exe) and wslpath not found"
        )
    end)
end)
