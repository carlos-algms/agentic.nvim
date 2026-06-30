--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

local function normalize(p)
    return vim.fn.resolve(vim.fn.fnamemodify(p, ":p"))
end

local function assert_buf_name(expected, bufnr)
    assert.equal(
        normalize(expected),
        normalize(vim.api.nvim_buf_get_name(bufnr))
    )
end

describe("WindowDecoration._set_buffer_name", function()
    --- @type agentic.ui.WindowDecoration
    local WindowDecoration

    --- @type integer[]
    local created_bufs

    before_each(function()
        package.loaded["agentic.ui.window_decoration"] = nil
        WindowDecoration = require("agentic.ui.window_decoration")
        created_bufs = {}
    end)

    after_each(function()
        for _, b in ipairs(created_bufs) do
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end)

    local function new_buf()
        local b = vim.api.nvim_create_buf(false, true)
        table.insert(created_bufs, b)
        return b
    end

    it("sets name when no buffer holds it", function()
        local bufnr = new_buf()
        local name = vim.fn.tempname() .. "_no_collision"

        WindowDecoration._set_buffer_name(bufnr, name)

        assert_buf_name(name, bufnr)
    end)

    it("renames existing buffer to <name>-old-1 on first collision", function()
        local existing = new_buf()
        local name = vim.fn.tempname() .. "_collision"
        vim.api.nvim_buf_set_name(existing, name)

        local target = new_buf()
        WindowDecoration._set_buffer_name(target, name)

        assert_buf_name(name, target)
        assert_buf_name(name .. "-old-1", existing)
    end)

    it("uses <name>-old-2 when <name>-old-1 also exists", function()
        local oldest = new_buf()
        local name = vim.fn.tempname() .. "_double"
        vim.api.nvim_buf_set_name(oldest, name .. "-old-1")

        local existing = new_buf()
        vim.api.nvim_buf_set_name(existing, name)

        local target = new_buf()
        WindowDecoration._set_buffer_name(target, name)

        assert_buf_name(name, target)
        assert_buf_name(name .. "-old-2", existing)
        assert_buf_name(name .. "-old-1", oldest)
    end)

    it("uses <name>-old-3 when -old-1 and -old-2 exist", function()
        local b1 = new_buf()
        local name = vim.fn.tempname() .. "_triple"
        vim.api.nvim_buf_set_name(b1, name .. "-old-1")

        local b2 = new_buf()
        vim.api.nvim_buf_set_name(b2, name .. "-old-2")

        local existing = new_buf()
        vim.api.nvim_buf_set_name(existing, name)

        local target = new_buf()
        WindowDecoration._set_buffer_name(target, name)

        assert_buf_name(name, target)
        assert_buf_name(name .. "-old-3", existing)
    end)

    it(
        "uses <name>-old-4 when name, -old-1, -old-2, -old-3 all pre-exist",
        function()
            local name = vim.fn.tempname() .. "_quad"

            local b1 = new_buf()
            vim.api.nvim_buf_set_name(b1, name .. "-old-1")
            local b2 = new_buf()
            vim.api.nvim_buf_set_name(b2, name .. "-old-2")
            local b3 = new_buf()
            vim.api.nvim_buf_set_name(b3, name .. "-old-3")

            local existing = new_buf()
            vim.api.nvim_buf_set_name(existing, name)

            local target = new_buf()
            WindowDecoration._set_buffer_name(target, name)

            assert_buf_name(name, target)
            assert_buf_name(name .. "-old-4", existing)
            assert_buf_name(name .. "-old-1", b1)
            assert_buf_name(name .. "-old-2", b2)
            assert_buf_name(name .. "-old-3", b3)
        end
    )

    it("is a no-op when bufnr already holds the target name", function()
        local bufnr = new_buf()
        local name = vim.fn.tempname() .. "_same"
        vim.api.nvim_buf_set_name(bufnr, name)

        WindowDecoration._set_buffer_name(bufnr, name)

        assert_buf_name(name, bufnr)
    end)
end)

describe("WindowDecoration._build_default_header", function()
    --- @type agentic.ui.WindowDecoration
    local WindowDecoration

    before_each(function()
        package.loaded["agentic.ui.window_decoration"] = nil
        WindowDecoration = require("agentic.ui.window_decoration")
    end)

    --- Stub session_state exposing only the getters the header consumes.
    --- @param cost_raw number|nil Cumulative cost; nil/0 omits the cost segment
    --- @param currency string|nil Cost currency
    --- @param context { used: string|nil, size: string|nil }|nil Overrides the
    ---   human-readable context getters; defaults to "1K"/"200K"
    --- @return agentic.acp.SessionState
    local function fake_session_state(cost_raw, currency, context)
        --- @type string|nil, string|nil
        local used, size = "1K", "200K"
        if context ~= nil then
            used = context.used
            size = context.size
        end
        --- @type any
        local stub = {
            get_provider_name = function()
                return "Claude"
            end,
            get_model_name = function()
                return "Sonnet"
            end,
            get_mode_name = function()
                return "Ask"
            end,
            get_context_used = function()
                return used
            end,
            get_context_size = function()
                return size
            end,
            get_cost_amount_raw = function()
                return cost_raw
            end,
            get_cost_amount = function()
                return cost_raw and string.format("%.2f", cost_raw) or nil
            end,
            get_cost_currency = function()
                return currency or "USD"
            end,
        }
        return stub
    end

    it("builds rich chat header without any key-hint suffix", function()
        -- suffix is present but the chat panel must ignore it; the hints
        -- belong on the input header.
        local parts =
            { title = "Agentic Chat", suffix = "change mode: <S-Tab>" }

        local text = WindowDecoration._build_default_header(
            "chat",
            parts,
            fake_session_state(0.5)
        )

        assert.equal(
            "Agentic Chat | Claude - Sonnet - Ask (1K/200K) USD 0.50",
            text
        )
    end)

    it("shows the reported cost currency", function()
        local parts = { title = "Agentic Chat" }

        local text = WindowDecoration._build_default_header(
            "chat",
            parts,
            fake_session_state(0.5, "EUR")
        )

        assert.equal(
            "Agentic Chat | Claude - Sonnet - Ask (1K/200K) EUR 0.50",
            text
        )
    end)

    it("omits cost segment when cost is nil", function()
        local parts = { title = "Agentic Chat" }

        local text = WindowDecoration._build_default_header(
            "chat",
            parts,
            fake_session_state(nil)
        )

        assert.equal("Agentic Chat | Claude - Sonnet - Ask (1K/200K)", text)
    end)

    it("omits cost segment when cost is zero", function()
        local parts = { title = "Agentic Chat" }

        local text = WindowDecoration._build_default_header(
            "chat",
            parts,
            fake_session_state(0)
        )

        assert.equal("Agentic Chat | Claude - Sonnet - Ask (1K/200K)", text)
    end)

    it("omits usage segment when context is not reported yet", function()
        local parts = { title = "Agentic Chat" }

        local text = WindowDecoration._build_default_header(
            "chat",
            parts,
            fake_session_state(nil, nil, { used = nil, size = nil })
        )

        assert.equal("Agentic Chat | Claude - Sonnet - Ask", text)
    end)

    it("omits usage segment when only one usage value is present", function()
        local parts = { title = "Agentic Chat" }

        local text = WindowDecoration._build_default_header(
            "chat",
            parts,
            fake_session_state(nil, nil, { used = "1K", size = nil })
        )

        assert.equal("Agentic Chat | Claude - Sonnet - Ask", text)
    end)

    it("omits the provider segment when provider name is nil", function()
        --- @type any
        local stub = {
            get_provider_name = function()
                return nil
            end,
            get_model_name = function()
                return "Sonnet"
            end,
            get_mode_name = function()
                return "Ask"
            end,
            get_context_used = function()
                return "1K"
            end,
            get_context_size = function()
                return "200K"
            end,
            get_cost_amount_raw = function()
                return nil
            end,
            get_cost_amount = function()
                return nil
            end,
            get_cost_currency = function()
                return nil
            end,
        }

        local text = WindowDecoration._build_default_header(
            "chat",
            { title = "Agentic Chat" },
            stub
        )

        assert.equal("Agentic Chat | Sonnet - Ask (1K/200K)", text)
    end)

    it("omits provider and mode segments when names are empty", function()
        --- @type any
        local stub = {
            get_provider_name = function()
                return ""
            end,
            get_model_name = function()
                return "Sonnet"
            end,
            get_mode_name = function()
                return ""
            end,
            get_context_used = function()
                return nil
            end,
            get_context_size = function()
                return nil
            end,
            get_cost_amount_raw = function()
                return nil
            end,
            get_cost_amount = function()
                return nil
            end,
            get_cost_currency = function()
                return nil
            end,
        }

        local text = WindowDecoration._build_default_header(
            "chat",
            { title = "Agentic Chat" },
            stub
        )

        assert.equal("Agentic Chat | Sonnet", text)
    end)

    it("omits the mode segment when mode name is nil", function()
        --- @type any
        local stub = {
            get_provider_name = function()
                return "Claude"
            end,
            get_model_name = function()
                return "Sonnet"
            end,
            get_mode_name = function()
                return nil
            end,
            get_context_used = function()
                return nil
            end,
            get_context_size = function()
                return nil
            end,
            get_cost_amount_raw = function()
                return nil
            end,
            get_cost_amount = function()
                return nil
            end,
            get_cost_currency = function()
                return nil
            end,
        }

        local text = WindowDecoration._build_default_header(
            "chat",
            { title = "Agentic Chat" },
            stub
        )

        assert.equal("Agentic Chat | Claude - Sonnet", text)
    end)

    it("keeps the input header carrying both key hints", function()
        local parts =
            { title = "Prompt", suffix = "submit: <C-s> change mode: <S-Tab>" }

        local text = WindowDecoration._build_default_header(
            "input",
            parts,
            fake_session_state(0.5)
        )

        assert.equal("Prompt | submit: <C-s> change mode: <S-Tab>", text)
    end)

    it("falls back to plain concat when session_state is nil", function()
        local chat = WindowDecoration._build_default_header(
            "chat",
            { title = "Agentic Chat", suffix = "change mode: <S-Tab>" },
            nil
        )
        assert.equal("Agentic Chat | change mode: <S-Tab>", chat)

        local input = WindowDecoration._build_default_header(
            "input",
            { title = "Prompt", suffix = "submit: <C-s>" },
            nil
        )
        assert.equal("Prompt | submit: <C-s>", input)
    end)
end)

describe("WindowDecoration.render_header", function()
    local child = Child:new()

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    --- Build a buffer displayed in a window, install header + buffer_name
    --- function configs that record their 2nd arg, then render_header with a
    --- session_state carrying a unique marker. Returns recorded markers.
    --- @param window_name string
    --- @return integer bufnr the buffer rendered into; recorded markers are read via _G globals
    local function render_with_session_state(window_name)
        return child.lua(string.format(
            [[
            local WindowDecoration = require("agentic.ui.window_decoration")
            local Config = require("agentic.config")

            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_win_set_buf(0, bufnr)

            Config.headers = Config.headers or {}
            Config.headers.%s = function(parts, session_state)
                _G.recorded_header_marker =
                    session_state and session_state.marker or nil
                return parts.title
            end

            Config.windows.%s.buffer_name = function(parts, session_state)
                _G.recorded_buffer_name_marker =
                    session_state and session_state.marker or nil
                return "%s-buf-name"
            end

            local session_state = { marker = "SS_MARKER" }
            WindowDecoration.render_header(bufnr, "%s", nil, session_state)

            return bufnr
        ]],
            window_name,
            window_name,
            window_name,
            window_name
        ))
    end

    it("passes session_state as 2nd arg to header function", function()
        render_with_session_state("chat")
        child.flush()

        assert.equal("SS_MARKER", child.lua_get("_G.recorded_header_marker"))
    end)

    it("passes session_state as 2nd arg to buffer_name function", function()
        render_with_session_state("chat")
        child.flush()

        assert.equal(
            "SS_MARKER",
            child.lua_get("_G.recorded_buffer_name_marker")
        )
    end)

    it("passes session_state as 2nd arg to input header function", function()
        render_with_session_state("input")
        child.flush()

        assert.equal("SS_MARKER", child.lua_get("_G.recorded_header_marker"))
    end)

    it(
        "passes session_state as 2nd arg to input buffer_name function",
        function()
            render_with_session_state("input")
            child.flush()

            assert.equal(
                "SS_MARKER",
                child.lua_get("_G.recorded_buffer_name_marker")
            )
        end
    )

    it("passes nil session_state to non-chat header function", function()
        render_with_session_state("code")
        child.flush()

        assert.is_true(child.lua_get("_G.recorded_header_marker == nil"))
    end)

    it("passes nil session_state to non-chat buffer_name function", function()
        render_with_session_state("code")
        child.flush()

        assert.is_true(child.lua_get("_G.recorded_buffer_name_marker == nil"))
    end)

    it("legacy single-arg header fn still works", function()
        child.lua([[
            local WindowDecoration = require("agentic.ui.window_decoration")
            local Config = require("agentic.config")

            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_win_set_buf(0, bufnr)

            Config.headers = Config.headers or {}
            -- Single-arg fn: ignores the new 2nd arg entirely.
            Config.headers.chat = function(parts)
                _G.legacy_returned = parts.title
                return parts.title
            end

            WindowDecoration.render_header(
                bufnr,
                "chat",
                nil,
                { marker = "SS_MARKER" }
            )
        ]])
        child.flush()

        local returned = child.lua_get("_G.legacy_returned")
        assert.is_true(returned:find("Agentic Chat", 1, true) ~= nil)
    end)
end)
