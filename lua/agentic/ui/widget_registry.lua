--- Not per-session state: buffer numbers are global in Neovim.
--- @class agentic.ui.WidgetRegistry
local WidgetRegistry = {}

--- @type table<integer, agentic.ui.ChatWidget>
local widgets_by_bufnr = {}

--- Scans by value, so it still cleans up after `buf_nrs` was emptied.
--- @param widget agentic.ui.ChatWidget
function WidgetRegistry.unregister(widget)
    for bufnr, owner in pairs(widgets_by_bufnr) do
        if owner == widget then
            widgets_by_bufnr[bufnr] = nil
        end
    end
end

--- Prunes first, so a swapped-out panel buffer leaves no stale owner.
--- @param widget agentic.ui.ChatWidget
function WidgetRegistry.register(widget)
    WidgetRegistry.unregister(widget)

    for _, bufnr in pairs(widget.buf_nrs) do
        widgets_by_bufnr[bufnr] = widget
    end
end

--- @param bufnr integer
--- @return agentic.ui.ChatWidget|nil
function WidgetRegistry.get(bufnr)
    return widgets_by_bufnr[bufnr]
end

--- @return table<integer, true>
function WidgetRegistry.all_bufnrs()
    --- @type table<integer, true>
    local bufnrs = {}

    for bufnr in pairs(widgets_by_bufnr) do
        bufnrs[bufnr] = true
    end

    return bufnrs
end

return WidgetRegistry
