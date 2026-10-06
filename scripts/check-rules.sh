#!/bin/sh
# Mechanical checks for rules in AGENTS.md / tests/AGENTS.md.
# Exit 1 with file:line output on any violation. POSIX sh, grep -E, awk only.
# Usage: scripts/check-rules.sh            check the repo
#        scripts/check-rules.sh --self-test prove each check still fires

set -u

# One rule per line: name<TAB>ERE pattern<TAB>path to skip (ERE, may be empty)
BANNED=$(printf '%s\t%s\t%s\n' \
    'vim.notify -> Logger.notify' 'vim\.notify\(' 'utils/logger\.lua$' \
    'vim.fn.bufwinid -> BufHelpers.find_visible_win' 'vim\.fn\.bufwinid' '' \
    'nvim_win_set_width/height -> BufHelpers.win_set_width/height' 'nvim_win_set_(width|height)' 'utils/buf_helpers\.lua$' \
    'vim.keymap.set/del -> BufHelpers.keymap_set/del' 'vim\.keymap\.(set|del)\(' 'utils/buf_helpers\.lua$' \
    'vim.wo[winid].opt = -> vim.wo[winid][0].opt =' 'vim\.wo\[[^]]+\]\.[a-z_]+[[:space:]]*=[^=]' '' \
    'table.pack/table.unpack (Lua 5.1)' '(^|[^A-Za-z0-9_.])table\.(un)?pack([^A-Za-z0-9_]|$)' '')
TAB=$(printf '\t')

# Prints "file:line:text" for code lines (not comments) matching ERE $1.
code_matches() {
    pattern=$1
    shift
    grep -nHE -- "$pattern" "$@" 2>/dev/null | awk '{
        text = $0; sub(/^[^:]*:[^:]*:/, "", text)
        if (text !~ /^[ \t]*--/) print
    }'
}

# $1: production Lua files (one per line). Prints violations.
check_banned() {
    files=$1
    printf '%s\n' "$BANNED" | while IFS=$TAB read -r name pattern skip; do
        targets=$files
        if [ -n "$skip" ]; then
            targets=$(printf '%s\n' "$files" | grep -vE "$skip")
        fi
        [ -z "$targets" ] && continue
        # shellcheck disable=SC2086
        hits=$(code_matches "$pattern" $targets)
        [ -n "$hits" ] && printf 'banned call: %s\n%s\n' "$name" "$hits"
    done
}

# $@: test files. Prints each `assert.`, `assert(`, `expect.` or
# `MiniTest.expect.` line that sits between a `vim.schedule(function(...)` /
# `vim.defer_fn(function(...)` opener and the first `end)` / `end,` after it.
# A nested `function ... end)` closes the block early, so this misses some
# cases; the runtime guard catches those.
check_async() {
    [ $# -eq 0 ] && return 0
    hits=$(awk '
        FNR == 1 { inblk = 0 }
        {
            line = $0
            if (!inblk) {
                if (!match(line, /vim\.(schedule|defer_fn)\([ \t]*function[ \t]*\([^)]*\)/)) next
                inblk = 1
                line = substr(line, RSTART + RLENGTH)
            }
            epos = match(line, /(^|[^A-Za-z0-9_])end[ \t]*[,)]/) ? RSTART : 0
            apos = match(line, /(^|[^A-Za-z0-9_.])(assert[.(]|expect\.|MiniTest\.expect\.)/) ? RSTART : 0
            if (apos && (!epos || apos < epos)) {
                print FILENAME ":" FNR ":" $0
                inblk = 0
            } else if (epos) {
                inblk = 0
            }
        }
    ' "$@" | head -n 50)
    [ -n "$hits" ] && printf 'assert inside a deferred callback (tests/AGENTS.md):\n%s\n' "$hits"
}

self_test() {
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    cat >"$dir/bad.lua" <<'EOF'
vim.notify("x")
local w = vim.fn.bufwinid(0)
vim.api.nvim_win_set_width(0, 1)
vim.keymap.set("n", "x", "y")
vim.wo[w].wrap = false
local t = table.pack(1)
-- vim.notify("in a comment is fine")
EOF
    cat >"$dir/bad.test.lua" <<'EOF'
it("a", function()
    vim.schedule(function()
        if x then
            y()
        end
        assert.equal(1, 2)
    end)
end)
it("b", function()
    vim.defer_fn(function() assert.is_true(done) end, 10)
end)
it("e", function()
    vim.schedule(function()
        MiniTest.expect.equality(1, 2)
    end)
end)
it("f", function()
    vim.schedule(function()
        assert(done)
    end)
end)
EOF
    cat >"$dir/good.test.lua" <<'EOF'
it("c", function()
    vim.defer_fn(function() done = true end, 10)
    assert.is_true(done)
end)
it("d", function()
    vim.schedule(function()
        done = true
    end)
    assert.is_true(done)
end)
EOF
    banned=$(check_banned "$dir/bad.lua" | grep -c '^banned call:')
    async_bad=$(check_async "$dir/bad.test.lua" | grep -c 'bad.test.lua:')
    async_good=$(check_async "$dir/good.test.lua")
    ok=0
    [ "$banned" = "6" ] || { echo "self-test: expected 6 banned hits, got $banned"; ok=1; }
    [ "$async_bad" = "4" ] || { echo "self-test: expected 4 async hits, got $async_bad"; ok=1; }
    [ -z "$async_good" ] || { echo "self-test: async check flagged a valid test: $async_good"; ok=1; }
    [ $ok -eq 0 ] && echo "self-test: ok"
    return $ok
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit $?
fi

status=0
all=$(git ls-files --cached --others --exclude-standard -- '*.lua')

prod=$(printf '%s\n' "$all" | grep -E '^(lua/|tests/mocks/)' | grep -vE '\.test\.lua$')
out=$(check_banned "$prod")
[ -n "$out" ] && { echo "$out"; status=1; }

tests=$(printf '%s\n' "$all" | grep -E '(^lua/.*\.test\.lua$|^tests/)' | grep -vE '^tests/(mocks|fixtures)/')
# shellcheck disable=SC2086
out=$(check_async $tests)
[ -n "$out" ] && { echo "$out"; status=1; }

if git ls-files --error-unmatch rules-report.md >/dev/null 2>&1; then
    echo "rules-report.md is committed. It is local-only (root AGENTS.md)."
    status=1
fi

exit $status
