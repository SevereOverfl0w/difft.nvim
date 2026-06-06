local M = {}

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

--- Finds right-side lnum column in a side-by-side hunk.
--- Difftastic has no separator, so infer column by scanning all column-like
--- tokens and picking one present on every hunk row. That rules out most
--- random integers in code text.
---@param lines string[]
---@param first integer
---@param last integer
---@return integer?
local function locate_column(lines, first, last)
    local potential_columns = {}

    for row = first, last do
        for padding, token_start, token in lines[row]:gmatch('(%s+)()([%d%.]+)%s?') do
            if token:match('^%.+$') or token:match('^%d+$') then
                local token_end = token_start + #token - 1
                local column = potential_columns[token_end] or {count = 0, padding = 0, width = 0}
                column.count = column.count + 1
                column.padding = math.max(column.padding, #padding)
                column.width = math.max(column.width, #token)
                potential_columns[token_end] = column
            end
        end
    end

    local best_end
    local best_padding = 0
    local hunk_size = last - first + 1
    for token_end, column in pairs(potential_columns) do
        if column.count == hunk_size and (column.padding > best_padding
            or column.padding == best_padding and (not best_end or token_end > best_end))
        then
            best_end = token_end
            best_padding = column.padding
        end
    end

    if not best_end then return nil end

    return best_end - potential_columns[best_end].width + 1
end

local function parse_side_by_side(line, col)
    local new_token = col and line:sub(col):match('^%s*([%d%.]+)%s?')
    return tonumber(line:match('^%s*([%d%.]+)%s')), tonumber(new_token)
end

local function is_side_by_side_row(line)
    return line:match('^%s*[%d%.]+%s')
end

local function add_side_by_side_hunk(map, lines, first, last)
    local col = locate_column(lines, first, last)
    for row = first, last do
        add_row(map, row, parse_side_by_side(lines[row], col))
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
