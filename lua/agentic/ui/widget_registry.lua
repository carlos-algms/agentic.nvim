-- lua/agentic/ui/widget_registry.lua

--- Module-level map from widget buffer number to its owning widget.
--- Buffer numbers are global in Neovim, so module-level state is correct here:
--- there is no per-tab data involved.
--- @class agentic.ui.WidgetRegistry
local WidgetRegistry = {}

--- @type table<integer, agentic.ui.ChatWidget>
local widgets_by_bufnr = {}

--- Removes every entry pointing at the widget, so a destroyed widget leaves
--- nothing behind even when its `buf_nrs` was already emptied.
--- @param widget agentic.ui.ChatWidget
function WidgetRegistry.unregister(widget)
    for bufnr, owner in pairs(widgets_by_bufnr) do
        if owner == widget then
            widgets_by_bufnr[bufnr] = nil
        end
    end
end

--- Maps every buffer the widget currently owns to it. Re-registering prunes
--- first, so a swapped-out panel buffer cannot leave a stale owner behind.
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
