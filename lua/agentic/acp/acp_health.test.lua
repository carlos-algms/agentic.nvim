--- @diagnostic disable: missing-fields
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.acp.ACPHealth", function()
    --- @type agentic.acp.ACPHealth
    local ACPHealth
    --- @type TestStub
    local executable_stub
    --- @type TestSpy
    local show_spy

    local absent = {}
    local original_loaded = {}

    before_each(function()
        original_loaded = {
            ["agentic.acp.acp_health"] = package.loaded["agentic.acp.acp_health"]
                or absent,
            ["agentic.config"] = package.loaded["agentic.config"] or absent,
            ["agentic.config_default"] = package.loaded["agentic.config_default"]
                or absent,
            ["agentic.ui.floating_message"] = package.loaded["agentic.ui.floating_message"]
                or absent,
        }

        package.loaded["agentic.config"] = {
            provider = "claude-acp",
            acp_providers = {
                ["claude-acp"] = {
                    name = "Default Provider",
                    command = "default-command",
                },
                ["codex-acp"] = {
                    name = "Explicit Provider",
                    command = "explicit-command",
                },
                ["gemini-acp"] = {
                    name = "Unavailable Provider",
                    command = "unavailable-command",
                },
            },
        }
        package.loaded["agentic.config_default"] = {
            acp_providers = {
                ["claude-acp"] = {},
                ["codex-acp"] = {},
                ["gemini-acp"] = {},
            },
        }
        show_spy = spy.new()
        package.loaded["agentic.ui.floating_message"] = {
            show = show_spy,
        }
        package.loaded["agentic.acp.acp_health"] = nil

        ACPHealth = require("agentic.acp.acp_health")
        executable_stub = spy.stub(vim.fn, "executable")
    end)

    after_each(function()
        executable_stub:revert()
        for module_name, module in pairs(original_loaded) do
            package.loaded[module_name] = module ~= absent and module or nil
        end
    end)

    it("checks the configured provider by default", function()
        executable_stub:invokes(function(command)
            return command == "default-command" and 1 or 0
        end)

        assert.is_true(ACPHealth.check_configured_provider())
        assert.stub(executable_stub).was.called_with("default-command")
        assert.spy(show_spy).was.called(0)
    end)

    it(
        "checks an explicit provider instead of the configured default",
        function()
            executable_stub:invokes(function(command)
                return command == "explicit-command" and 1 or 0
            end)

            assert.is_true(ACPHealth.check_configured_provider("codex-acp"))
            assert.stub(executable_stub).was.called_with("explicit-command")
            assert.spy(show_spy).was.called(0)
        end
    )

    it("shows the existing warning for an explicit missing provider", function()
        executable_stub:returns(0)

        assert.is_false(ACPHealth.check_configured_provider("opencode-acp"))
        assert.spy(show_spy).was.called(1)

        local opts = show_spy.calls[1][1]
        assert.equal(" Agentic.nvim - Warning ", opts.title)
        assert.is_true(
            vim.tbl_contains(
                opts.body,
                "‼️ Provider **opencode-acp** not found in configuration."
            )
        )
    end)

    it(
        "shows the existing warning for an unavailable explicit command",
        function()
            executable_stub:returns(0)

            assert.is_false(ACPHealth.check_configured_provider("gemini-acp"))
            assert.spy(show_spy).was.called(1)

            local opts = show_spy.calls[1][1]
            assert.equal(" Agentic.nvim - Warning ", opts.title)
            assert.is_true(
                vim.tbl_contains(
                    opts.body,
                    "‼️ **Unavailable Provider** (command: `unavailable-command`) is not installed or not executable."
                )
            )
        end
    )
end)
