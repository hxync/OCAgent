-- OCAgent $[[VERSION]], by hxync
do
    local path = "$[[INSTALL_PATH]]"
    local package = require("package")
    if not package.path:find(path, 1, true) then
        package.path = package.path .. ";" .. path .. "?.lua"
    end
    if os.getenv("AGENT") ~= path .. "agent" then
        os.setenv("AGENT", path .. "agent")
    end
end

do
    local internet = require("internet")
    local download = function(url)
        local handle = internet.request(url)
        local result = ""
        for chunk in handle do
            result = result..chunk
        end
        return result
    end
    local suc, test = pcall(download, "http://www.msftconnecttest.com/connecttest.txt")
    if suc and test == "Microsoft Connect Test" then
        local repo = "$[[REPO]]$[[BRANCH]]/"
        local version = download(repo .. "VERSION")
        if version ~= "$[[VERSION]]" then
            print("检测到新版本，是否更新？(Y/N)")
            local input = io.read()
            if input:lower() == "y" then
                local installer = download(repo .. "installer.lua")
                local shell = require("shell")
                shell.execute("rm -rf " .. os.getenv("AGENT"))
                load(installer)()
                return
            end
        end
    end
end

local tools = {}
local callbacks = {}
do
    local fs = require("filesystem")

    local function registerTool(info, callback)
        table.insert(tools, info)
        callbacks[info["function"].name] = callback
    end

    local tools_path = os.getenv("AGENT") .. "/tools"
    for file in fs.list(tools_path) do
        if file:sub(-4) == ".lua" then
            loadfile(tools_path .. "/" .. file)(registerTool)
        end
    end
end

local args = table.pack(...)
local ai = require("agent.ai")
local Session = require("agent.Session")
local session
local resume = false
if args[1] then
    for i = 1, args.n do
        session = Session(args[i])
        if session then
            break
        end
    end
    if session then
        for i = 1, args.n do
            if args[i] == "--resume" then
                resume = true
                break
            end
        end
    end
end
if not session then
    local fs = require("filesystem")
    local sessions_path = os.getenv("AGENT") .. "/sessions"
    local sessionsList = { "创建新会话" }
    for file in fs.list(sessions_path) do
        if file:sub(-4) == ".txt" then
            table.insert(sessionsList, file:sub(1, -5))
        end
    end
    local selecter = require("agent.selecter")
    print("选择会话：")
    local index = selecter.select(sessionsList)
    if index and index > 1 then
        print("[" .. sessionsList[index] .. "]")
        session = Session(sessionsList[index])
    elseif index == 1 then
        print("[新会话]")
        session = Session()
    end
end

if session then
    if resume then
        ai.steps(session, tools, callbacks)
    end
    while session:append_user_input() do
        ai.steps(session, tools, callbacks)
    end
end
