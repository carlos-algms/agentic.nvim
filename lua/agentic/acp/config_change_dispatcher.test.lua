local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Logger = require("agentic.utils.logger")
local ConfigChangeDispatcher = require("agentic.acp.config_change_dispatcher")

describe("agentic.acp.ConfigChangeDispatcher", function()
    --- @type TestStub
    local notify_stub
    --- @type TestStub
    local debug_stub

    before_each(function()
        notify_stub = spy.stub(Logger, "notify")
        debug_stub = spy.stub(Logger, "debug")
    end)

    after_each(function()
        notify_stub:revert()
        debug_stub:revert()
    end)

    --- Build a get_session_id resolver reading `ref.id` live.
    --- @param ref { id: string|nil }
    local function get_session_id_for(ref)
        return function()
            return ref.id
        end
    end

    it("forwards a fresh, error-free response to on_success", function()
        local ref = { id = "s1" }
        local on_success = spy.new(function() end)
        local result = { configOptions = {} }

        ConfigChangeDispatcher.dispatch({
            get_session_id = get_session_id_for(ref),
            value = "code",
            label = "mode",
            send = function(callback)
                callback(result, nil)
            end,
            on_success = on_success --[[@as function]],
        })

        assert.spy(on_success).was.called(1)
        assert.equal(result, on_success.calls[1][1])
        assert.spy(notify_stub).was.called(0)
    end)

    it("drops a response when the session changed mid-flight", function()
        local ref = { id = "s1" }
        local on_success = spy.new(function() end)

        ConfigChangeDispatcher.dispatch({
            get_session_id = get_session_id_for(ref),
            value = "code",
            label = "mode",
            send = function(callback)
                ref.id = "s2" -- session swapped before the response lands
                callback({}, nil)
            end,
            on_success = on_success --[[@as function]],
        })

        assert.spy(on_success).was.called(0)
        assert.spy(notify_stub).was.called(0)
        assert.spy(debug_stub).was.called(1)
    end)

    it("notifies at ERROR level and skips on_success on error", function()
        local ref = { id = "s1" }
        local on_success = spy.new(function() end)

        ConfigChangeDispatcher.dispatch({
            get_session_id = get_session_id_for(ref),
            value = "opus",
            label = "model",
            send = function(callback)
                callback(nil, { message = "boom" } --[[@as any]])
            end,
            on_success = on_success --[[@as function]],
        })

        assert.spy(on_success).was.called(0)
        assert.spy(notify_stub).was.called(1)
        assert.equal(vim.log.levels.ERROR, notify_stub.calls[1][2])
        local msg = notify_stub.calls[1][1]
        assert.is_not_nil(msg:find("model", 1, true))
        assert.is_not_nil(msg:find("opus", 1, true))
        assert.is_not_nil(msg:find("boom", 1, true))
    end)

    it("captures the session id at dispatch time, not at send time", function()
        local ref = { id = "s1" }
        local on_success = spy.new(function() end)

        -- Same id at dispatch and at response → fresh, even though we never
        -- changed it: proves the captured baseline is "s1".
        ConfigChangeDispatcher.dispatch({
            get_session_id = get_session_id_for(ref),
            value = "low",
            label = "thought effort level",
            send = function(callback)
                callback({}, nil)
            end,
            on_success = on_success --[[@as function]],
        })

        assert.spy(on_success).was.called(1)
    end)
end)
