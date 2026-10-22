local messages = {}

local prompts_path = os.getenv("AGENT") .. "/prompts/"

-- system
local f = assert(io.open(prompts_path .. "system.txt", "r"))
local prompt = f:read("*a")
f:close()
prompt = prompt:gsub("$[[MODEL]]", require("agent.ai").MODEL)
local w, h = require("tty").gpu().getResolution()
prompt = prompt:gsub("$[[RESOLUTION]]", tostring(w) .. "x" .. tostring(h))
table.insert(messages, { role = "system", content = prompt })

-- shell
f = assert(io.open(prompts_path .. "shell.txt", "r"))
prompt = f:read("*a")
f:close()
table.insert(messages, { role = "user", content = "SYSTEM: " .. prompt })

return messages