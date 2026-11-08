local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local Hooks = require("agentic.utils.hooks")

describe("agentic.utils.Hooks", function()
    --- @type TestStub
    local schedule_stub
    --- @type TestStub|nil
    local notify_stub

    before_each(function()
        -- Run the scheduled callback synchronously so assertions see its effect.
        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(fn)
            fn()
        end)
    end)

    after_each(function()
        schedule_stub:revert()
        if notify_stub then
            notify_stub:revert()
            notify_stub = nil
        end
        Config.hooks = Config.hooks or {}
        Config.hooks.on_prompt_submit = nil
        Config.hooks.before_first_prompt = nil
    end)

    it("invokes the configured hook with the data", function()
        local hook_spy = spy.new(function() end)
        Config.hooks = Config.hooks or {}
        Config.hooks.on_prompt_submit = function(data)
            hook_spy(data)
        end

        local payload = { prompt = "hi" }
        Hooks.invoke("on_prompt_submit", payload --[[@as any]])

        assert.spy(hook_spy).was.called(1)
        assert.equal(payload, hook_spy.calls[1][1])
    end)

    it("is a no-op when no hook is configured", function()
        Config.hooks = Config.hooks or {}
        Config.hooks.on_prompt_submit = nil

        assert.has_no_errors(function()
            Hooks.invoke("on_prompt_submit", {} --[[@as any]])
        end)
        assert.spy(schedule_stub).was.called(0)
    end)

    it("is a no-op when the hook is not a function", function()
        Config.hooks = Config.hooks or {}
        --- @diagnostic disable-next-line: assign-type-mismatch
        Config.hooks.on_prompt_submit = "not a function"

        assert.has_no_errors(function()
            Hooks.invoke("on_prompt_submit", {} --[[@as any]])
        end)
        assert.spy(schedule_stub).was.called(0)
    end)

    it("swallows hook errors and notifies them at ERROR level", function()
        notify_stub = spy.stub(Logger, "notify")
        Config.hooks = Config.hooks or {}
        Config.hooks.on_prompt_submit = function()
            error("boom")
        end

        assert.has_no_errors(function()
            Hooks.invoke("on_prompt_submit", {} --[[@as any]])
        end)
        assert.spy(notify_stub).was.called(1)
        assert.equal(vim.log.levels.ERROR, notify_stub.calls[1][2])
    end)

    describe("invoke_sync", function()
        --- @return agentic.UserConfig.BeforeFirstPromptData
        local function payload()
            --- @type agentic.UserConfig.BeforeFirstPromptData
            local data = {
                session_id = "session-1",
                session_key = 7,
                provider_name = "TestProvider",
            }
            return data
        end

        it(
            "returns the hook value with the payload, without scheduling",
            function()
                Config.hooks = Config.hooks or {}
                local hook_spy = spy.new(function()
                    return "extra"
                end)
                Config.hooks.before_first_prompt = function(data)
                    return hook_spy(data)
                end

                local data = payload()
                local result = Hooks.invoke_sync("before_first_prompt", data)

                assert.equal("extra", result)
                assert.spy(hook_spy).was.called(1)
                assert.equal(data, hook_spy.calls[1][1])
                assert.spy(schedule_stub).was.called(0)
            end
        )

        it(
            "returns nil without notifying when no hook is configured",
            function()
                notify_stub = spy.stub(Logger, "notify")
                Config.hooks = Config.hooks or {}
                Config.hooks.before_first_prompt = nil

                assert.is_nil(
                    Hooks.invoke_sync("before_first_prompt", payload())
                )
                assert.spy(notify_stub).was.called(0)
            end
        )

        it(
            "returns nil without notifying when the hook is not a function",
            function()
                notify_stub = spy.stub(Logger, "notify")
                Config.hooks = Config.hooks or {}
                --- @diagnostic disable-next-line: assign-type-mismatch
                Config.hooks.before_first_prompt = "not a function"

                assert.is_nil(
                    Hooks.invoke_sync("before_first_prompt", payload())
                )
                assert.spy(notify_stub).was.called(0)
            end
        )

        it("returns nil and notifies at ERROR when the hook throws", function()
            notify_stub = spy.stub(Logger, "notify")
            Config.hooks = Config.hooks or {}
            Config.hooks.before_first_prompt = function()
                error("boom")
            end

            assert.is_nil(Hooks.invoke_sync("before_first_prompt", payload()))
            assert.spy(notify_stub).was.called(1)
            assert.equal(vim.log.levels.ERROR, notify_stub.calls[1][2])
        end)

        it(
            "returns nil and notifies at WARN when the value is not a string",
            function()
                notify_stub = spy.stub(Logger, "notify")
                Config.hooks = Config.hooks or {}
                --- @type fun(): any
                local returns_integer = function()
                    return 42
                end
                Config.hooks.before_first_prompt = returns_integer

                assert.is_nil(
                    Hooks.invoke_sync("before_first_prompt", payload())
                )
                assert.spy(notify_stub).was.called(1)
                assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])
            end
        )
    end)
end)
