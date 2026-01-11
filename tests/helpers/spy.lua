-- Simple spy/stub implementation for mini.test
-- Provides tracking of function calls without luassert dependency

---@diagnostic disable: invisible, return-type-mismatch

local M = {}

--- @class TestSpy
--- @field calls table[] List of call arguments
--- @field call_count number Number of times called
--- @field _fn function|nil Original function to wrap
--- @field _original_fn function|nil Original function (for reverting)
--- @field _target table|nil Target object (for method spies)
--- @field _method string|nil Method name (for method spies)
--- @field called_with fun(self: TestSpy, ...: any): boolean Check if called with args
--- @field call fun(self: TestSpy, n: number): table|nil Get args from call n
--- @field clear fun(self: TestSpy) Clear call history
--- @field revert fun(self: TestSpy) Revert to original function

--- Create a new spy function
--- @param fn? function Optional function to wrap
--- @return TestSpy
function M.new(fn)
    local spy = {
        calls = {},
        call_count = 0,
        _fn = fn,
        _original_fn = nil,
        _target = nil,
        _method = nil,
    }

    --- Check if spy was called with specific arguments
    --- @param ... any Expected arguments
    --- @return boolean
    function spy:called_with(...)
        local expected = { ... }
        for _, call_args in ipairs(self.calls) do
            if vim.deep_equal(call_args, expected) then
                return true
            end
        end
        return false
    end

    --- Get arguments from a specific call
    --- @param n number Call index (1-based)
    --- @return table|nil args Arguments from that call
    function spy:call(n)
        return self.calls[n]
    end

    --- Clear call history
    function spy:clear()
        self.calls = {}
        self.call_count = 0
    end

    --- Revert a spy to the original function
    function spy:revert()
        if self._target and self._method and self._original_fn then
            self._target[self._method] = self._original_fn
        end
    end

    return setmetatable(spy, {
        __call = function(self, ...)
            local args = { ... }
            table.insert(self.calls, args)
            self.call_count = self.call_count + 1
            if self._fn then
                return self._fn(...)
            end
        end,
    })
end

--- Create a spy on an existing object method
--- @param target table Object containing the method
--- @param method string Method name to spy on
--- @return TestSpy
function M.on(target, method)
    local original = target[method]
    local s = M.new(original)
    s._original_fn = original
    s._target = target
    s._method = method
    target[method] = s
    return s
end

--- @class TestStub
--- @field calls table[] List of call arguments
--- @field call_count number Number of times called
--- @field _return_value any Value to return
--- @field _invokes_fn function|nil Function to invoke
--- @field _original_fn function|nil Original function (for reverting)
--- @field _target table|nil Target object
--- @field _method string|nil Method name
--- @field returns fun(self: TestStub, value: any) Set return value
--- @field invokes fun(self: TestStub, fn: function) Set invoke function
--- @field revert fun(self: TestStub) Revert to original function
--- @field clear fun(self: TestStub) Clear call history
--- @field called_with fun(self: TestStub, ...: any): boolean Check if called with args

--- Create a stub that replaces a method
--- @param target table Object containing the method
--- @param method string Method name to stub
--- @return TestStub
function M.stub(target, method)
    local original = target[method]
    local stub = {
        calls = {},
        call_count = 0,
        _original_fn = original,
        _target = target,
        _method = method,
        _return_value = nil,
        _invokes_fn = nil,
    }

    --- Set the return value for the stub
    --- @param value any Value to return when stub is called
    function stub:returns(value)
        self._return_value = value
    end

    --- Set a function to invoke when stub is called
    --- @param fn function Function to invoke
    function stub:invokes(fn)
        self._invokes_fn = fn
    end

    --- Revert the stub to original function
    function stub:revert()
        if self._target and self._method and self._original_fn then
            self._target[self._method] = self._original_fn
        end
    end

    --- Clear call history
    function stub:clear()
        self.calls = {}
        self.call_count = 0
    end

    --- Check if stub was called with specific arguments
    --- @param ... any Expected arguments
    --- @return boolean
    function stub:called_with(...)
        local expected = { ... }
        for _, call_args in ipairs(self.calls) do
            if vim.deep_equal(call_args, expected) then
                return true
            end
        end
        return false
    end

    local callable = setmetatable(stub, {
        __call = function(self, ...)
            local args = { ... }
            table.insert(self.calls, args)
            self.call_count = self.call_count + 1
            if self._invokes_fn then
                return self._invokes_fn(...)
            end
            return self._return_value
        end,
    })

    target[method] = callable
    return callable
end

return M
