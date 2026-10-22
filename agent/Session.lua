local serialization = require("serialization")
local fs = require("filesystem")

local sessions_path = os.getenv("AGENT") .. "/sessions/"

local display = {}
display.write_reasoning_content = io.write
display.write_content = io.write
display.write_tool_call_arguments = io.write
display.write_tool_call_result = io.write
display.write_user_input = io.write
function display.title_reasoning_content()
    io.write("\n\27[33m<thinking>\27[0m\n")
end
function display.title_content()
    io.write("\n\27[35m<deepseek>\27[0m\n")
end
function display.title_tool_call_arguments(name)
    io.write("\n\27[33m<tool-call>\27[0m\n")
    if name and name ~= "" then
        io.write(name .. ": ")
    end
end
function display.title_tool_call_result(name)
    io.write("\n\27[32m<" .. name .. ">\27[0m\n")
end
function display.title_user_input()
    io.write("\27[36m<user>\27[0m\n")
end

local Session = {}
Session.__index = Session

local function new(filename)
    local self = setmetatable({}, Session)
    self.display = display
    if filename then
        self.title = filename
        self.filename = sessions_path .. filename .. ".txt"
        local f = io.open(self.filename, "r")
        if not f then return end
        self.messages = load("return {" .. f:read("*a") .. "}")()
        f:close()
        local index
        for i = #self.messages, 1, -1 do
            if self.messages[i].role == "assistant" then
                index = i
                break
            end
        end
        if index and self.messages[index].tool_calls then
            for i, tool_call in ipairs(self.messages[index].tool_calls) do
                if not self.messages[index+i] then
                    self:append({ role = "tool", tool_call_id = tool_call.id, content = "Error: computer shutdown" })
                end
            end
        end
    else
        self.messages = dofile(os.getenv("AGENT") .. "/prompts/init.lua")
    end
    return self
end
setmetatable(Session, { __call = function(_, ...) return new(...) end })

local function getTitle(message)
    local ai, JSON = require("agent.ai"), require("JSON")
    local payload = JSON:encode({
        model = ai.MODEL,
        messages = {{
            role = "user",
            content = "Generate the session title from this message, your answer should be only the title:\n" .. JSON:encode(message)
        }},
        reasoning_effort = "none",
    })
    local reply, request = "", ai.request(payload)
    while true do
        local data = request.read()
        if not data then
            break
        end
        reply = reply .. data
        os.sleep(0)
    end
    local content = JSON:decode(reply).choices[1].message.content
    local title = content:gsub("\n", " "):gsub("\r", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if #title > 50 then
        title = title:sub(1, 50)
    end
    if fs.exists(sessions_path .. title .. ".txt") then
        for i = 1, math.huge do
            if not fs.exists(sessions_path .. title .. " (" .. tostring(i) .. ").txt") then
                title = title .. " (" .. tostring(i) .. ")"
                break
            end
        end
    end
    return title
end

function Session:append(message)
    table.insert(self.messages, message)
    if self.filename then
        local f = assert(io.open(self.filename, "a"))
        f:write(serialization.serialize(message) .. ",\n")
        f:close()
    end
end

function Session:append_user_input()
    self.display.title_user_input()
    local suc, input = pcall(io.read)
    if suc and type(input) == "string" then
        input = input:gsub("^%s+", ""):gsub("%s+$", "")
    else
        return false
    end
    if input == "" then
        return false
    end
    local message = { role = "user", content = input }
    if not self.filename then
        self.title = getTitle(message)
        self.filename = sessions_path .. self.title .. ".txt"
        local f = assert(io.open(self.filename, "a"))
        for _, msg in ipairs(self.messages) do
            f:write(serialization.serialize(msg) .. ",\n")
        end
        f:close()
    end
    self:append(message)
    return true
end

return Session