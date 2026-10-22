local event = require("event")

local selecter = {}

-- 每页最多显示的选项数量
local PAGE_SIZE = 10

-- OpenComputers 的按键代码
local KEY_UP = 0xC8
local KEY_DOWN = 0xD0
local KEY_HOME = 0xC7
local KEY_END = 0xCF
local KEY_PAGE_UP = 0xC9
local KEY_PAGE_DOWN = 0xD1
local KEY_ENTER = 0x1C
local KEY_NUMPAD_ENTER = 0x9C
local KEY_ESCAPE = 0x01

local ESC = "\27"

-- 取当前终端窗口的宽高，取不到时退回 OpenOS 的默认分辨率
local function get_terminal_size()
    local ok, term = pcall(require, "term")
    if ok and term and term.getGlobalArea then
        local success, _, _, width, height = pcall(term.getGlobalArea)
        if success and type(width) == "number" and type(height) == "number" then
            return width, height
        end
    end
    return 80, 25
end

-- 选项只占一行，防止换行或控制字符破坏菜单
local function format_option(option)
    return (tostring(option):gsub("%c", " "))
end

-- 按终端列宽截断，避免自动换行打乱光标位置；中文按两列计算
local function truncate(text, width)
    if width <= 0 then
        return ""
    end
    local ok, unicode = pcall(require, "unicode")
    if ok and unicode.wlen and unicode.wtrunc and unicode.wlen(text) > width then
        return unicode.wtrunc(text, width)
    end
    return text
end

-- 重绘当前页，返回已经绘制的行数
local function draw(options, index, start, rows, drawn, width)
    local out = {}
    -- 重绘时光标停在选项区域的最后一行，先回到第一行
    if drawn > 0 then
        out[#out + 1] = ESC .. "[" .. (drawn - 1) .. "A\r"
    else
        out[#out + 1] = "\r"
    end

    local last = math.min(#options, start + rows - 1)
    local count = 0
    for i = start, last do
        local text = truncate(format_option(options[i]), width - 2)
        out[#out + 1] = ESC .. "[2K"
        if i == index then
            out[#out + 1] = ESC .. "[32m> " .. ESC .. "[0m" .. ESC .. "[7m" .. text .. ESC .. "[0m"
        else
            out[#out + 1] = "  " .. text
        end
        count = count + 1
        if i < last then
            out[#out + 1] = "\n"
        end
    end

    -- 一次性写入，避免逐行刷新造成闪烁
    io.write(table.concat(out))
    return count
end

-- 计算某个选项所在的页，每页从 rows*n+1 开始
local function page_start(index, rows)
    return math.floor((index - 1) / rows) * rows + 1
end

-- 擦除选项区域，并把光标留在选项区域的第一行
local function erase(drawn)
    if drawn <= 0 then
        return
    end
    local out = { ESC .. "[" .. (drawn - 1) .. "A\r" }
    for i = 1, drawn do
        out[#out + 1] = ESC .. "[2K"
        if i < drawn then
            out[#out + 1] = "\n"
        end
    end
    if drawn > 1 then
        out[#out + 1] = ESC .. "[" .. (drawn - 1) .. "A\r"
    end
    io.write(table.concat(out))
end

-- 标题由调用方负责输出；本函数只渲染选项列表
-- 显示选项菜单，返回选中项的下标（从 1 开始）；取消或中断时返回 nil
function selecter.select(options)
    options = options or {}
    local total = #options
    if total == 0 then
        return nil
    end

    local width, height = get_terminal_size()
    local rows = math.min(PAGE_SIZE, total, math.max(1, height))

    -- 关闭自动换行，避免长选项折行后光标位置错乱
    io.write(ESC .. "[?7l")

    local index = 1
    local start = 1
    local drawn = draw(options, index, start, rows, 0, width)
    local chosen

    while true do
        local ev = table.pack(event.pullMultiple("key_down", "interrupted"))

        if ev[1] == "interrupted" then
            break
        elseif ev[1] == "key_down" then
            local code = ev[4] -- (name, address, char, code, playerName)
            local new_index = index

            if code == KEY_UP then
                new_index = index - 1
                if new_index < 1 then
                    new_index = total
                end
            elseif code == KEY_DOWN then
                new_index = index + 1
                if new_index > total then
                    new_index = 1
                end
            elseif code == KEY_HOME then
                new_index = 1
            elseif code == KEY_END then
                new_index = total
            elseif code == KEY_PAGE_UP then
                new_index = math.max(1, index - rows)
            elseif code == KEY_PAGE_DOWN then
                new_index = math.min(total, index + rows)
            elseif code == KEY_ENTER or code == KEY_NUMPAD_ENTER then
                chosen = index
                break
            elseif code == KEY_ESCAPE then
                break
            end

            if new_index ~= index then
                index = new_index
                local new_start = page_start(index, rows)
                if new_start ~= start then
                    -- 换页时先清掉旧页，避免上一页较长的内容残留
                    erase(drawn)
                    start = new_start
                    drawn = draw(options, index, start, rows, 0, width)
                else
                    drawn = draw(options, index, start, rows, drawn, width)
                end
            end
        end
    end

    erase(drawn)
    io.write(ESC .. "[?7h") -- 恢复自动换行

    -- 取消或中断时返回 nil
    return chosen
end

return selecter
