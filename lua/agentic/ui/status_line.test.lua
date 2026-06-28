-- lua/agentic/ui/status_line.test.lua
local assert = require("tests.helpers.assert")
local StatusLine = require("agentic.ui.status_line")

local MiniTest = require("mini.test")
local describe = MiniTest.new_set

--- Helper: open a scratch split window, return winid
--- @return integer winid
local function open_scratch_win()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
        split = "right",
        win = -1,
    })
    return win
end

--- Helper: close a window safely
--- @param winid integer
local function close_win(winid)
    if vim.api.nvim_win_is_valid(winid) then
        vim.api.nvim_win_close(winid, true)
    end
end

--- Helper: create a StatusLine attached with the given win_nrs and position.
--- Uses the public attach() API so no private fields are set directly.
--- @param win_nrs table<string, integer>
--- @param position string
--- @return agentic.ui.StatusLine
local function make_attached(win_nrs, position)
    local tab = vim.api.nvim_get_current_tabpage()
    local sl = StatusLine:new()
    sl:attach(tab, win_nrs, position)
    return sl
end

local T = describe({})

T["_anchor_winid"] = describe()

T["_anchor_winid"]["position=right with chat+input returns input"] = function()
    local chat = open_scratch_win()
    local input = open_scratch_win()

    local sl = make_attached({ chat = chat, input = input }, "right")
    local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

    assert.equal(result, input)

    close_win(input)
    close_win(chat)
end

T["_anchor_winid"]["position=left with chat+input returns input"] = function()
    local chat = open_scratch_win()
    local input = open_scratch_win()

    local sl = make_attached({ chat = chat, input = input }, "left")
    local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

    assert.equal(result, input)

    close_win(input)
    close_win(chat)
end

T["_anchor_winid"]["position=bottom with chat+input+code returns code"] = function()
    local chat = open_scratch_win()
    local input = open_scratch_win()
    local code = open_scratch_win()

    local sl =
        make_attached({ chat = chat, input = input, code = code }, "bottom")
    local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

    assert.equal(result, code)

    close_win(code)
    close_win(input)
    close_win(chat)
end

T["_anchor_winid"]["position=bottom with all panels returns todos"] = function()
    local chat = open_scratch_win()
    local input = open_scratch_win()
    local code = open_scratch_win()
    local files = open_scratch_win()
    local diagnostics = open_scratch_win()
    local todos = open_scratch_win()

    local sl = make_attached({
        chat = chat,
        input = input,
        code = code,
        files = files,
        diagnostics = diagnostics,
        todos = todos,
    }, "bottom")
    local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

    assert.equal(result, todos)

    close_win(todos)
    close_win(diagnostics)
    close_win(files)
    close_win(code)
    close_win(input)
    close_win(chat)
end

T["_anchor_winid"]["position=bottom with chat+input only returns input"] = function()
    local chat = open_scratch_win()
    local input = open_scratch_win()

    local sl = make_attached({ chat = chat, input = input }, "bottom")
    local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

    assert.equal(result, input)

    close_win(input)
    close_win(chat)
end

T["_anchor_winid"]["win_nrs with only chat returns chat"] = function()
    local chat = open_scratch_win()

    local sl = make_attached({ chat = chat }, "right")
    local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

    assert.equal(result, chat)

    close_win(chat)
end

T["_anchor_winid"]["invalid input winid falls through to chat"] = function()
    local chat = open_scratch_win()
    local input = open_scratch_win()
    close_win(input)

    local sl = make_attached({ chat = chat, input = input }, "right")
    local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

    assert.equal(result, chat)

    close_win(chat)
end

T["_anchor_winid"]["empty win_nrs returns nil"] = function()
    local sl = make_attached({}, "right")
    local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

    assert.is_nil(result)
end

T["_anchor_winid"]["all winids invalid returns nil"] = function()
    local chat = open_scratch_win()
    local input = open_scratch_win()
    close_win(chat)
    close_win(input)

    local sl = make_attached({ chat = chat, input = input }, "right")
    local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

    assert.is_nil(result)
end

T["_anchor_winid"]["position=bottom with todos absent falls through to diagnostics"] = function()
    local chat = open_scratch_win()
    local input = open_scratch_win()
    local diagnostics = open_scratch_win()

    local sl = make_attached(
        { chat = chat, input = input, diagnostics = diagnostics },
        "bottom"
    )
    local result = sl:_anchor_winid() --- @diagnostic disable-line: invisible

    assert.equal(result, diagnostics)

    close_win(diagnostics)
    close_win(input)
    close_win(chat)
end

return T
