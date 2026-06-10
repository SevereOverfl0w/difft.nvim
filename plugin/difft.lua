---@class difft.NoPathCommandOpts: difft.OpenOpts
---@field old_path? nil
---@field new_path? nil

---@class difft.PathCommandOpts: difft.OpenOpts
---@field old_path string
---@field new_path string

---@alias difft.CommandOpts difft.NoPathCommandOpts|difft.PathCommandOpts

---@param args string[]
---@return difft.CommandOpts
local function parse_args(args)
    ---@type table<string, any>
    local opts = {}
    local paths = {}
    local i = 1

    while i <= #args do
        local arg = args[i]

        if arg == '-display' then
            i = i + 1
            opts.display = args[i]
            if not opts.display or opts.display:match('^-') then error('difft: -display requires value') end
        elseif arg == '-current' then
            i = i + 1
            opts.current = args[i]
            if not opts.current or opts.current:match('^-') then error('difft: -current requires value') end
        elseif arg:match('^-') then
            error('difft: unknown option ' .. arg)
        else
            table.insert(paths, arg)
        end

        i = i + 1
    end

    if #paths ~= 0 and #paths ~= 2 then
        error('difft: expected OLD-PATH and NEW-PATH')
    end

    if #paths == 0 then
        ---@cast opts difft.NoPathCommandOpts
        return opts
    end

    opts.old_path = vim.fn.expand(paths[1])
    opts.new_path = vim.fn.expand(paths[2])
    ---@cast opts difft.PathCommandOpts
    return opts
end

local function filter(items, lead)
    return vim.tbl_filter(function(item)
        return vim.startswith(item, lead)
    end, items)
end

local function complete(arglead, cmdline, cursorpos)
    local before_cursor = cmdline:sub(1, cursorpos - 1)
    local before_arg = before_cursor:sub(1, #before_cursor - #arglead)
    local args = vim.split(before_arg, '%s+', {trimempty = true})
    local previous = args[#args]

    if previous == '-current' then
        return filter({'old', 'new'}, arglead)
    end
    if previous == '-display' then
        return filter({'side-by-side', 'side-by-side-show-both', 'inline'}, arglead)
    end
    if vim.startswith(arglead, '-') then
        return filter({'-current', '-display'}, arglead)
    end

    return vim.fn.getcompletion(arglead, 'file')
end

vim.api.nvim_create_user_command('Difft', function(command)
    require('difft').open(parse_args(command.fargs))
end, {
    nargs = '*',
    complete = complete,
    desc = 'Open difftastic output synced with current window. Usage: Difft [-current old|new] [-display DISPLAY] [OLD-PATH NEW-PATH]',
})

vim.api.nvim_create_user_command('DifftClose', function()
    require('difft').close()
end, {
    desc = 'Close the difftastic window paired with the current window',
})
