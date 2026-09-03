-- Noctty cmd.exe shell integration for Clink.
-- PROMPT supplies OSC 133 A/B and OSC 9;9; this adds C/D with exit status.

local ESC = string.char(27)
local BEL = string.char(7)
local state_key = "__noctty_cmd_shell_integration"
local state = rawget(_G, state_key)

if not state then
    state = { command_pending = false, registered = false }
    rawset(_G, state_key, state)
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
