-- Noctty cmd.exe shell integration for Clink.
-- PROMPT supplies OSC 133 A/B and OSC 9;9; this adds C/D with exit status.

local ESC = string.char(27)
local BEL = string.char(7)
local command_pending = false

local function emit(body)
    clink.print(ESC .. "]" .. body .. BEL, NONL)
end

if clink.onfilterinput and clink.onbeginedit and clink.print and
    os.geterrorlevel and NONL then
    clink.onfilterinput(function(line)
        if line and line:match("%S") then
            command_pending = true
            emit("133;C")
        end
    end)

    clink.onbeginedit(function()
        if not command_pending then
            return
        end

        local exit_code = os.geterrorlevel()
        command_pending = false
        emit("133;D;" .. tostring(exit_code))
    end)
end
