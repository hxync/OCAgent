-- A small regular-expression engine for the grep tool.
--
-- It covers the ripgrep constructs an agent commonly uses: literals, ., *,
-- +, ?, {m,n}, [...], [^...], groups, alternation, ^, $, \b/\B, and the
-- \d/\w/\s class shorthands. Matching is byte based, which is enough for
-- ASCII patterns and preserves UTF-8 literal matches.

local regex = {}

local MAX_REPEAT = 1000
local MAX_STEPS = 200000

local function is_digit_byte(byte)
    return byte >= 48 and byte <= 57
end

local function is_word_byte(byte)
    return (byte >= 48 and byte <= 57)
        or (byte >= 65 and byte <= 90)
        or (byte >= 97 and byte <= 122)
        or byte == 95
end

local function is_space_byte(byte)
    return byte == 32 or byte == 9 or byte == 10 or byte == 13 or byte == 12 or byte == 11
end

local function class_shorthand_matches(class, byte)
    if class == "d" then
        return is_digit_byte(byte)
    elseif class == "D" then
        return not is_digit_byte(byte)
    elseif class == "w" then
        return is_word_byte(byte)
    elseif class == "W" then
        return not is_word_byte(byte)
    elseif class == "s" then
        return is_space_byte(byte)
    elseif class == "S" then
        return not is_space_byte(byte)
    end
    return false
end

local function class_matches(node, byte)
    local hit = false
    for _, item in ipairs(node.items) do
        if item.class then
            if class_shorthand_matches(item.class, byte) then
                hit = true
                break
            end
        elseif byte >= item.lo and byte <= item.hi then
            hit = true
            break
        end
    end
    if node.neg then
        return not hit
    end
    return hit
end

local Parser = {}
Parser.__index = Parser

function Parser.new(pattern, ignore_case)
    return setmetatable({ pattern = pattern, length = #pattern, index = 1, ignore_case = ignore_case }, Parser)
end

function Parser:byte_for(char)
    if self.ignore_case then
        local lowered = char:lower()
        if #lowered == 1 then
            char = lowered
        end
    end
    return string.byte(char)
end

function Parser:peek(offset)
    local index = self.index + (offset or 0)
    if index <= self.length then
        return self.pattern:sub(index, index)
    end
end

function Parser:take()
    local char = self:peek()
    if char then
        self.index = self.index + 1
    end
    return char
end

function Parser:fail(message)
    error(string.format("invalid regular expression at position %d: %s", self.index, message), 0)
end

function Parser:read_digits()
    local start = self.index
    while self:peek() and self:peek():match("%d") do
        self.index = self.index + 1
    end
    if self.index > start then
        return self.pattern:sub(start, self.index - 1)
    end
end

function Parser:parse()
    local alternatives = self:parse_alternatives()
    if self.index <= self.length then
        self:fail("unexpected '" .. self:peek() .. "'")
    end
    return { alternatives = alternatives }
end

function Parser:parse_alternatives()
    local alternatives = {}
    while true do
        table.insert(alternatives, self:parse_sequence())
        if self:peek() == "|" then
            self.index = self.index + 1
        else
            break
        end
    end
    return alternatives
end

function Parser:parse_sequence()
    local nodes = {}
    while true do
        local char = self:peek()
        if not char or char == "|" or char == ")" then
            break
        end
        local atom = self:parse_atom()
        if not atom then
            break
        end
        table.insert(nodes, self:parse_quantifier(atom))
    end
    return nodes
end

function Parser:parse_atom()
    local char = self:take()
    if char == "(" then
        if self:peek() == "?" then
            self.index = self.index + 1
            local kind = self:take()
            if kind ~= ":" then
                if kind == "=" or kind == "!" then
                    self:fail("lookahead is not supported")
                end
                self:fail("unsupported group extension '(?" .. tostring(kind) .. "'")
            end
        end
        local alternatives = self:parse_alternatives()
        if self:take() ~= ")" then
            self:fail("missing ')'")
        end
        return { type = "group", alternatives = alternatives }
    elseif char == "[" then
        return self:parse_class()
    elseif char == "." then
        return { type = "any" }
    elseif char == "^" then
        return { type = "start" }
    elseif char == "$" then
        return { type = "end" }
    elseif char == "\\" then
        return self:parse_escape()
    elseif char == "*" or char == "+" or char == "?" then
        self:fail("nothing to repeat")
    else
        return { type = "char", byte = self:byte_for(char) }
    end
end

function Parser:parse_quantifier(atom)
    local char = self:peek()
    local minimum
    local maximum

    if char == "*" then
        minimum, maximum = 0, math.huge
        self.index = self.index + 1
    elseif char == "+" then
        minimum, maximum = 1, math.huge
        self.index = self.index + 1
    elseif char == "?" then
        minimum, maximum = 0, 1
        self.index = self.index + 1
    elseif char == "{" then
        local save = self.index
        self.index = self.index + 1
        local minimum_text = self:read_digits()
        if not minimum_text then
            self.index = save
            return atom
        end
        minimum = tonumber(minimum_text)
        if self:peek() == "}" then
            self.index = self.index + 1
            maximum = minimum
        elseif self:peek() == "," then
            self.index = self.index + 1
            local maximum_text = self:read_digits()
            if self:peek() ~= "}" then
                self.index = save
                return atom
            end
            self.index = self.index + 1
            maximum = maximum_text and tonumber(maximum_text) or math.huge
        else
            self.index = save
            return atom
        end
        if minimum > MAX_REPEAT or (maximum ~= math.huge and maximum > MAX_REPEAT) then
            self:fail("repetition count is too large")
        end
        if maximum < minimum then
            self:fail("invalid repetition range")
        end
    else
        return atom
    end

    -- A trailing ? makes a quantifier lazy; greediness does not change whether
    -- a line matches, so it is accepted and ignored.
    if self:peek() == "?" then
        self.index = self.index + 1
    end
    local next_char = self:peek()
    if next_char == "*" or next_char == "+" or next_char == "?" then
        self:fail("multiple repeat operators")
    end

    return { type = "repeat", node = atom, minimum = minimum, maximum = maximum }
end

function Parser:parse_escape()
    local char = self:take()
    if not char then
        self:fail("trailing backslash")
    end
    if char == "d" or char == "D" or char == "w" or char == "W" or char == "s" or char == "S" then
        return { type = "class", neg = false, items = { { class = char } } }
    elseif char == "b" then
        return { type = "word", neg = false }
    elseif char == "B" then
        return { type = "word", neg = true }
    elseif char == "n" then
        return { type = "char", byte = 10 }
    elseif char == "r" then
        return { type = "char", byte = 13 }
    elseif char == "t" then
        return { type = "char", byte = 9 }
    elseif char == "f" then
        return { type = "char", byte = 12 }
    elseif char == "v" then
        return { type = "char", byte = 11 }
    elseif char == "0" then
        return { type = "char", byte = 0 }
    elseif char == "x" then
        local hex = self.pattern:sub(self.index, self.index + 1)
        if not hex:match("^%x%x$") then
            self:fail("invalid \\x escape")
        end
        self.index = self.index + 2
        local byte = tonumber(hex, 16)
        if self.ignore_case and byte >= 65 and byte <= 90 then
            byte = byte + 32
        end
        return { type = "char", byte = byte }
    elseif char:match("%d") then
        self:fail("backreferences are not supported")
    end
    return { type = "char", byte = self:byte_for(char) }
end

function Parser:parse_class_escape()
    local char = self:take()
    if not char then
        self:fail("trailing backslash in character class")
    end
    if char == "d" or char == "D" or char == "w" or char == "W" or char == "s" or char == "S" then
        return { class = char }
    elseif char == "b" then
        return { lo = 8, hi = 8 }
    elseif char == "n" then
        return { lo = 10, hi = 10 }
    elseif char == "r" then
        return { lo = 13, hi = 13 }
    elseif char == "t" then
        return { lo = 9, hi = 9 }
    elseif char == "f" then
        return { lo = 12, hi = 12 }
    elseif char == "v" then
        return { lo = 11, hi = 11 }
    elseif char == "x" then
        local hex = self.pattern:sub(self.index, self.index + 1)
        if not hex:match("^%x%x$") then
            self:fail("invalid \\x escape")
        end
        self.index = self.index + 2
        local byte = tonumber(hex, 16)
        if self.ignore_case and byte >= 65 and byte <= 90 then
            byte = byte + 32
        end
        return { lo = byte, hi = byte }
    end
    local byte = self:byte_for(char)
    return { lo = byte, hi = byte }
end

function Parser:parse_class()
    local negated = false
    local first_char = self:peek()
    if first_char == "^" or first_char == "!" then
        negated = true
        self.index = self.index + 1
    end

    local items = {}
    local first = true
    while true do
        local char = self:peek()
        if not char then
            self:fail("unterminated character class")
        end
        if char == "]" and not first then
            self.index = self.index + 1
            break
        elseif char == "]" and first then
            self.index = self.index + 1
            table.insert(items, { lo = 93, hi = 93 })
            first = false
        elseif char == "\\" then
            self.index = self.index + 1
            table.insert(items, self:parse_class_escape())
            first = false
        elseif char == "-" then
            self.index = self.index + 1
            table.insert(items, { lo = 45, hi = 45 })
            first = false
        else
            self.index = self.index + 1
            local low = self:byte_for(char)
            if self:peek() == "-" and self:peek(1) and self:peek(1) ~= "]" then
                self.index = self.index + 1
                local high_char = self:take()
                if not high_char then
                    self:fail("unterminated character range")
                end
                local high
                if high_char == "\\" then
                    local item = self:parse_class_escape()
                    if item.class then
                        self:fail("character class cannot be a range endpoint")
                    end
                    high = item.lo
                else
                    high = self:byte_for(high_char)
                end
                if high < low then
                    self:fail("invalid character range")
                end
                table.insert(items, { lo = low, hi = high })
            else
                table.insert(items, { lo = low, hi = low })
            end
            first = false
        end
    end

    return { type = "class", neg = negated, items = items }
end

local function word_boundary(text, position)
    local previous = position > 0 and is_word_byte(text:byte(position)) or false
    local current = position < #text and is_word_byte(text:byte(position + 1)) or false
    return previous ~= current
end

local function tick(context)
    context.steps = context.steps - 1
    if context.steps < 0 then
        context.exceeded = true
        return false
    end
    return true
end

local match_sequence
local match_node
local match_repeat

local function match_simple(node, text, position)
    local kind = node.type
    if kind == "char" then
        if text:byte(position + 1) == node.byte then
            return position + 1
        end
    elseif kind == "any" then
        if position < #text then
            return position + 1
        end
    elseif kind == "class" then
        local byte = text:byte(position + 1)
        if byte and class_matches(node, byte) then
            return position + 1
        end
    end
    return nil
end

match_repeat = function(node, text, position, continuation, context)
    local minimum = node.minimum
    local maximum = node.maximum
    local child = node.node

    if child.type == "char" or child.type == "any" or child.type == "class" then
        local positions = { position }
        local count = 0
        local current = position
        while count < maximum do
            if not tick(context) then
                return false
            end
            local next_position = match_simple(child, text, current)
            if not next_position then
                break
            end
            current = next_position
            count = count + 1
            positions[count + 1] = current
        end
        for amount = count, minimum, -1 do
            if continuation(positions[amount + 1]) then
                return true
            end
            if context.exceeded then
                return false
            end
        end
        return false
    end

    local function try(amount, current)
        if context.exceeded or not tick(context) then
            return false
        end
        if amount < maximum then
            local advanced = false
            local empty = false
            match_node(child, text, current, function(next_position)
                if next_position == current then
                    empty = true
                    -- Let the child try its remaining alternatives; an empty
                    -- branch can still be accepted below.
                    return false
                end
                if try(amount + 1, next_position) then
                    advanced = true
                    return true
                end
                return false
            end, context)
            if advanced then
                return true
            end
            if empty then
                return continuation(current)
            end
        end
        if amount >= minimum then
            return continuation(current)
        end
        return false
    end

    return try(0, position)
end

match_node = function(node, text, position, continuation, context)
    if context.exceeded or not tick(context) then
        return false
    end
    local kind = node.type
    if kind == "char" then
        if text:byte(position + 1) == node.byte then
            return continuation(position + 1)
        end
    elseif kind == "any" then
        if position < #text then
            return continuation(position + 1)
        end
    elseif kind == "class" then
        local byte = text:byte(position + 1)
        if byte and class_matches(node, byte) then
            return continuation(position + 1)
        end
    elseif kind == "start" then
        if position == 0 then
            return continuation(position)
        end
    elseif kind == "end" then
        if position == #text then
            return continuation(position)
        end
    elseif kind == "word" then
        local boundary = word_boundary(text, position)
        if (not node.neg and boundary) or (node.neg and not boundary) then
            return continuation(position)
        end
    elseif kind == "group" then
        for _, alternative in ipairs(node.alternatives) do
            if match_sequence(alternative, 1, text, position, continuation, context) then
                return true
            end
            if context.exceeded then
                return false
            end
        end
    elseif kind == "repeat" then
        return match_repeat(node, text, position, continuation, context)
    end
    return false
end

match_sequence = function(nodes, index, text, position, continuation, context)
    if context.exceeded or not tick(context) then
        return false
    end
    if index > #nodes then
        return continuation(position)
    end
    local node = nodes[index]
    return match_node(node, text, position, function(next_position)
        return match_sequence(nodes, index + 1, text, next_position, continuation, context)
    end, context)
end

local function search(ast, text)
    local context = { steps = MAX_STEPS, exceeded = false }
    local alternatives = ast.alternatives

    local function try_at(position)
        for _, alternative in ipairs(alternatives) do
            if match_sequence(alternative, 1, text, position, function()
                return true
            end, context) then
                return true
            end
            if context.exceeded then
                return false
            end
        end
        return false
    end

    -- A single branch beginning with ^ can only match at position zero.
    if #alternatives == 1 and alternatives[1][1] and alternatives[1][1].type == "start" then
        return try_at(0), context
    end

    -- A leading unbounded .* or .+ can consume any prefix, so position zero
    -- already covers every possible start and avoids quadratic rescans.
    local first = #alternatives == 1 and alternatives[1][1] or nil
    if first and first.type == "repeat" and first.node.type == "any"
        and first.maximum == math.huge and first.minimum <= 1 then
        return try_at(0), context
    end

    for position = 0, #text do
        if try_at(position) then
            return true, context
        end
        if context.exceeded then
            break
        end
    end
    return false, context
end

local function collect_required_literals(ast)
    local function collect_sequence(nodes, into)
        for _, node in ipairs(nodes) do
            if node.type == "char" then
                into[node.byte] = true
            elseif node.type == "repeat" and node.minimum >= 1 then
                if node.node.type == "char" then
                    into[node.node.byte] = true
                end
            elseif node.type == "group" then
                local common
                for _, alternative in ipairs(node.alternatives) do
                    local found = {}
                    collect_sequence(alternative, found)
                    if not common then
                        common = found
                    else
                        for byte in pairs(common) do
                            if not found[byte] then
                                common[byte] = nil
                            end
                        end
                    end
                end
                if common then
                    for byte in pairs(common) do
                        into[byte] = true
                    end
                end
            end
        end
    end

    local required
    for _, alternative in ipairs(ast.alternatives) do
        local found = {}
        collect_sequence(alternative, found)
        if not required then
            required = found
        else
            for byte in pairs(required) do
                if not found[byte] then
                    required[byte] = nil
                end
            end
        end
    end
    return required or {}
end

function regex.new(pattern)
    local ignore_case = false
    if pattern:sub(1, 4) == "(?i)" then
        ignore_case = true
        pattern = pattern:sub(5)
    end

    local ok, parsed = pcall(function()
        return Parser.new(pattern, ignore_case):parse()
    end)
    if not ok then
        return nil, parsed
    end
    local required = collect_required_literals(parsed)

    return function(text)
        if ignore_case then
            text = text:lower()
        end
        for byte in pairs(required) do
            if not text:find(string.char(byte), 1, true) then
                return false
            end
        end
        local matched, context = search(parsed, text)
        if not matched and context.exceeded then
            error("regular expression is too complex", 0)
        end
        return matched
    end
end

return regex
