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
local theme = clink.promptfilter(5)
function theme:filter(prompt)
    if theme_mode == "replace" then return "TOP\nTHEME> ", false end
    if theme_mode == "owned" then
        return ESC .. "]133;A" .. BEL .. "USER> " .. ESC .. "]133;B" .. BEL, false
    end
    return prompt
end
function theme:transientfilter() return "TRANSIENT> ", false end

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
    end
end)
clink.onprovideline(function()
    step = step + 1
    if step == 1 then return "echo noctty-clink-smoke & ping -n 3 127.0.0.1 >nul" end
    if step == 2 then return "cmd /d /c exit 3" end
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
