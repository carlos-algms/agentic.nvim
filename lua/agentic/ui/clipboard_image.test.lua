local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("ClipboardImage", function()
    --- @type agentic.ui.ClipboardImage
    local ClipboardImage

    --- @type TestStub
    local has_stub
    --- @type TestStub
    local executable_stub
    local original_wayland

    before_each(function()
        package.loaded["agentic.ui.clipboard_image"] = nil
        ClipboardImage = require("agentic.ui.clipboard_image")
        has_stub = spy.stub(vim.fn, "has")
        executable_stub = spy.stub(vim.fn, "executable")
        original_wayland = vim.env.WAYLAND_DISPLAY
        vim.env.WAYLAND_DISPLAY = nil
    end)

    after_each(function()
        has_stub:revert()
        executable_stub:revert()
        vim.env.WAYLAND_DISPLAY = original_wayland
    end)

    describe("get_platform", function()
        it("returns 'mac' when has('mac') is 1", function()
            has_stub:invokes(function(feature)
                return feature == "mac" and 1 or 0
            end)
            assert.equal("mac", ClipboardImage.get_platform())
        end)

        it("returns 'win' when has('win32') is 1", function()
            has_stub:invokes(function(feature)
                return feature == "win32" and 1 or 0
            end)
            assert.equal("win", ClipboardImage.get_platform())
        end)

        it(
            "returns 'win' when has('wsl') is 1 and powershell.exe is on PATH",
            function()
                has_stub:invokes(function(feature)
                    return feature == "wsl" and 1 or 0
                end)
                executable_stub:invokes(function(name)
                    return name == "powershell.exe" and 1 or 0
                end)
                assert.equal("win", ClipboardImage.get_platform())
            end
        )

        it(
            "returns 'linux_x11' when has('wsl') is 1 but powershell.exe missing and no Wayland",
            function()
                has_stub:invokes(function(feature)
                    return feature == "wsl" and 1 or 0
                end)
                executable_stub:returns(0)
                vim.env.WAYLAND_DISPLAY = nil
                assert.equal("linux_x11", ClipboardImage.get_platform())
            end
        )

        it(
            "returns 'linux_wayland' when has('wsl') is 1 but powershell.exe missing and WAYLAND_DISPLAY set",
            function()
                has_stub:invokes(function(feature)
                    return feature == "wsl" and 1 or 0
                end)
                executable_stub:returns(0)
                vim.env.WAYLAND_DISPLAY = "wayland-0"
                assert.equal("linux_wayland", ClipboardImage.get_platform())
            end
        )

        it(
            "returns 'linux_wayland' on Linux when WAYLAND_DISPLAY is set",
            function()
                has_stub:returns(0)
                vim.env.WAYLAND_DISPLAY = "wayland-0"
                assert.equal("linux_wayland", ClipboardImage.get_platform())
            end
        )

        it(
            "returns 'linux_x11' on Linux when WAYLAND_DISPLAY is unset",
            function()
                has_stub:returns(0)
                vim.env.WAYLAND_DISPLAY = nil
                assert.equal("linux_x11", ClipboardImage.get_platform())
            end
        )
    end)

    describe("is_supported", function()
        it("returns true on mac without probing executables", function()
            has_stub:invokes(function(feature)
                return feature == "mac" and 1 or 0
            end)
            assert.is_true(ClipboardImage.is_supported())
            assert.equal(0, executable_stub.call_count)
        end)

        it("returns true on win when powershell.exe is available", function()
            has_stub:invokes(function(feature)
                return feature == "win32" and 1 or 0
            end)
            executable_stub:invokes(function(name)
                return name == "powershell.exe" and 1 or 0
            end)
            assert.is_true(ClipboardImage.is_supported())
        end)

        it("returns false on win when powershell.exe is missing", function()
            has_stub:invokes(function(feature)
                return feature == "win32" and 1 or 0
            end)
            executable_stub:returns(0)
            assert.is_false(ClipboardImage.is_supported())
        end)

        it(
            "returns true on linux_wayland when wl-paste is available",
            function()
                has_stub:returns(0)
                vim.env.WAYLAND_DISPLAY = "wayland-0"
                executable_stub:invokes(function(name)
                    return name == "wl-paste" and 1 or 0
                end)
                assert.is_true(ClipboardImage.is_supported())
            end
        )

        it("returns false on linux_wayland when wl-paste is missing", function()
            has_stub:returns(0)
            vim.env.WAYLAND_DISPLAY = "wayland-0"
            executable_stub:returns(0)
            assert.is_false(ClipboardImage.is_supported())
        end)

        it("returns true on linux_x11 when xclip is available", function()
            has_stub:returns(0)
            vim.env.WAYLAND_DISPLAY = nil
            executable_stub:invokes(function(name)
                return name == "xclip" and 1 or 0
            end)
            assert.is_true(ClipboardImage.is_supported())
        end)

        it("returns false on linux_x11 when xclip is missing", function()
            has_stub:returns(0)
            vim.env.WAYLAND_DISPLAY = nil
            executable_stub:returns(0)
            assert.is_false(ClipboardImage.is_supported())
        end)
    end)
end)
