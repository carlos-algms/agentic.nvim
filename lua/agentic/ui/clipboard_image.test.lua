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

    --- @param feature_name string|nil has() feature returning 1; nil = none
    local function stub_has(feature_name)
        has_stub:invokes(function(feature)
            return feature == feature_name and 1 or 0
        end)
    end

    --- @param available table<string, boolean> executable names returning 1
    local function stub_executables(available)
        executable_stub:invokes(function(name)
            return available[name] and 1 or 0
        end)
    end

    --- @param platform agentic.ui.ClipboardImage.Platform
    local function force_platform(platform)
        if platform == "mac" then
            stub_has("mac")
        elseif platform == "win" then
            stub_has("win32")
        elseif platform == "wsl" then
            stub_has("wsl")
        elseif platform == "linux_wayland" or platform == "linux_x11" then
            stub_has("linux")
        else
            stub_has(nil)
        end
        vim.env.WAYLAND_DISPLAY = platform == "linux_wayland" and "wayland-0"
            or nil
    end

    describe("get_platform", function()
        local cases = {
            { name = "mac", has = "mac", expected = "mac" },
            { name = "win", has = "win32", expected = "win" },
            { name = "wsl", has = "wsl", expected = "wsl" },
            {
                name = "linux_wayland when WAYLAND_DISPLAY set",
                has = "linux",
                wayland = "wayland-0",
                expected = "linux_wayland",
            },
            {
                name = "linux_x11 when WAYLAND_DISPLAY unset",
                has = "linux",
                expected = "linux_x11",
            },
            { name = "unknown otherwise", has = nil, expected = "unknown" },
        }

        it("returns expected platform for each case", function()
            for _, case in ipairs(cases) do
                stub_has(case.has)
                vim.env.WAYLAND_DISPLAY = case.wayland
                local actual = ClipboardImage.get_platform()
                if actual ~= case.expected then
                    error(
                        "case '"
                            .. case.name
                            .. "': expected "
                            .. tostring(case.expected)
                            .. ", got "
                            .. tostring(actual)
                    )
                end
            end
        end)

        it("ignores WAYLAND_DISPLAY for non-linux platforms", function()
            stub_has("wsl")
            vim.env.WAYLAND_DISPLAY = "wayland-0"
            assert.equal("wsl", ClipboardImage.get_platform())
            assert.equal(0, executable_stub.call_count)
        end)
    end)

    describe("is_supported", function()
        local cases = {
            { platform = "mac", available = {}, expected = true },
            {
                platform = "win",
                available = { ["powershell.exe"] = true },
                expected = true,
            },
            { platform = "win", available = {}, expected = false },
            {
                platform = "wsl",
                available = { ["powershell.exe"] = true, wslpath = true },
                expected = true,
            },
            {
                platform = "wsl",
                available = { ["powershell.exe"] = true },
                expected = false,
            },
            {
                platform = "wsl",
                available = { wslpath = true },
                expected = false,
            },
            {
                platform = "linux_wayland",
                available = { ["wl-paste"] = true },
                expected = true,
            },
            {
                platform = "linux_wayland",
                available = {},
                expected = false,
            },
            {
                platform = "linux_x11",
                available = { xclip = true },
                expected = true,
            },
            { platform = "linux_x11", available = {}, expected = false },
            { platform = "unknown", available = {}, expected = false },
        }

        for _, case in ipairs(cases) do
            local avail_keys = vim.tbl_keys(case.available)
            table.sort(avail_keys)
            local desc = case.platform
                .. " -> "
                .. tostring(case.expected)
                .. " (available: "
                .. (#avail_keys > 0 and table.concat(avail_keys, ",") or "none")
                .. ")"
            it(desc, function()
                force_platform(case.platform)
                stub_executables(case.available)
                assert.equal(case.expected, ClipboardImage.is_supported())
            end)
        end

        it("does not probe executables on mac", function()
            force_platform("mac")
            ClipboardImage.is_supported()
            assert.equal(0, executable_stub.call_count)
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
                    assert.same(case.expected_argv, run_stub.calls[1][1])
                end
            end)
        end

        it("returns false on unknown platform without calling _run", function()
            force_platform("unknown")
            assert.is_false(ClipboardImage.has_image())
            assert.equal(0, run_stub.call_count)
        end)

        it("win argv includes powershell ContainsImage preamble", function()
            force_platform("win")
            run_stub:invokes(function()
                return true, ""
            end)
            ClipboardImage.has_image()
            local cmd = run_stub.calls[1][1]
            assert.same(
                { "powershell.exe", "-NoProfile", "-Command" },
                { cmd[1], cmd[2], cmd[3] }
            )
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

    describe("save", function()
        --- @type TestStub
        local run_stub
        --- @type TestStub
        local shellescape_stub
        --- @type TestStub
        local fs_stat_stub

        before_each(function()
            run_stub = spy.stub(ClipboardImage, "_run")
            shellescape_stub = spy.stub(vim.fn, "shellescape")
            shellescape_stub:invokes(function(s)
                return "'" .. s .. "'"
            end)
            fs_stat_stub = spy.stub(vim.uv, "fs_stat")
            fs_stat_stub:returns({ size = 1234, type = "file" })
        end)

        after_each(function()
            run_stub:revert()
            shellescape_stub:revert()
            fs_stat_stub:revert()
        end)

        it("mac happy path runs osascript with PNGf script", function()
            force_platform("mac")
            run_stub:invokes(function()
                return true, ""
            end)

            local ok, err = ClipboardImage.save("/tmp/img.png")
            assert.is_true(ok)
            assert.is_nil(err)
            local cmd = run_stub.calls[1][1]
            assert.same({ "osascript", "-e" }, { cmd[1], cmd[2] })
            assert.is_true(cmd[3]:find("/tmp/img.png", 1, true) ~= nil)
            assert.is_true(cmd[3]:find("«class PNGf»", 1, true) ~= nil)
        end)

        it("mac returns (false, err) when _run fails", function()
            force_platform("mac")
            run_stub:invokes(function()
                return false, "error: bad clipboard"
            end)
            local ok, err = ClipboardImage.save("/tmp/img.png")
            assert.is_false(ok)
            assert.equal("error: bad clipboard", err)
        end)

        it("win argv contains GetImage preamble and escapes quotes", function()
            force_platform("win")
            run_stub:invokes(function()
                return true, ""
            end)

            local ok, err = ClipboardImage.save("C:\\tmp\\don't.png")
            assert.is_true(ok)
            assert.is_nil(err)
            local cmd = run_stub.calls[1][1]
            assert.same(
                { "powershell.exe", "-NoProfile", "-Command" },
                { cmd[1], cmd[2], cmd[3] }
            )
            assert.is_true(
                cmd[4]:find(
                    "Add-Type -AssemblyName System.Windows.Forms",
                    1,
                    true
                ) ~= nil
            )
            assert.is_true(
                cmd[4]:find(
                    "[System.Windows.Forms.Clipboard]::GetImage",
                    1,
                    true
                ) ~= nil
            )
            assert.is_true(cmd[4]:find("don''t.png", 1, true) ~= nil)
        end)

        it("wsl converts path via wslpath and stats the linux path", function()
            force_platform("wsl")
            stub_executables({ ["powershell.exe"] = true })
            run_stub:invokes(function(cmd)
                if cmd[1] == "wslpath" then
                    return true,
                        [[\\wsl.localhost\Ubuntu\tmp\pasted image.png]] .. "\n"
                end
                return true, ""
            end)

            local ok, err = ClipboardImage.save("/tmp/pasted image.png")
            assert.is_true(ok)
            assert.is_nil(err)

            assert.equal(2, run_stub.call_count)
            assert.same(
                { "wslpath", "-w", "/tmp/pasted image.png" },
                run_stub.calls[1][1]
            )
            local cmd = run_stub.calls[2][1]
            assert.equal("powershell.exe", cmd[1])
            assert.is_true(
                cmd[4]:find(
                    [[\\wsl.localhost\Ubuntu\tmp\pasted image.png]],
                    1,
                    true
                ) ~= nil
            )
            assert.is_true(cmd[4]:find("/tmp/pasted image.png", 1, true) == nil)
            assert.equal("/tmp/pasted image.png", fs_stat_stub.calls[1][1])
        end)

        local shell_cases = {
            {
                platform = "linux_wayland",
                expected_prefix = "wl-paste --type image/png > ",
            },
            {
                platform = "linux_x11",
                expected_prefix = "xclip -selection clipboard -t image/png -o > ",
            },
        }

        for _, case in ipairs(shell_cases) do
            it(
                case.platform .. " uses shell string with escaped path",
                function()
                    force_platform(case.platform)
                    shellescape_stub:invokes(function(p)
                        return "SHELL_ESCAPED:" .. p
                    end)
                    run_stub:invokes(function()
                        return true, ""
                    end)

                    local path = "/tmp/img with ' quote.png"
                    local ok = ClipboardImage.save(path)
                    assert.is_true(ok)
                    local cmd = run_stub.calls[1][1]
                    assert.equal("string", type(cmd))
                    assert.equal(
                        case.expected_prefix .. "SHELL_ESCAPED:" .. path,
                        cmd
                    )
                end
            )
        end

        local empty_file_cases = {
            { name = "zero bytes", stat = { size = 0, type = "file" } },
            { name = "fs_stat returns nil", stat = nil },
        }

        for _, case in ipairs(empty_file_cases) do
            it("returns (false, empty-file) when " .. case.name, function()
                force_platform("linux_x11")
                run_stub:invokes(function()
                    return true, ""
                end)
                fs_stat_stub:returns(case.stat)

                local ok, err = ClipboardImage.save("/tmp/img.png")
                assert.is_false(ok)
                assert.is_not_nil(err)
                if case.stat then
                    assert.is_true(
                        err ~= nil and err:find("empty", 1, true) ~= nil
                    )
                end
            end)
        end

        it(
            "unknown platform returns (false, unsupported) without _run",
            function()
                force_platform("unknown")

                local ok, err = ClipboardImage.save("/tmp/img.png")
                assert.is_false(ok)
                assert.equal("unsupported platform", err)
                assert.equal(0, run_stub.call_count)
            end
        )
    end)
end)
