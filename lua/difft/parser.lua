local M = {}

---@class difft.LnumMap
---@field old table<integer, integer> source lnum -> difft row
---@field new table<integer, integer> source lnum -> difft row
---@field rows table<integer, {old: integer?, new: integer?}> difft row -> source lnums
---@field lnums {old: integer[], new: integer[]} source lnums in row order, per side
---@return difft.LnumMap
local function new_map()
    return {old = {}, new = {}, rows = {}, lnums = {old = {}, new = {}}}
end

local function add_row(map, row, old_lnum, new_lnum)
    map.rows[row] = {old = old_lnum, new = new_lnum}

    if old_lnum then
        map.old[old_lnum] = row
        table.insert(map.lnums.old, old_lnum)
    end
    if new_lnum then
        map.new[new_lnum] = row
        table.insert(map.lnums.new, new_lnum)
    end
end

local function parse_inline(line)
    return tonumber(line:match('^(%d+)')), tonumber(line:match('^%s+(%d+)'))
end

local function inline_lnum_maps(lines)
    local map = new_map()
    for row, line in ipairs(lines) do
        add_row(map, row, parse_inline(line))
    end
    return map
end

--- Column-alignment tokens in a side-by-side row, each tagged with the display column it ends at.
local function column_tokens(line)
    local tokens = {}
    for padding, token_start, token in line:gmatch('(%s+)()([%d%.]+)%s?') do
        if token:match('^%.+$') or token:match('^%d+$') then
            local col_end = vim.fn.strdisplaywidth(line:sub(1, token_start - 1)) + #token
            tokens[#tokens + 1] = {value = token, col_end = col_end, padding = #padding}
        end
    end
    return tokens
end

local function is_side_by_side_row(line)
    return line:match('^%s*[%d%.]+%s')
end

--- Finds right-side lnum column in a side-by-side hunk. Difftastic has no separator, so infer column by scanning all
--- column-like tokens and picking one present on every hunk row. That rules out most random integers in code text.
---@param map difft.LnumMap
---@param lines string[]
---@param first integer
---@param last integer
local function add_side_by_side_hunk(map, lines, first, last)
    local columns = {}
    local lnum_at = {}
    for row = first, last do
        local row_lnums = {}
        for _, token in ipairs(column_tokens(lines[row])) do
            row_lnums[token.col_end] = tonumber(token.value)
            local column = columns[token.col_end] or {count = 0, padding = 0}
            column.count = column.count + 1
            column.padding = math.max(column.padding, token.padding)
            columns[token.col_end] = column
        end
        lnum_at[row] = row_lnums
    end

    local new_col
    local best_padding = 0
    local hunk_size = last - first + 1
    for col_end, column in pairs(columns) do
        if column.count == hunk_size and (column.padding > best_padding
            or column.padding == best_padding and (not new_col or col_end > new_col))
        then
            new_col = col_end
            best_padding = column.padding
        end
    end

    for row = first, last do
        add_row(map, row, tonumber(lines[row]:match('^%s*([%d%.]+)%s')), lnum_at[row][new_col])
    end
end

local function side_by_side_lnum_maps(lines)
    local map = new_map()
    local row = 1

    while row <= #lines do
        if is_side_by_side_row(lines[row]) then
            local first = row
            repeat
                row = row + 1
            until row > #lines or not is_side_by_side_row(lines[row])

            add_side_by_side_hunk(map, lines, first, row - 1)
        else
            map.rows[row] = {}
            row = row + 1
        end
    end

    return map
end

function M.lnum_maps(lines, display)
    if display == 'inline' then
        return inline_lnum_maps(lines)
    end

    return side_by_side_lnum_maps(lines)
end

return M
