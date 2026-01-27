--- @class agentic.utils.object
local M = {}

function M.deep_merge_into(target, ...)
    for _, source in ipairs({ ... }) do
        for k, v in pairs(source) do
            if type(v) == "table" and type(target[k]) == "table" then
                M.deep_merge_into(target[k], v)
            else
                target[k] = v
            end
        end
    end
    return target
end

--- @param config agentic.UserConfig
--- @param default_config agentic.UserConfig
--- @return agentic.UserConfig
function M.merge_config(config, default_config)
    local user_keys = config and config.keymaps or {}
    local default_keys = default_config and default_config.keymaps or {}

    local merged =
        M.deep_merge_into(vim.deepcopy(default_config or {}), config or {})

    merged.keymaps = vim.tbl_deep_extend("force", default_keys, user_keys)

    return merged
end

return M
