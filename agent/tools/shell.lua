local registerTool = ...

local shell = require("shell")
local sh = require("sh")
local stream_capture = require("agent.lib.stream_capture")

local DEFAULT_TIMEOUT_SEC = stream_capture.DEFAULT_TIMEOUT_SEC
local MAX_OUTPUT_KIB = stream_capture.MAX_OUTPUT_KIB

local function execute(parameters)
    assert(type(parameters.command) == "string",
        "bad argument #command (string expected, got " .. type(parameters.command) .. ")")
    assert(parameters.command:match("%S"), "command must be a non-empty string")

    -- Run shell.execute as the captured worker; keep its result and OpenOS
    -- last exit code so this tool can report command failures.
    local capture = stream_capture.run(function()
        local packed = table.pack(pcall(shell.execute, parameters.command))
        local code_ok, exit_code = pcall(sh.getLastExitCode)
        return packed, code_ok and exit_code or nil
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

    local packed = worker_result[2]
    local exit_code = worker_result[3]
    if not packed then
        return stream_capture.append_block(output, "[execute failed]")
    end
    if not packed[1] then
        return stream_capture.append_block(output, "[execute failed: " .. tostring(packed[2]) .. "]")
    end

    local command_ok = packed[2]
    local reason = packed[3]
    if command_ok == true or command_ok == 0 then
        return output
    end

    local message = "[execute failed]"
    if reason ~= nil then
        message = message .. ": " .. tostring(reason)
    elseif type(command_ok) == "number" and command_ok ~= 0 then
        message = message .. "\n[exit code: " .. tostring(command_ok) .. "]"
    elseif exit_code and exit_code ~= 0 then
        message = message .. "\n[exit code: " .. tostring(exit_code) .. "]"
    end
    return stream_capture.append_block(output, message)
end

local info = {
    type = "function",
    ["function"] = {
        name = "shell",
        description = "Execute a non-interactive OpenOS shell command and return its stdout/stderr. "
            .. "Failure, timeout, and truncation markers are appended; output is capped at "
            .. MAX_OUTPUT_KIB .. " KiB per stream. The timeout is cooperative.",
        parameters = {
            type = "object",
            properties = {
                command = { type = "string", description = "Shell command to execute." },
                timeoutSec = { type = "number", description = "Maximum seconds to wait before the tool stops waiting for the command. Defaults to " .. DEFAULT_TIMEOUT_SEC .. "." }
            },
            required = { "command" }
        }
    }
}

registerTool(info, execute)
