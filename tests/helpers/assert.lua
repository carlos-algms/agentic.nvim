--- Custom assert module wrapping mini.test's expect for familiar busted/luassert API

local MiniTest = require("mini.test")
local expect = MiniTest.expect

--- @class tests.helpers.AssertSpyChain
--- @field was tests.helpers.AssertSpyWas

--- @class tests.helpers.AssertSpyWas
--- @field called fun(n: number|nil) Assert spy was called (no arg = at least once, with arg = exact count)
--- @field called_with fun(...: any) Assert spy was called with specific arguments

--- @class tests.helpers.Assert
local M = {}

--- Basic equality assertion
--- @param actual any Actual value
--- @param expected any Expected value
function M.equal(actual, expected)
    expect.equality(actual, expected)
end

--- Deep equality assertion (same as equal in mini.test)
--- @param actual any Actual value
--- @param expected any Expected value
function M.same(actual, expected)
    expect.equality(actual, expected)
end

--- Assert value is nil
--- @param value any Value to check
function M.is_nil(value)
    expect.equality(value, nil)
end

--- Assert value is not nil
--- @param value any Value to check
function M.is_not_nil(value)
    expect.no_equality(value, nil)
end

--- Assert value is true
--- @param value any Value to check
function M.is_true(value)
    expect.equality(value, true)
end

--- Assert value is false
--- @param value any Value to check
function M.is_false(value)
    expect.equality(value, false)
end

--- Assert value is a table
--- @param value any Value to check
function M.is_table(value)
    expect.equality(type(value), "table")
end

--- Assert value is truthy (not nil and not false)
--- @param value any Value to check
function M.truthy(value)
    expect.equality(not not value, true)
end

--- Assert value is falsy (nil or false)
--- @param value any Value to check
function M.is_falsy(value)
    expect.equality(not value, true)
end

--- Assert function does not throw errors
--- @param fn function Function to execute
function M.has_no_errors(fn)
    expect.no_error(fn)
end

--- Negated equality assertions
--- @class tests.helpers.AssertIsNot
M.is_not = {
    equal = function(actual, expected)
        expect.no_equality(actual, expected)
    end,
    same = function(actual, expected)
        expect.no_equality(actual, expected)
    end,
}

--- Busted-style equality assertions
--- @class tests.helpers.AssertAre
M.are = {
    equal = M.equal,
    same = M.same,
}

--- Busted-style negated equality assertions
--- @class tests.helpers.AssertAreNot
M.are_not = {
    equal = M.is_not.equal,
    same = M.is_not.same,
}

--- Create spy/stub assertion chain
--- @param spy_or_stub TestSpy|TestStub
--- @return tests.helpers.AssertSpyChain
local function create_spy_chain(spy_or_stub)
    return {
        was = {
            called = function(n)
                if n == nil then
                    -- No argument: assert called at least once
                    expect.equality(spy_or_stub.call_count >= 1, true)
                else
                    -- With argument: assert exact call count
                    expect.equality(spy_or_stub.call_count, n)
                end
            end,
            called_with = function(...)
                expect.equality(spy_or_stub:called_with(...), true)
            end,
        },
    }
end

--- Create assertion chain for a spy
--- @param s TestSpy Spy to create assertion chain for
--- @return tests.helpers.AssertSpyChain
function M.spy(s)
    return create_spy_chain(s)
end

--- Create assertion chain for a stub
--- @param s TestStub Stub to create assertion chain for
--- @return tests.helpers.AssertSpyChain
function M.stub(s)
    return create_spy_chain(s)
end

return M
