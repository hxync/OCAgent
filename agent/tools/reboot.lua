local registerTool = ...

local computer = require("computer")

local BOOT_PATH = "/boot/77_agent.lua"

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function make_boot_script(command)
    -- The command is embedded as a Lua string literal so a session title can
    -- never terminate the outer long bracket or inject boot-script source.
    return table.concat({
        'local event = require("event")',
        'event.listen("init", function()',
        '    event.timer(2, function()',
        '        event.push(',
        '            "clipboard",',
        '            require("tty").keyboard(),',
        '            ' .. string.format("%q", command),
        '        )',
        '    end, 1)',
        '    return false',
        'end)',
        '',
    }, "\n")
end

local function reboot(parameters, session)
    assert(type(session) == "table", "reboot requires the active session")
    assert(type(session.title) == "string" and session.title ~= "",
        "reboot requires a session title")

    local title = session.title:gsub("[\r\n]", " "):gsub("%z", "")
    if not title:match("%S") then
        error("reboot requires a non-empty session title", 0)
    end
    -- OpenOS command substitution scans backticks before quote handling.
    if title:find("`", 1, true) then
        error("reboot cannot resume a session title containing a backtick", 0)
    end

    local agent_root = os.getenv("AGENT")
    assert(type(agent_root) == "string" and agent_root ~= "",
        "AGENT environment variable is not set")
    agent_root = agent_root:gsub("/+$", "")

    local command = "rm " .. BOOT_PATH .. "; "
        .. shell_quote(agent_root .. "/init.lua") .. " "
        .. shell_quote(title) .. " --resume\n"

    local file, reason = io.open(BOOT_PATH, "w")
    if not file then
        error("cannot write " .. BOOT_PATH .. ": " .. tostring(reason), 0)
    end
    local ok, write_reason = file:write(make_boot_script(command))
    if not ok then
        file:close()
        error("cannot write " .. BOOT_PATH .. ": " .. tostring(write_reason), 0)
    end
    local closed, close_reason = file:close()
    if closed == nil and close_reason then
        error("cannot write " .. BOOT_PATH .. ": " .. tostring(close_reason), 0)
    end

    computer.shutdown(true) -- 传递 true 参数表示重启
    return "Reboot failed"
end

local info = {
    type = "function",
    ["function"] = {
        name = "reboot",
        description = "Reboot the computer and automatically resume the current agent session after boot. "
            .. "Use this tool ONLY when the runtime environment has been polluted or corrupted "
            .. "and an in-process recovery is not safe or possible.",
        parameters = {
            type = "object",
            properties = require("JSON"):newObject({}) -- 空表会被编码成JSON数组，需要创建一个空对象
        }
    }
}

if require("filesystem").exists("/etc/api_key") then
    registerTool(info, reboot)
end

