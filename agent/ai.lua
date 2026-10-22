local event = require("event")
local JSON = require("JSON")

local BASE_URL = "https://api.deepseek.com"
local MODEL = "deepseek-v4-flash"

local interrupted = false
local function interrupt()
    interrupted = true
    event.ignore("interrupted", interrupt)
end

local request
do
    local component = require("component")
    local func = component.proxy(component.list("internet")()).request
    local api_key
    local f = io.open("/etc/api_key", "r") -- tools/reboot.lua 也使用了该地址，修改需要同步
    if f then
        local key = (f:read("*a") or ""):gsub("^%s+", ""):gsub("%s+$", "")
        f:close()
        if key ~= "" then
            api_key = key
        end
    end
    if not api_key then
        io.write("Paste your API key: ")
        local _, _, value = event.pull("clipboard")
        assert(type(value) == "string" and value ~= "", "no API key provided")
        api_key = value
        io.write(string.rep("*", #value) .. "\n")
    end
    local URL = BASE_URL .. "/chat/completions"
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
    }
    request = function(data)
        local res, reason = func(URL, data, headers, "POST")
        if res then
            return res
        else
            error("request failed: " .. reason)
        end
    end
end

local function read(response)
    while true do
        local data, reason = response.read()
        if not data then
            return nil, reason
        elseif #data > 0 then
            return data
        end
        os.sleep(0)
        if interrupted then
            return nil
        end
    end
end

local function sse(payload)
    local response = assert(request(payload))
    local buffer = ""
    return function()
        while true do
            local newline = buffer:find("\n", 1, true)

            if newline then
                local line = buffer:sub(1, newline - 1):gsub("\r$", "")
                buffer = buffer:sub(newline + 1)

                local body = line:match("^data:%s?(.*)$")
                if body then
                    body = body:gsub("^%s+", ""):gsub("%s+$", "")
                    if body == "[DONE]" then
                        response.close()
                        return nil
                    elseif body ~= "" then
                        local suc, evnt = pcall(JSON.decode, JSON, body)
                        if suc and type(evnt) == "table" then
                            return evnt
                        end
                    end
                end
            else
                local data, reason = read(response)
                if data then
                    buffer = buffer .. data
                else
                    response.close()
                    if reason then
                        error(reason)
                    end
                    return nil
                end
            end

        end
    end
end

local ai = {}
ai.MODEL = MODEL
ai.request = request

function ai.step(payload, display)
    display = setmetatable(display or {}, { __index = function() return function() end end })
    local message, finish_reason, usage = { role = "assistant", reasoning_content = "" }, "aborted", nil
    for evnt in sse(payload) do
        if evnt.usage then
            usage = evnt.usage
        end

        local choice = evnt.choices[1]
        if choice.finish_reason then
            finish_reason = choice.finish_reason
        end

        local delta = evnt.choices[1].delta

        -- 思考
        if delta.reasoning_content then
            if message.reasoning_content ~= "" then
                message.reasoning_content = message.reasoning_content .. delta.reasoning_content
                display.write_reasoning_content(delta.reasoning_content)
            elseif delta.reasoning_content ~= "" then
                message.reasoning_content = delta.reasoning_content
                display.title_reasoning_content()
                display.write_reasoning_content(delta.reasoning_content)
            end
        end

        -- 回答
        if delta.content and delta.content ~= "" then
            if message.content then
                message.content = message.content .. delta.content
                display.write_content(delta.content)
            else
                message.content = delta.content
                display.title_content()
                display.write_content(delta.content)
            end
        end

        -- 工具调用
        if delta.tool_calls then
            if not message.tool_calls then
                message.tool_calls = {}
            end
            local tool_call = delta.tool_calls[1]
            local index = tool_call.index + 1
            if not message.tool_calls[index] then
                message.tool_calls[index] = { type = "function", ["function"] = { arguments = "" } }
            end
            if tool_call.id then
                message.tool_calls[index].id = tool_call.id
            end
            if tool_call["function"].name then
                message.tool_calls[index]["function"].name = tool_call["function"].name
                display.title_tool_call_arguments(tool_call["function"].name)
            end
            if tool_call["function"].arguments then
                message.tool_calls[index]["function"].arguments = message.tool_calls[index]["function"].arguments .. tool_call["function"].arguments
                display.write_tool_call_arguments(tool_call["function"].arguments)
            end
        end
    end

    return message, finish_reason, usage
end

function ai.steps(session, tools, callbacks)
    interrupted = false
    event.listen("interrupted", interrupt)
    while true do
        local payload = JSON:encode({
            model = MODEL,
            stream = true,
            messages = session.messages,
            tools = tools,
        })
        local message, finish_reason = ai.step(payload, session.display)
        if finish_reason == "tool_calls" and message.tool_calls and #message.tool_calls > 0 then
            session:append(message)
            -- 调用工具
            for i, tool_call in ipairs(message.tool_calls) do
                local tool = { role = "tool", tool_call_id = tool_call.id }
                session.display.title_tool_call_result(tool_call["function"].name)
                local content
                if interrupted then
                    content = "interrupted by user"
                else
                    local suc, arguments = pcall(JSON.decode, JSON, tool_call["function"].arguments)
                    if suc and type(arguments) == "table" then
                        suc, content = pcall(callbacks[tool_call["function"].name], arguments, session)
                    else
                        content = "failed to resolve arguments"
                    end
                    if suc then
                        tool.content = content
                    else
                        tool.content = "Error: " .. content
                    end
                    session.display.write_tool_call_result(tool.content .. "\n")
                end
                session:append(tool)
            end
            if interrupted then
                break
            end
        else
            message.reasoning_content = nil
            message.tool_calls = nil
            if message.content and message.content ~= "" then
                session:append(message)
            elseif interrupted then
                session:append({ role = "user", content = "SYSTEM: interrupted by user" })
            end
            break
        end
    end
    event.ignore("interrupted", interrupt)
    interrupted = false
    session.display.write_content("\n\n")
    return session
end

return ai