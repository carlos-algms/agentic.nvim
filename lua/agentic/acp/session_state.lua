--- Live, read-through facade over the per-tab session state.
---
--- Delegates model/mode id reads to `AgentConfigOptions` (single source of the
--- config→legacy resolution) and resolves names locally. Owns ONLY the token
--- usage fed from the ACP `usage_update` session update. Every getter is
--- nil-able by contract; consumers MUST nil-check (usage stays nil until the
--- first `usage_update`, and after a session restore).
---
--- @class agentic.acp.SessionState
--- @field _config_options agentic.acp.AgentConfigOptions
--- @field _provider_name? string
--- @field _usage? { used?: number, size?: number, cost?: { amount: number, currency: string } }
local SessionState = {}
SessionState.__index = SessionState

--- ceil to 1 decimal: 27649 -> "27.7K", 1000000 -> "1M"
--- @return string
local function to_human(n)
    n = n or 0
    if n >= 1000000 then
        return string.format("%gM", math.ceil(n / 100000) / 10)
    elseif n >= 1000 then
        local k = math.ceil(n / 100) / 10
        if k >= 1000 then
            return string.format("%gM", math.ceil(n / 100000) / 10)
        end
        return string.format("%gK", k)
    end
    return tostring(n)
end

--- ceil to 2 decimals: 0.004 -> 0.01
--- @return string
local function to_formatted_cost(n)
    return string.format("%.2f", math.ceil((n or 0) * 100) / 100)
end

--- @param config_options agentic.acp.AgentConfigOptions
--- @param provider_name string|nil
--- @return agentic.acp.SessionState
function SessionState:new(config_options, provider_name)
    self = setmetatable({
        _config_options = config_options,
        _provider_name = provider_name,
        _usage = nil,
    }, self)

    return self
end

--- @return string|nil model_id
function SessionState:get_model_id()
    return self._config_options:get_model_id()
end

--- @return string|nil model_name
function SessionState:get_model_name()
    local id = self:get_model_id()

    if not id then
        return nil
    end

    local co = self._config_options

    if co.model then
        for _, option in ipairs(co.model.options or {}) do
            if option.value == id then
                return option.name
            end
        end

        return nil
    end

    local legacy = co.legacy_agent_models:get_model(id)

    return legacy and legacy.name
end

--- @return string|nil mode_id
function SessionState:get_mode_id()
    return self._config_options:get_mode_id()
end

--- @return string|nil mode_name
function SessionState:get_mode_name()
    local id = self:get_mode_id()

    if not id then
        return nil
    end

    return self._config_options:get_mode_name(id)
end

--- @return string|nil thought_level_id
function SessionState:get_thought_level_id()
    local thought_level = self._config_options.thought_level

    return thought_level and thought_level.currentValue
end

--- @return string|nil thought_level_name
function SessionState:get_thought_level_name()
    local thought_level = self._config_options.thought_level

    if not thought_level then
        return nil
    end

    local id = self:get_thought_level_id()

    for _, option in ipairs(thought_level.options or {}) do
        if option.value == id then
            return option.name
        end
    end

    return nil
end

--- @return number|nil context_used Tokens currently in context
function SessionState:get_context_used_raw()
    return self._usage and self._usage.used
end

--- Human-readable `get_context_used_raw`: 27649 -> "27.7K"
--- @return string|nil context_used
function SessionState:get_context_used()
    local used = self:get_context_used_raw()

    return used and to_human(used)
end

--- @return number|nil context_size Total context window size in tokens
function SessionState:get_context_size_raw()
    return self._usage and self._usage.size
end

--- Human-readable `get_context_size_raw`: 1000000 -> "1M"
--- @return string|nil context_size
function SessionState:get_context_size()
    local size = self:get_context_size_raw()

    return size and to_human(size)
end

--- @return number|nil cost_amount Cumulative session cost amount
function SessionState:get_cost_amount_raw()
    return self._usage and self._usage.cost and self._usage.cost.amount
end

--- Human-readable `get_cost_amount_raw`: 0.004 -> "0.01"
--- @return string|nil cost_amount
function SessionState:get_cost_amount()
    local amount = self:get_cost_amount_raw()

    return amount and to_formatted_cost(amount)
end

--- @return string|nil cost_currency Cumulative session cost currency
function SessionState:get_cost_currency()
    return self._usage and self._usage.cost and self._usage.cost.currency
end

--- @return string|nil provider_name
function SessionState:get_provider_name()
    return self._provider_name
end

--- Merges new-over-existing so a partial `usage_update` (Claude streams
--- cost-less updates before the cost-bearing one) does not wipe known values.
--- Absent/null `used`/`size`/`cost` keys survive; a malformed cost object
--- without a numeric `amount` is rejected rather than overwriting a good cost.
--- @param update agentic.acp.UsageUpdate
function SessionState:set_usage(update)
    local fields = { used = update.used, size = update.size }

    if
        type(update.cost) == "table"
        and type(update.cost.amount) == "number"
    then
        fields.cost = update.cost
    end

    self._usage = vim.tbl_extend("force", self._usage or {}, fields)
end

function SessionState:clear()
    self._usage = nil
end

return SessionState
