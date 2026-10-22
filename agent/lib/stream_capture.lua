-- Capture a worker's stdout/stderr and run it under a cooperative timeout.
-- The caller owns result interpretation; this module only captures streams,
-- enforces the per-stream byte cap, and always restores process IO.

local buffer = require("buffer")
local thread = require("thread")

local stream_capture = {}

stream_capture.DEFAULT_TIMEOUT_SEC = 10
stream_capture.MAX_OUTPUT_KIB = 32
local MAX_OUTPUT_BYTES = stream_capture.MAX_OUTPUT_KIB * 1024

local function create_output_stream(output)
    local size = 0
    local truncated = false
    return {
        write = function(_, value)
            if truncated then
                return true
            end
            local remaining = MAX_OUTPUT_BYTES - size
            if remaining <= 0 then
                truncated = true
                output[#output + 1] = "\n[output truncated]"
                return true
            end
            if #value > remaining then
                output[#output + 1] = value:sub(1, remaining)
                output[#output + 1] = "\n[output truncated]"
                size = size + remaining
                truncated = true
            else
                output[#output + 1] = value
                size = size + #value
            end
            return true
        end,
        close = function()
            return true
        end,
        seek = function()
            return 0
        end,
    }
end

local function create_empty_input()
    return buffer.new("r", {
        read = function()
            return nil
        end,
        close = function()
            return true
        end,
        seek = function()
            return 0
        end,
        write = function()
            return true
        end,
    })
end

local function normalize_timeout(value)
    if value == nil then
        return stream_capture.DEFAULT_TIMEOUT_SEC
    end
    assert(type(value) == "number",
        "bad argument #timeoutSec (number expected, got " .. type(value) .. ")")
    assert(value > 0 and value < math.huge and value == value,
        "timeoutSec must be a positive finite number")
    return value
end

function stream_capture.append_block(text, block)
    if #text > 0 and text:sub(-1) ~= "\n" then
        text = text .. "\n"
    end
    return text .. block
end

function stream_capture.run(worker, timeout_sec)
    assert(type(worker) == "function",
        "bad argument #1 (function expected, got " .. type(worker) .. ")")
    timeout_sec = normalize_timeout(timeout_sec)

    local stdout = {}
    local stderr = {}
    local stdout_stream = buffer.new("w", create_output_stream(stdout))
    local stderr_stream = buffer.new("w", create_output_stream(stderr))
    local stdin_stream = create_empty_input()

    stdout_stream:setvbuf("no")
    stderr_stream:setvbuf("no")

    local old_stdout = io.output()
    local old_stderr = io.error()
    local old_stdin = io.input()

    local result
    local finished = false

    local ok, failure = pcall(function()
        io.output(stdout_stream)
        io.error(stderr_stream)
        io.input(stdin_stream)

        local worker_thread = thread.create(function()
            result = table.pack(pcall(worker))
        end)

        finished = worker_thread:join(timeout_sec) == true
    end)

    pcall(function()
        stdout_stream:flush()
    end)
    pcall(function()
        stderr_stream:flush()
    end)
    io.output(old_stdout)
    io.error(old_stderr)
    io.input(old_stdin)
    pcall(function()
        stdout_stream:close()
    end)
    pcall(function()
        stderr_stream:close()
    end)
    pcall(function()
        stdin_stream:close()
    end)

    if not ok then
        error(tostring(failure), 0)
    end

    return {
        stdout = table.concat(stdout),
        stderr = table.concat(stderr),
        finished = finished,
        result = result,
    }
end

return stream_capture
