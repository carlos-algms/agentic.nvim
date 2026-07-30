--- @diagnostic disable: missing-fields, assign-type-mismatch, return-type-mismatch

local assert = require("tests.helpers.assert")
local WidgetRegistry = require("agentic.ui.widget_registry")

describe("agentic.ui.WidgetRegistry", function()
    --- @type agentic.ui.ChatWidget[]
    local created

    --- Registry only reads `buf_nrs`.
    --- @param buf_nrs table<string, integer>
    --- @return agentic.ui.ChatWidget
    local function fake_widget(buf_nrs)
        local widget = { buf_nrs = buf_nrs }
        created[#created + 1] = widget
        return widget
    end

    before_each(function()
        created = {}
    end)

    after_each(function()
        -- Registry state is module-level.
        for _, widget in ipairs(created) do
            WidgetRegistry.unregister(widget)
        end
    end)

    it("maps every buffer of a registered widget to that widget", function()
        local widget = fake_widget({ chat = 11, input = 12 })

        WidgetRegistry.register(widget)

        assert.equal(WidgetRegistry.get(11), widget)
        assert.equal(WidgetRegistry.get(12), widget)
    end)

    it("returns nil for an unregistered bufnr", function()
        assert.is_nil(WidgetRegistry.get(9999))
    end)

    it("clears every mapped bufnr on unregister", function()
        local widget = fake_widget({ chat = 21, input = 22 })
        WidgetRegistry.register(widget)

        WidgetRegistry.unregister(widget)

        assert.is_nil(WidgetRegistry.get(21))
        assert.is_nil(WidgetRegistry.get(22))
    end)

    it("keeps two widgets' buffers distinct", function()
        local a = fake_widget({ chat = 31 })
        local b = fake_widget({ chat = 32 })

        WidgetRegistry.register(a)
        WidgetRegistry.register(b)

        assert.equal(WidgetRegistry.get(31), a)
        assert.equal(WidgetRegistry.get(32), b)
    end)

    it("unregisters a widget whose buf_nrs was already emptied", function()
        local widget = fake_widget({ chat = 41, input = 42 })
        WidgetRegistry.register(widget)

        -- `ChatWidget:destroy` unregisters before nil-ing `buf_nrs` entries;
        -- covers callers that empty `buf_nrs` first.
        widget.buf_nrs.chat = nil
        widget.buf_nrs.input = nil

        WidgetRegistry.unregister(widget)

        assert.is_nil(WidgetRegistry.get(41))
        assert.is_nil(WidgetRegistry.get(42))
    end)

    it("does not disturb other widgets when one unregisters", function()
        local a = fake_widget({ chat = 51 })
        local b = fake_widget({ chat = 52 })
        WidgetRegistry.register(a)
        WidgetRegistry.register(b)

        WidgetRegistry.unregister(a)

        assert.is_nil(WidgetRegistry.get(51))
        assert.equal(WidgetRegistry.get(52), b)
    end)

    it("drops stale entries when a widget re-registers", function()
        local widget = fake_widget({ chat = 61 })
        WidgetRegistry.register(widget)

        -- Repurposed panel buffer, then re-register.
        widget.buf_nrs.chat = 62
        WidgetRegistry.register(widget)

        assert.is_nil(WidgetRegistry.get(61))
        assert.equal(WidgetRegistry.get(62), widget)
    end)

    it("reports every registered bufnr as a set", function()
        local a = fake_widget({ chat = 71, input = 72 })
        local b = fake_widget({ chat = 73 })
        WidgetRegistry.register(a)
        WidgetRegistry.register(b)

        local bufnrs = WidgetRegistry.all_bufnrs()

        assert.is_true(bufnrs[71])
        assert.is_true(bufnrs[72])
        assert.is_true(bufnrs[73])
        assert.is_nil(bufnrs[74])
    end)

    it("omits unregistered bufnrs from all_bufnrs", function()
        local widget = fake_widget({ chat = 81 })
        WidgetRegistry.register(widget)

        WidgetRegistry.unregister(widget)

        assert.is_nil(WidgetRegistry.all_bufnrs()[81])
    end)
end)
