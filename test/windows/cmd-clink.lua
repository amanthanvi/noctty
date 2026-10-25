-- Runs inside a real injected portable Clink, not a stub of its filter engine.
local ESC, BEL = string.char(27), string.char(7)
local output = assert(os.getenv("NOCTTY_CLINK_RESULTS"))
local results, failures, marks = {}, 0, {}
local function check(value, name)
    results[#results + 1] = (value and "PASS " or "FAIL ") .. name
    if not value then failures = failures + 1 end
end
local function count(s, needle)
    local n, at = 0, 1
    while true do
        local found = s:find(needle, at, true)
        if not found then return n end
        n, at = n + 1, found + #needle
    end
end
local print_original = clink.print
clink.print = function(text, ...)
    if type(text) == "string" and text:find(ESC .. "]133;", 1, true) then
        marks[#marks + 1] = text
    end
    return print_original(text, ...)
end

local theme_mode = "pass"
-- The resize step: a theme whose ruler follows the width, as themes that ask
-- for clink.refilterafterterminalresize() do. Every width the filter was run
-- at, and every final prompt it produced, is kept for the checks.
local resize = { widths = {}, prompts = {} }
local theme = clink.promptfilter(5)
function theme:filter(prompt)
    if theme_mode == "replace" then return "TOP\nTHEME> ", false end
    if theme_mode == "owned" then
        return ESC .. "]133;A" .. BEL .. "USER> " .. ESC .. "]133;B" .. BEL, false
    end
    if theme_mode == "resize" then
        local width = console.getwidth()
        resize.widths[#resize.widths + 1] = width
        return string.rep("=", math.max(1, width - 10)) .. "\nRESIZE " .. width .. "> ", false
    end
    return prompt
end
function theme:transientfilter() return "TRANSIENT> ", false end
local refilter_api = clink.refilterafterterminalresize ~= nil
if refilter_api then clink.refilterafterterminalresize(true) end

local function touch(path, text)
    local file = assert(io.open(assert(path, "handshake path not set"), "w"))
    file:write(text)
    file:close()
end

-- Rows of the visible window that contain `needle`. Lines are 1 to
-- console.getnumlines(); past that, getlinetext repeats the last one.
local function visible_rows(needle)
    local n, top = 0, console.gettop()
    for line = top, math.min(top + console.getheight() - 1, console.getnumlines()) do
        local text = console.getlinetext(line)
        if text and text:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

-- Runs while Clink waits at the resize step's prompt. The harness resizes the
-- window once the ready file exists, and presses Enter once the done file
-- exists. A width change makes Clink redraw its prompt and line at once and,
-- 1.5 s after the size settles, run the prompt filters again.
local function resize_wait()
    local before = console.getwidth()
    touch(assert(os.getenv("NOCTTY_CLINK_RESIZE_READY")), tostring(before))
    local deadline = os.time() + 20
    while console.getwidth() == before and os.time() < deadline do os.sleep(0.05) end
    local after = console.getwidth()
    check(after ~= before, "the harness resized the terminal at the prompt")
    local function refiltered()
        for _, width in ipairs(resize.widths) do
            if width == after then return true end
        end
        return false
    end
    while not refiltered() and os.time() < deadline do os.sleep(0.05) end
    -- Let the refiltered prompt reach the screen.
    os.sleep(0.5)
    check(refilter_api and refiltered(),
        "clink.refilterafterterminalresize reran the prompt filters at the new width")
    local last = resize.prompts[#resize.prompts] or ""
    check(count(last, ESC .. "]133;A") == 1 and count(last, ESC .. "]133;B") == 1 and
        count(last, ESC .. "]9;9;") == 1 and last:find("RESIZE " .. after .. "> ", 1, true) ~= nil,
        "refiltered prompt after a resize has one A/B/cwd")
    -- console.getlinetext strips trailing blanks, so no space after the `>`.
    local new_rows = visible_rows("RESIZE " .. after .. ">")
    local old_rows = visible_rows("RESIZE " .. before .. ">")
    check(new_rows == 1 and old_rows == 0, "resized prompt shown once, without the old one" ..
        ((new_rows == 1 and old_rows == 0) and "" or (": new " .. new_rows .. ", old " .. old_rows)))
    resize.finished = true
    touch(assert(os.getenv("NOCTTY_CLINK_RESIZE_DONE")), "done")
end

local tested = false
local function prompt_checks()
    check(rawget(_G, "__noctty_cmd_shell_integration") ~= nil,
        "unique script name loaded alongside Clink's own clink.lua")
    local internal = clink._internal
    local owned = ESC .. "]133;A;redraw=0" .. BEL .. "BODY> " .. ESC .. "]133;B" .. BEL
    local value, right, ok = internal._filter_prompt(owned, "RIGHT> ")
    check(value == owned and right == "RIGHT> " and ok == true,
        "existing marks and right prompt preserved")
    local before = internal._filter_prompt
    if rawget(_G, "__noctty_cmd_shell_integration") then
        dofile(assert(os.getenv("NOCTTY_CLINK_SCRIPT")))
    end
    check(before == internal._filter_prompt, "reloading script registers no second wrapper")
    for _, integration in ipairs({"off", "on"}) do
        settings.set("terminal.shell_integration", integration)
        theme_mode = "replace"
        value, right, ok = internal._filter_prompt(owned, "RIGHT> ")
        check(count(value, ESC .. "]133;A") == 1 and count(value, ESC .. "]133;B") == 1 and
            count(value, ESC .. "]9;9;") == 1 and value:find("THEME> ", 1, true) ~= nil and
            right == "RIGHT> " and ok == true,
            "replacing stopping theme has one A/B/cwd with Clink integration " .. integration)
        if integration == "off" then
            check(value:find("redraw=0", 1, true) ~= nil and
                value:find("kitty-shell-cwd://localhost/" .. os.getcwd(), 1, true) ~= nil and
                value:find(ESC .. "]133;A", 1, true) < value:find("TOP", 1, true) and
                value:sub(-8) == ESC .. "]133;B" .. BEL,
                "whole multiline normal prompt wrapped with raw Windows cwd and B at end")
        end
        theme_mode = "owned"
        value = internal._filter_prompt(owned, "")
        check(count(value, ESC .. "]133;A") == 1 and value:find("USER> ", 1, true) ~= nil,
            "theme-owned marks respected with Clink integration " .. integration)
    end
    settings.set("terminal.shell_integration", "off")
    value = internal._filter_transient_prompt("OLD> ", "", "echo x", 7, true)
    check(value == "TRANSIENT> ", "transient redraw has no new normal-prompt marks")
    theme_mode = "pass"
    local state = rawget(_G, "__noctty_cmd_shell_integration")
    if state then
        local saved = internal._filter_prompt
        local function reload_with(func)
            internal._filter_prompt = func
            state.prompt_registered = false
            dofile(assert(os.getenv("NOCTTY_CLINK_SCRIPT")))
        end
        reload_with(function() return nil, "RIGHT", false end)
        local p, r, success = internal._filter_prompt()
        check(p == nil and r == "RIGHT" and success == false,
            "nil and unsuccessful filter returns preserved")
        reload_with(function() return "ERROR PROMPT", nil, false end)
        p, r, success = internal._filter_prompt()
        check(p == "ERROR PROMPT" and r == nil and success == false,
            "error prompt is not wrapped")
        reload_with(function() error("fixture-filter-error") end)
        local called, err = pcall(internal._filter_prompt)
        check(not called and tostring(err):find("fixture-filter-error", 1, true) ~= nil,
            "filter exceptions propagate")
        reload_with(nil)
        check(internal._filter_prompt == nil and not state.prompt_registered,
            "missing private API keeps fallback without installing hook")
        internal._filter_prompt, state.prompt_registered = saved, true
    end
end

local step = 0
clink.onbeginedit(function()
    if not tested then
        tested = true
        local ok, err = pcall(prompt_checks)
        check(ok, "prompt checks complete" .. (ok and "" or ": " .. tostring(err)))
        -- Outermost, so it sees the prompt as Clink displays it.
        local internal = clink._internal
        if internal and type(internal._filter_prompt) == "function" then
            local final = internal._filter_prompt
            internal._filter_prompt = function(...)
                local prompt, rprompt, success = final(...)
                if theme_mode == "resize" and type(prompt) == "string" then
                    resize.prompts[#resize.prompts + 1] = prompt
                end
                return prompt, rprompt, success
            end
        end
    end
end)
clink.onprovideline(function()
    step = step + 1
    if step == 1 then return "echo noctty-clink-smoke & ping -n 3 127.0.0.1 >nul" end
    if step == 2 then
        theme_mode = "resize"
        return "cmd /d /c exit 3"
    end
    if step == 3 then
        -- Wait at a real prompt; the harness resizes, then presses Enter.
        coroutine.create(function()
            local ok, err = pcall(resize_wait)
            if not ok then
                check(false, "resize step: " .. tostring(err))
                -- Both, so the harness moves on whichever step failed.
                pcall(touch, os.getenv("NOCTTY_CLINK_RESIZE_READY"), "error")
                pcall(touch, os.getenv("NOCTTY_CLINK_RESIZE_DONE"), "error")
            end
        end)
        return nil
    end
    theme_mode = "pass"
    check(resize.finished == true, "resize step finished before the line was accepted")
    local all = table.concat(marks)
    check(count(all, ESC .. "]133;C") == 2, "real command input emits C exactly twice")
    check(all:find(ESC .. "]133;D;0" .. BEL, 1, true) ~= nil,
        "real successful command emits D;0")
    check(all:find(ESC .. "]133;D;3" .. BEL, 1, true) ~= nil,
        "real failing command emits D;3")
    local file = assert(io.open(output, "w"))
    file:write(table.concat(results, "\n"), "\n", failures == 0 and "PASS ALL\n" or "FAIL ALL\n")
    file:close()
    return "exit"
end)
