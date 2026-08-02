--- @diagnostic disable: assign-type-mismatch, missing-fields, return-type-mismatch

local assert = require("tests.helpers.assert")
local WidgetRegistry = require("agentic.ui.widget_registry")

describe("agentic.ui.WidgetRegistry", function()
    --- @type agentic.ui.ChatWidget[]
    local created

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
        for _, widget in ipairs(created) do
            WidgetRegistry.unregister(widget)
        end
    end)

    it("maps every current buffer to its widget", function()
        local widget = fake_widget({ chat = 11, input = 12 })

        WidgetRegistry.register(widget)

        assert.equal(widget, WidgetRegistry.get(11))
        assert.equal(widget, WidgetRegistry.get(12))
    end)

    it("returns nil for an unregistered buffer", function()
        assert.is_nil(WidgetRegistry.get(9999))
    end)

    it("removes stale mappings when a widget re-registers", function()
        local widget = fake_widget({ chat = 21, input = 22 })
        WidgetRegistry.register(widget)

        widget.buf_nrs.chat = 23
        WidgetRegistry.register(widget)

        assert.is_nil(WidgetRegistry.get(21))
        assert.equal(widget, WidgetRegistry.get(22))
        assert.equal(widget, WidgetRegistry.get(23))
    end)

    it("replaces only colliding ownership", function()
        local first = fake_widget({ chat = 31, input = 32 })
        local second = fake_widget({ chat = 31, input = 33 })
        WidgetRegistry.register(first)

        WidgetRegistry.register(second)

        assert.equal(second, WidgetRegistry.get(31))
        assert.equal(first, WidgetRegistry.get(32))
        assert.equal(second, WidgetRegistry.get(33))
    end)

    it("unregisters only mappings still owned by the widget", function()
        local first = fake_widget({ chat = 41, input = 42 })
        local second = fake_widget({ chat = 41 })
        WidgetRegistry.register(first)
        WidgetRegistry.register(second)

        WidgetRegistry.unregister(first)

        assert.equal(second, WidgetRegistry.get(41))
        assert.is_nil(WidgetRegistry.get(42))
    end)

    it("unregisters mappings after buf_nrs changes", function()
        local widget = fake_widget({ chat = 51, input = 52 })
        WidgetRegistry.register(widget)
        widget.buf_nrs = {}

        WidgetRegistry.unregister(widget)

        assert.is_nil(WidgetRegistry.get(51))
        assert.is_nil(WidgetRegistry.get(52))
    end)

    it("returns all registered buffer numbers as a set", function()
        local first = fake_widget({ chat = 61, input = 62 })
        local second = fake_widget({ chat = 63 })
        WidgetRegistry.register(first)
        WidgetRegistry.register(second)

        local registered = WidgetRegistry.all_bufnrs()

        assert.is_true(registered[61])
        assert.is_true(registered[62])
        assert.is_true(registered[63])
        assert.is_nil(registered[64])
    end)
end)
