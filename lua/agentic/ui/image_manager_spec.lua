describe("agentic.ui.ImageManager", function()
    local ImageManager = require("agentic.ui.image_manager")
    local spy = require("luassert.spy")
    local stub = require("luassert.stub")

    --- @type integer
    local bufnr
    --- @type agentic.ui.ImageManager
    local image_manager
    local on_change_spy

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        on_change_spy = spy.new(function() end)

        image_manager =
            ImageManager:new(bufnr, on_change_spy --[[@as function]])
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("new", function()
        it("creates instance with empty images list", function()
            assert.is_true(image_manager:is_empty())
        end)

        it("sets up buffer and callback", function()
            local images = image_manager:get_images()
            assert.equal(0, #images)
        end)
    end)

    describe("get_images and is_empty", function()
        it("returns empty array initially", function()
            local images = image_manager:get_images()
            assert.equal(0, #images)
            assert.is_true(image_manager:is_empty())
        end)

        it("returns images after adding", function()
            -- Use public API via stubbed clipboard
            local get_clipboard_stub =
                stub(image_manager, "_get_clipboard_image")
            ---@diagnostic disable-next-line: undefined-field
            get_clipboard_stub.returns("base64data", "image/png")

            image_manager:paste_from_clipboard()
            ---@diagnostic disable-next-line: undefined-field
            get_clipboard_stub:revert()

            local images = image_manager:get_images()
            assert.equal(1, #images)
            assert.is_false(image_manager:is_empty())
            assert.equal("base64data", images[1].data)
            assert.equal("image/png", images[1].mimeType)
        end)
    end)

    describe("clear", function()
        it("removes all images and triggers callback", function()
            -- Add images using public API via stubbed clipboard
            local get_clipboard_stub =
                stub(image_manager, "_get_clipboard_image")
            ---@diagnostic disable-next-line: undefined-field
            get_clipboard_stub.on_call(1).returns("data1", "image/png")
            ---@diagnostic disable-next-line: undefined-field
            get_clipboard_stub.on_call(2).returns("data2", "image/jpeg")

            image_manager:paste_from_clipboard()
            image_manager:paste_from_clipboard()
            ---@diagnostic disable-next-line: undefined-field
            get_clipboard_stub:revert()

            assert.equal(2, #image_manager:get_images())

            -- Clear
            image_manager:clear()

            assert.is_true(image_manager:is_empty())
            -- Called 2 times for paste + 1 time for clear = 3
            assert.spy(on_change_spy).was.called(3)
        end)
    end)

    describe("paste_from_clipboard", function()
        local get_clipboard_stub

        before_each(function()
            get_clipboard_stub =
                stub(image_manager, "_get_clipboard_image")
        end)

        after_each(function()
            ---@diagnostic disable-next-line: undefined-field
            get_clipboard_stub:revert()
        end)

        it("adds image when clipboard has image data", function()
            ---@diagnostic disable-next-line: undefined-field
            get_clipboard_stub.returns("iVBORw0KGgo=", "image/png")

            image_manager:paste_from_clipboard()

            local images = image_manager:get_images()
            assert.equal(1, #images)
            assert.equal("iVBORw0KGgo=", images[1].data)
            assert.equal("image/png", images[1].mimeType)
            assert.spy(on_change_spy).was.called(1)
        end)

        it("does not add image when clipboard is empty", function()
            ---@diagnostic disable-next-line: undefined-field
            get_clipboard_stub.returns(nil, nil)

            image_manager:paste_from_clipboard()

            assert.is_true(image_manager:is_empty())
            assert.spy(on_change_spy).was.not_called()
        end)

        it("adds multiple images sequentially", function()
            ---@diagnostic disable-next-line: undefined-field
            get_clipboard_stub.on_call(1).returns("data1", "image/png")
            ---@diagnostic disable-next-line: undefined-field
            get_clipboard_stub.on_call(2).returns("data2", "image/jpeg")

            image_manager:paste_from_clipboard()
            image_manager:paste_from_clipboard()

            local images = image_manager:get_images()
            assert.equal(2, #images)
            assert.spy(on_change_spy).was.called(2)
        end)
    end)
end)
