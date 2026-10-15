-- Noctty cmd.exe shell integration for Clink.
-- PROMPT supplies the plain-cmd fallback; Clink adds C/D and protects the
-- prompt marks from themes which replace PROMPT and stop the filter chain.

local ESC = string.char(27)
local BEL = string.char(7)
local state_key = "__noctty_cmd_shell_integration"
local state = rawget(_G, state_key)

if not state then
    state = { command_pending = false, registered = false }
    rawset(_G, state_key, state)
end

-- A last-priority promptfilter is skipped when a theme returns `prompt, false`.
-- :surround() runs before that stop, but cannot see the final prompt (including
-- another integration's marks), and Clink's own integration ignores surrounds
-- when checking for duplicate marks. Wrap only the normal final-return seam.
-- This is private Clink API, so older/incompatible versions keep PROMPT and C/D.
-- Do not wrap _filter_transient_prompt: those redraws are not new prompts.
local internal = clink._internal
if internal and type(internal._filter_prompt) == "function" and
    not state.prompt_registered then
    local filter_prompt = internal._filter_prompt
    internal._filter_prompt = function(...)
        local prompt, rprompt, ok = filter_prompt(...)
        if type(prompt) == "string" and ok ~= false and
            not prompt:find(ESC .. "]133;A[;\7\27]") then
            local prefix = ESC .. "[<99u" .. ESC .. "[>4;0m" ..
                ESC .. "]133;A;redraw=0" .. BEL ..
                ESC .. "]9;9;kitty-shell-cwd://localhost/" .. os.getcwd() .. BEL
            prompt = prefix .. prompt .. ESC .. "]133;B" .. BEL
        end
        return prompt, rprompt, ok
    end
    state.prompt_registered = true
end

local function emit(body)
    clink.print(ESC .. "]" .. body .. BEL, NONL)
end

if clink.onfilterinput and clink.onbeginedit and clink.print and
    os.geterrorlevel and NONL and not state.registered then
    clink.onfilterinput(function(line)
        if line and line:match("%S") then
            state.command_pending = true
            emit("133;C")
        end
    end)

    -- Every prompt closes the previous command boundary: `D;<code>` when a
    -- command ran, bare `D` for the first prompt, an empty line, or Ctrl-C.
    clink.onbeginedit(function()
        if state.command_pending then
            emit("133;D;" .. tostring(os.geterrorlevel()))
        else
            emit("133;D")
        end

        state.command_pending = false
    end)

    state.registered = true
end
