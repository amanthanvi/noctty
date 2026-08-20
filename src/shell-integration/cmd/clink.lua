-- Winghostty cmd.exe shell integration for Clink.
-- Emits OSC 133 C (command start) and D (command end + exit code).
-- A/B and OSC 9;9 cwd stay on PROMPT so they work without Clink.

local ESC = string.char(27)
local BEL = string.char(7)

local function osc(body)
    io.write(ESC .. "]" .. body .. BEL)
end

if clink.onbeginedit then
    clink.onbeginedit(function()
        osc("133;C")
    end)
end

if clink.promptfilter then
    local filter = clink.promptfilter(1)
    function filter:filter(prompt)
        local code = os.geterrorlevel and os.geterrorlevel() or 0
        osc("133;D;" .. tostring(code))
        return prompt
    end
end
