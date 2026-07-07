--- @diagnostic disable: missing-fields, param-type-mismatch

local assert = require("tests.helpers.assert")

local SessionState = require("agentic.acp.session_state")

describe("agentic.acp.SessionState", function()
    --- Fake config_options whose id getters mimic the Task 1 accessors.
    --- @return table fake
    local function config_provider_fake()
        return {
            get_model_id = function()
                return "sonnet"
            end,
            get_mode_id = function()
                return "ask"
            end,
            get_mode_name = function(_, _id)
                return "Ask"
            end,
            model = {
                options = {
                    { value = "sonnet", name = "Sonnet" },
                },
            },
            thought_level = {
                currentValue = "high",
                options = {
                    { value = "high", name = "High" },
                },
            },
            legacy_agent_models = {
                get_model = function(_, _id)
                    return nil
                end,
            },
            legacy_agent_modes = {
                get_mode = function(_, _id)
                    return nil
                end,
            },
        }
    end

    --- Legacy provider: config name source absent, legacy holders supply names.
    --- @return table fake
    local function legacy_provider_fake()
        return {
            get_model_id = function()
                return "gpt"
            end,
            get_mode_id = function()
                return "plan"
            end,
            get_mode_name = function(_, _id)
                return "Plan"
            end,
            model = nil,
            thought_level = nil,
            legacy_agent_models = {
                get_model = function(_, _id)
                    return { modelId = "gpt", name = "GPT" }
                end,
            },
            legacy_agent_modes = {
                get_mode = function(_, _id)
                    return { id = "plan", name = "Plan" }
                end,
            },
        }
    end

    --- Real shape: legacy holders ALWAYS exist; all ids nil.
    --- @return table fake
    local function empty_fake()
        return {
            get_model_id = function()
                return nil
            end,
            get_mode_id = function()
                return nil
            end,
            get_mode_name = function(_, _id)
                return nil
            end,
            model = nil,
            mode = nil,
            thought_level = nil,
            legacy_agent_models = {
                get_model = function(_, _id)
                    return nil
                end,
            },
            legacy_agent_modes = {
                get_mode = function(_, _id)
                    return nil
                end,
            },
        }
    end

    describe("usage getters", function()
        it("are nil on a fresh instance", function()
            local state = SessionState:new(config_provider_fake(), "Claude")

            assert.is_nil(state:get_context_used())
            assert.is_nil(state:get_context_size())
            assert.is_nil(state:get_cost_amount())
            assert.is_nil(state:get_cost_currency())
        end)

        it("returns used/size after set_usage without cost", function()
            local state = SessionState:new(config_provider_fake(), "Claude")

            state:set_usage({ used = 1000, size = 200000 })

            assert.equal(state:get_context_used_raw(), 1000)
            assert.equal(state:get_context_size_raw(), 200000)
            assert.is_nil(state:get_cost_amount_raw())
            assert.is_nil(state:get_cost_currency())
        end)

        it("returns cost when the update includes it", function()
            local state = SessionState:new(config_provider_fake(), "Claude")

            state:set_usage({
                used = 10,
                size = 20,
                cost = { amount = 0.5, currency = "USD" },
            })

            assert.equal(state:get_cost_amount_raw(), 0.5)
            assert.equal(state:get_cost_currency(), "USD")
        end)

        it("stores zero used/size values", function()
            local state = SessionState:new(config_provider_fake(), "Claude")

            state:set_usage({ used = 0, size = 0 })

            assert.equal(state:get_context_used_raw(), 0)
            assert.equal(state:get_context_size_raw(), 0)
        end)

        it("overwrites used/size on a later set_usage", function()
            local state = SessionState:new(config_provider_fake(), "Claude")

            state:set_usage({ used = 1, size = 2 })
            state:set_usage({ used = 5, size = 6 })

            assert.equal(state:get_context_used_raw(), 5)
            assert.equal(state:get_context_size_raw(), 6)
        end)

        it("preserves prior cost when a later update omits cost", function()
            local state = SessionState:new(config_provider_fake(), "Claude")

            state:set_usage({
                used = 1,
                size = 2,
                cost = { amount = 9, currency = "EUR" },
            })
            state:set_usage({ used = 5, size = 6 })

            assert.equal(state:get_cost_amount_raw(), 9)
            assert.equal(state:get_cost_currency(), "EUR")
        end)

        it("preserves prior cost when a later cost has no amount", function()
            local state = SessionState:new(config_provider_fake(), "Claude")

            state:set_usage({
                used = 1,
                size = 2,
                cost = { amount = 9, currency = "EUR" },
            })
            state:set_usage({ used = 5, size = 6, cost = { currency = "USD" } })

            assert.equal(state:get_cost_amount_raw(), 9)
            assert.equal(state:get_cost_currency(), "EUR")
        end)
    end)

    describe("human-readable usage getters", function()
        --- @param usage table
        --- @return agentic.acp.SessionState
        local function state_with(usage)
            local state = SessionState:new(config_provider_fake(), "Claude")
            state:set_usage(usage)

            return state
        end

        it("returns nil on a fresh instance", function()
            local state = SessionState:new(config_provider_fake(), "Claude")

            assert.is_nil(state:get_context_used())
            assert.is_nil(state:get_context_size())
            assert.is_nil(state:get_cost_amount())
        end)

        it("formats sub-thousand counts as plain numbers", function()
            local state = state_with({ used = 0, size = 999 })

            assert.equal(state:get_context_used(), "0")
            assert.equal(state:get_context_size(), "999")
        end)

        it("formats thousands with a K suffix, ceil to 1 decimal", function()
            local state = state_with({ used = 1000, size = 27649 })

            assert.equal(state:get_context_used(), "1K")
            assert.equal(state:get_context_size(), "27.7K")
        end)

        it("formats millions with an M suffix, ceil to 1 decimal", function()
            local state = state_with({ used = 1000000, size = 1550000 })

            assert.equal(state:get_context_used(), "1M")
            assert.equal(state:get_context_size(), "1.6M")
        end)

        it("crosses to M when K rounding hits 1000, not 1000K", function()
            local state = state_with({ used = 999999, size = 999500 })

            assert.equal(state:get_context_used(), "1M")
            assert.equal(state:get_context_size(), "999.5K")
        end)

        it("formats cost as a 2-decimal string, ceil to cents", function()
            local state = state_with({
                used = 1,
                size = 2,
                cost = { amount = 0.004, currency = "USD" },
            })

            assert.equal(state:get_cost_amount(), "0.01")
        end)
    end)

    describe("clear", function()
        it("resets usage but keeps provider_name", function()
            local state = SessionState:new(config_provider_fake(), "Claude")

            state:set_usage({
                used = 1,
                size = 2,
                cost = { amount = 3, currency = "USD" },
            })
            state:clear()

            assert.is_nil(state:get_context_used())
            assert.is_nil(state:get_context_size())
            assert.is_nil(state:get_cost_amount())
            assert.is_nil(state:get_cost_currency())
            assert.equal(state:get_provider_name(), "Claude")
        end)
    end)

    describe("provider name", function()
        it("returns the name passed to new", function()
            local state = SessionState:new(config_provider_fake(), "Claude")

            assert.equal(state:get_provider_name(), "Claude")
        end)
    end)

    describe("config-provider delegation", function()
        it("delegates ids and resolves names from config options", function()
            local state = SessionState:new(config_provider_fake(), "Claude")

            assert.equal(state:get_model_id(), "sonnet")
            assert.equal(state:get_model_name(), "Sonnet")
            assert.equal(state:get_mode_id(), "ask")
            assert.equal(state:get_mode_name(), "Ask")
            assert.equal(state:get_thought_level_id(), "high")
            assert.equal(state:get_thought_level_name(), "High")
        end)
    end)

    describe("legacy-provider delegation", function()
        it("resolves model name via the legacy scan branch", function()
            local state = SessionState:new(legacy_provider_fake(), "Codex")

            assert.equal(state:get_model_id(), "gpt")
            assert.equal(state:get_model_name(), "GPT")
            assert.equal(state:get_mode_id(), "plan")
            assert.equal(state:get_mode_name(), "Plan")
        end)

        it("has nil thought level (no legacy path)", function()
            local state = SessionState:new(legacy_provider_fake(), "Codex")

            assert.is_nil(state:get_thought_level_id())
            assert.is_nil(state:get_thought_level_name())
        end)
    end)

    describe("missing config and legacy", function()
        it("returns nil for every getter without crashing", function()
            local state = SessionState:new(empty_fake(), "None")

            assert.is_nil(state:get_model_id())
            assert.is_nil(state:get_model_name())
            assert.is_nil(state:get_mode_id())
            assert.is_nil(state:get_mode_name())
            assert.is_nil(state:get_thought_level_id())
            assert.is_nil(state:get_thought_level_name())
        end)
    end)
end)
