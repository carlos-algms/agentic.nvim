-- tests/helpers/assert.lua
-- Custom assert module wrapping mini.test's expect for familiar busted/luassert API

local MiniTest = require("mini.test")
local expect = MiniTest.expect

local M = {}

-- Basic equality
function M.equal(expected, actual)
    expect.equality(actual, expected)
end

-- Deep equality (same as equal in mini.test)
function M.same(expected, actual)
    expect.equality(actual, expected)
end

-- Type checks
function M.is_nil(value)
    expect.equality(value, nil)
end

function M.is_not_nil(value)
    expect.no_equality(value, nil)
end

function M.is_true(value)
    expect.equality(value, true)
end

function M.is_false(value)
    expect.equality(value, false)
end

function M.is_table(value)
    expect.equality(type(value), "table")
end

function M.is_string(value)
    expect.equality(type(value), "string")
end

function M.is_number(value)
    expect.equality(type(value), "number")
end

function M.is_function(value)
    expect.equality(type(value), "function")
end

-- Truthy/falsy
function M.truthy(value)
    expect.equality(not not value, true)
end

function M.is_truthy(value)
    expect.equality(not not value, true)
end

function M.falsy(value)
    expect.equality(not value, true)
end

function M.is_falsy(value)
    expect.equality(not value, true)
end

-- Error handling
function M.has_error(fn, pattern)
    expect.error(fn, pattern)
end

function M.has_no_errors(fn)
    local ok, err = pcall(fn)
    if not ok then
        error("Expected no error but got: " .. tostring(err))
    end
end

-- Negated equality (uses rawequal for identity comparison on tables)
M.is_not = {
    equal = function(expected, actual)
        if type(expected) == "table" and type(actual) == "table" then
            -- Use identity comparison for tables
            expect.equality(rawequal(actual, expected), false)
        else
            expect.no_equality(actual, expected)
        end
    end,
    same = function(expected, actual)
        expect.no_equality(actual, expected)
    end,
}

-- are/are_not variants (busted style)
M.are = {
    equal = M.equal,
    same = M.same,
    truthy = M.truthy,
    falsy = M.falsy,
}

M.are_not = {
    equal = function(expected, actual)
        if type(expected) == "table" and type(actual) == "table" then
            -- Use identity comparison for tables
            expect.equality(rawequal(actual, expected), false)
        else
            expect.no_equality(actual, expected)
        end
    end,
    same = M.is_not.same,
    truthy = M.falsy,
    falsy = M.truthy,
}

--- Create spy/stub assertion chain
--- @param spy_or_stub table
--- @return table
local function create_spy_chain(spy_or_stub)
    return {
        was = {
            called = function(n)
                expect.equality(spy_or_stub.call_count, n)
            end,
            called_with = function(...)
                expect.equality(spy_or_stub:called_with(...), true)
            end,
        },
    }
end

function M.spy(s)
    return create_spy_chain(s)
end

function M.stub(s)
    return create_spy_chain(s)
end

return M
