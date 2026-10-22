local registerTool = ...

local stream_capture = require("agent.lib.stream_capture")

local function optrequire(...)
    local success, module = pcall(require, ...)
    if success then
        return module
    end
end

local env = setmetatable({}, {
    __index = function(_, key)
        _ENV[key] = _ENV[key] or optrequire(key)
        return _ENV[key]
    end
})

-- Evaluate a Lua expression/statement and serialize its return values. This is
-- the lua_shell equivalent of shell.execute: it reports success/failure and
-- leaves stdout/stderr capture to the shared stream harness.
local function run(command)
    local code, reason
    if string.sub(command, 1, 1) == "=" then
        code, reason = load("return " .. string.sub(command, 2), "=lua_shell", "t", env)
    else
        code, reason = load("return " .. command, "=lua_shell", "t", env)
        if not code then
            code, reason = load(command, "=lua_shell", "t", env)
        end
    end

    if not code then
        io.stderr:write(tostring(reason) .. "\n")
        return false, reason
    end

    local result = table.pack(xpcall(code, debug.traceback))
    if not result[1] then
        local failure = result[2]
        local reason_text
        if type(failure) == "table" and failure.reason == "terminated" then
            reason_text = "terminated (exit code " .. tostring(failure.code) .. ")"
            io.write("[terminated, exit code: " .. tostring(failure.code) .. "]\n")
        else
            reason_text = tostring(failure)
        end
        io.stderr:write(reason_text .. "\n")
        return false, reason_text
    end

    local ok, why = pcall(function()
        for index = 2, result.n do
            io.write(require("serialization").serialize(result[index], 2000), index < result.n and "\t" or "\n")
        end
    end)
    if not ok then
        local reason_text = "crashed serializing result: " .. tostring(why)
        io.stderr:write(reason_text)
        return false, reason_text
    end

    return true
end

local function execute(parameters)
    assert(type(parameters.command) == "string",
        "bad argument #command (string expected, got " .. type(parameters.command) .. ")")
    assert(parameters.command:match("%S"), "command must be a non-empty string")

    local capture = stream_capture.run(function()
        return run(parameters.command)
    end, parameters.timeoutSec)

    local output = capture.stdout
    if #capture.stderr > 0 then
        output = stream_capture.append_block(output, "[stderr]\n" .. capture.stderr)
    end

    if not capture.finished then
        return stream_capture.append_block(output, "[exit reason: time out]")
    end

    local worker_result = capture.result
    if not worker_result then
        return stream_capture.append_block(output, "[execute failed]")
    end
    if not worker_result[1] then
        return stream_capture.append_block(output, "[execute failed: " .. tostring(worker_result[2]) .. "]")
    end

    local command_ok = worker_result[2]
    local reason = worker_result[3]
    if command_ok == true then
        return output
    end

    local message = "[execute failed]"
    if #capture.stderr == 0 and reason ~= nil then
        message = message .. ": " .. tostring(reason)
    end
    return stream_capture.append_block(output, message)
end

local info = {
    type = "function",
    ["function"] = {
        name = "lua_shell",
        description = "Evaluate a Lua expression or statement in the agent's Lua environment, "
            .. "its serialized result will be written to stdout, and return its stdout/stderr"
            .. "Failure, timeout, and truncation markers are appended; output is capped at "
            .. stream_capture.MAX_OUTPUT_KIB .. " KiB per stream. The timeout is cooperative.",
        parameters = {
            type = "object",
            properties = {
                command = { type = "string", description = "Lua expression or statement to evaluate. Prefix with = to force expression mode." },
                timeoutSec = { type = "number", description = "Maximum seconds to wait before the tool stops waiting for the command. Defaults to " .. stream_capture.DEFAULT_TIMEOUT_SEC .. "." }
            },
            required = { "command" }
        }
    }
}

registerTool(info, execute)
