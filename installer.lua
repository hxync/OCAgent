local usingPrefix = true -- 如果连接不上github，可以把这项改成true，使用国内镜像下载

local filesystem = require("filesystem")
local internet = require("internet")

local install_path = "/usr/apps/"

local repo = "https://raw.githubusercontent.com/hxync/OCAgent/"
local branch = "main"
local paths = {
    install_path,
    install_path .. "agent",
    install_path .. "agent/lib",
    install_path .. "agent/prompts",
    install_path .. "agent/sessions",
    install_path .. "agent/tools",
}

local scripts = {
    "agent/lib/fs_util.lua",
    "agent/lib/glob.lua",
    "agent/lib/observation.lua",
    "agent/lib/regex.lua",
    "agent/lib/stream_capture.lua",
    "agent/prompts/init.lua",
    "agent/prompts/shell.txt",
    "agent/prompts/system.txt",
    "agent/tools/edit.lua",
    "agent/tools/glob.lua",
    "agent/tools/grep.lua",
    "agent/tools/lua_shell.lua",
    "agent/tools/read.lua",
    "agent/tools/reboot.lua",
    "agent/tools/shell.lua",
    "agent/tools/working_directory.lua",
    "agent/tools/write.lua",
    "agent/ai.lua",
    "agent/init.lua",
    "agent/selecter.lua",
    "agent/Session.lua",
}

local lnks = {
    ["/home/ai.lua"] = install_path .. "agent/init.lua",
}

local prefix = "https://github.xutongxin.me/"
repo = usingPrefix and prefix .. repo or repo

local function download(url)
    local handle = internet.request(url)
    local result = ""
    for chunk in handle do
        result = result..chunk
    end
    return result
end

local function writeFile(path, content)
    local file = assert(io.open(path, "w"))
    file:write(content)
    file:close()
end

local function main()
    -- Lib
    if not filesystem.exists("/lib/JSON.lua") then
        print("Downloading JSON.lua")
        local content = download("https://regex.info/code/JSON.lua")
        writeFile("/lib/JSON.lua", content)
    end
    -- Repo
    local version = download(string.format("%s%s/VERSION", repo, branch))
    for i = 1, #paths do
        local dir = paths[i]
        if not filesystem.exists(dir) then
            filesystem.makeDirectory(dir)
        end
    end
    for i = 1, #scripts do
        local file_path = install_path .. scripts[i]
        if filesystem.exists(file_path) then
            filesystem.remove(file_path)
        end
        local url = string.format("%s%s/%s", repo, branch, scripts[i])
        print("Downloading "..scripts[i])
        local content = download(url)
        content = content:gsub("$[[INSTALL_PATH]]", install_path)
        content = content:gsub("$[[VERSION]]", version)
        content = content:gsub("$[[REPO]]", repo)
        content = content:gsub("$[[BRANCH]]", branch)
        writeFile(file_path, content)
    end
    -- Lnk
    for lnk, target in pairs(lnks) do
        writeFile(lnk, "loadfile(\"" .. target .. "\")(...)")
    end
end

local suc, test = pcall(download, "http://www.msftconnecttest.com/connecttest.txt")
if suc and test == "Microsoft Connect Test" then
    main()
else
    print("Error: Internet Disconnected")
end
