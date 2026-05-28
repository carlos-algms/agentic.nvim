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
                has_stub:invokes(function(feature)
                    return feature == "linux" and 1 or 0
                end)
                vim.env.WAYLAND_DISPLAY = "wayland-0"
                assert.equal("linux_wayland", ClipboardImage.get_platform())
            end
        )

        it(
            "returns 'linux_x11' on Linux when WAYLAND_DISPLAY is unset",
            function()
                has_stub:invokes(function(feature)
                    return feature == "linux" and 1 or 0
                end)
                vim.env.WAYLAND_DISPLAY = nil
                assert.equal("linux_x11", ClipboardImage.get_platform())
            end
        )

        it(
            "returns 'unknown' on a host that is neither mac, win, nor Linux",
            function()
                has_stub:returns(0)
                vim.env.WAYLAND_DISPLAY = nil
                assert.equal("unknown", ClipboardImage.get_platform())
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
                has_stub:invokes(function(feature)
                    return feature == "linux" and 1 or 0
                end)
                vim.env.WAYLAND_DISPLAY = "wayland-0"
                executable_stub:invokes(function(name)
                    return name == "wl-paste" and 1 or 0
                end)
                assert.is_true(ClipboardImage.is_supported())
            end
        )

        it("returns false on linux_wayland when wl-paste is missing", function()
            has_stub:invokes(function(feature)
                return feature == "linux" and 1 or 0
            end)
            vim.env.WAYLAND_DISPLAY = "wayland-0"
            executable_stub:returns(0)
            assert.is_false(ClipboardImage.is_supported())
        end)

        it("returns true on linux_x11 when xclip is available", function()
            has_stub:invokes(function(feature)
                return feature == "linux" and 1 or 0
            end)
            vim.env.WAYLAND_DISPLAY = nil
            executable_stub:invokes(function(name)
                return name == "xclip" and 1 or 0
            end)
            assert.is_true(ClipboardImage.is_supported())
        end)

        it("returns false on linux_x11 when xclip is missing", function()
            has_stub:invokes(function(feature)
                return feature == "linux" and 1 or 0
            end)
            vim.env.WAYLAND_DISPLAY = nil
            executable_stub:returns(0)
            assert.is_false(ClipboardImage.is_supported())
        end)

        it("returns false when platform is unknown", function()
            has_stub:returns(0)
            vim.env.WAYLAND_DISPLAY = nil
            assert.is_false(ClipboardImage.is_supported())
        end)
    end)

    describe("has_image", function()
        --- @type TestStub
        local run_stub

        before_each(function()
            run_stub = spy.stub(ClipboardImage, "_run")
        end)

        after_each(function()
            run_stub:revert()
        end)

        --- @param platform "mac"|"win"|"linux_wayland"|"linux_x11"|"unknown"
        local function force_platform(platform)
            has_stub:invokes(function(feature)
                if platform == "mac" and feature == "mac" then
                    return 1
                end
                if platform == "win" and feature == "win32" then
                    return 1
                end
                if
                    (platform == "linux_wayland" or platform == "linux_x11")
                    and feature == "linux"
                then
                    return 1
                end
                return 0
            end)
            if platform == "linux_wayland" then
                vim.env.WAYLAND_DISPLAY = "wayland-0"
            else
                vim.env.WAYLAND_DISPLAY = nil
            end
        end

        local cases = {
            {
                name = "mac true when stdout contains «class PNGf»",
                platform = "mac",
                run_return = { true, "... «class PNGf» ..." },
                expected = true,
                expected_argv = { "osascript", "-e", "clipboard info" },
            },
            {
                name = "mac false when stdout has no PNGf marker",
                platform = "mac",
                run_return = { true, "... «class TEXT» ..." },
                expected = false,
            },
            {
                name = "mac false when _run fails",
                platform = "mac",
                run_return = { false, "" },
                expected = false,
            },
            {
                name = "win true when _run exits 0",
                platform = "win",
                run_return = { true, "" },
                expected = true,
            },
            {
                name = "win false when _run exits non-zero",
                platform = "win",
                run_return = { false, "" },
                expected = false,
            },
            {
                name = "linux_wayland true when stdout has image/png",
                platform = "linux_wayland",
                run_return = { true, "image/png\ntext/plain" },
                expected = true,
                expected_argv = { "wl-paste", "--list-types" },
            },
            {
                name = "linux_wayland false when stdout lacks image/png",
                platform = "linux_wayland",
                run_return = { true, "text/plain" },
                expected = false,
            },
            {
                name = "linux_wayland false when _run fails",
                platform = "linux_wayland",
                run_return = { false, "" },
                expected = false,
            },
            {
                name = "linux_x11 true when stdout has image/png",
                platform = "linux_x11",
                run_return = { true, "TARGETS\nimage/png" },
                expected = true,
                expected_argv = {
                    "xclip",
                    "-selection",
                    "clipboard",
                    "-t",
                    "TARGETS",
                    "-o",
                },
            },
            {
                name = "linux_x11 false when stdout lacks image/png",
                platform = "linux_x11",
                run_return = { true, "TARGETS\nUTF8_STRING" },
                expected = false,
            },
            {
                name = "linux_x11 false when _run fails",
                platform = "linux_x11",
                run_return = { false, "" },
                expected = false,
            },
        }

        for _, case in ipairs(cases) do
            it(case.name, function()
                force_platform(case.platform)
                run_stub:invokes(function()
                    return case.run_return[1], case.run_return[2]
                end)

                assert.equal(case.expected, ClipboardImage.has_image())

                if case.expected_argv then
                    assert.equal(1, run_stub.call_count)
                    local cmd = run_stub.calls[1][1]
                    assert.same(case.expected_argv, cmd)
                end
            end)
        end

        it("returns false on unknown platform without calling _run", function()
            force_platform("unknown")
            assert.is_false(ClipboardImage.has_image())
            assert.equal(0, run_stub.call_count)
        end)

        it("includes the powershell preamble for the win branch", function()
            force_platform("win")
            run_stub:invokes(function()
                return true, ""
            end)
            ClipboardImage.has_image()
            assert.equal(1, run_stub.call_count)
            local cmd = run_stub.calls[1][1]
            assert.equal("powershell.exe", cmd[1])
            assert.equal("-NoProfile", cmd[2])
            assert.equal("-Command", cmd[3])
            assert.is_true(
                cmd[4]:find(
                    "Add-Type -AssemblyName System.Windows.Forms",
                    1,
                    true
                ) ~= nil
            )
            assert.is_true(
                cmd[4]:find(
                    "[System.Windows.Forms.Clipboard]::ContainsImage",
                    1,
                    true
                ) ~= nil
            )
        end)
    end)
end)
