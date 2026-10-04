--- @diagnostic disable: missing-fields
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.acp.AgentInstance", function()
    --- @type agentic.acp.AgentInstance
    local AgentInstance
    --- @type TestSpy
    local health_spy
    --- @type TestSpy
    local client_new_spy

    local health_results = {}
    local absent = {}
    local original_loaded = {}

    before_each(function()
        original_loaded = {
            ["agentic.acp.agent_instance"] = package.loaded["agentic.acp.agent_instance"]
                or absent,
            ["agentic.acp.acp_client"] = package.loaded["agentic.acp.acp_client"]
                or absent,
            ["agentic.acp.acp_health"] = package.loaded["agentic.acp.acp_health"]
                or absent,
            ["agentic.config"] = package.loaded["agentic.config"] or absent,
            ["agentic.utils.logger"] = package.loaded["agentic.utils.logger"]
                or absent,
        }

        package.loaded["agentic.config"] = {
            acp_providers = {
                ["codex-acp"] = {
                    name = "Available",
                    command = "available-command",
                },
                ["gemini-acp"] = {
                    name = "Unavailable",
                    command = "unavailable-command",
                },
            },
        }

        health_results = {
            ["codex-acp"] = true,
            ["gemini-acp"] = false,
            ["claude-acp"] = true,
        }
        health_spy = spy.new(function(provider_name)
            return health_results[provider_name] == true
        end)
        package.loaded["agentic.acp.acp_health"] = {
            check_configured_provider = health_spy,
        }

        client_new_spy = spy.new(function(_self, config, on_ready)
            local client = { provider_config = config }
            on_ready(client)
            return client
        end)
        package.loaded["agentic.acp.acp_client"] = {
            new = client_new_spy,
        }
        package.loaded["agentic.utils.logger"] = {
            debug = function() end,
        }
        package.loaded["agentic.acp.agent_instance"] = nil

        AgentInstance = require("agentic.acp.agent_instance")
    end)

    after_each(function()
        for module_name, module in pairs(original_loaded) do
            package.loaded[module_name] = module ~= absent and module or nil
        end
    end)

    it("rejects a healthy provider with no configuration", function()
        local client = AgentInstance.get_instance("claude-acp", function() end)

        assert.is_nil(client)
        assert.spy(health_spy).was.called_with("claude-acp")
        assert.spy(client_new_spy).was.called(0)
    end)

    it(
        "returns nil for an unavailable command without constructing a client",
        function()
            local client = AgentInstance.get_instance(
                "gemini-acp",
                function() end
            )

            assert.is_nil(client)
            assert.spy(health_spy).was.called_with("gemini-acp")
            assert.spy(client_new_spy).was.called(0)
        end
    )

    it("creates and caches one client for a valid provider", function()
        local on_ready = spy.new()

        local first = AgentInstance.get_instance(
            "codex-acp",
            on_ready --[[@as fun(client: agentic.acp.ACPClient)]]
        )
        local second = AgentInstance.get_instance(
            "codex-acp",
            on_ready --[[@as fun(client: agentic.acp.ACPClient)]]
        )

        assert.is_not_nil(first)
        assert.equal(first, second)
        assert.spy(client_new_spy).was.called(1)
        assert.spy(on_ready).was.called(2)
    end)

    it("returns a cached client without constructing another", function()
        local first = AgentInstance.get_instance("codex-acp", function() end)
        client_new_spy:reset()

        local second = AgentInstance.get_instance("codex-acp", function() end)

        assert.equal(first, second)
        assert.spy(client_new_spy).was.called(0)
        assert.spy(health_spy).was.called(1)
    end)

    it("uses a no-op readiness callback when none is supplied", function()
        local client

        assert.has_no_errors(function()
            client = AgentInstance.get_instance("codex-acp")
        end)

        assert.is_not_nil(client)
        assert.equal("function", type(client_new_spy.calls[1][3]))
    end)
end)
