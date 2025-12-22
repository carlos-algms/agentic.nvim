describe("basic test suite", function()
    it("should assert two equal values", function()
        local a = 1
        local b = 1
        assert.are.equal(a, b)
    end)

    it("should assert true is true", function()
        assert.is_true(true)
    end)

    it("should assert strings match", function()
        local expected = "hello"
        local actual = "hello"
        assert.are.equal(expected, actual)
    end)
end)
