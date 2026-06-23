local parser = require('difft.parser')

local M = {}

---@alias difft.CurrentSide 'old'|'new'
---@alias difft.Display 'side-by-side'|'side-by-side-show-both'|'inline'

---@class difft.OpenOpts
---@field old_path? string
---@field new_path? string
---@field current? difft.CurrentSide
---@field display? difft.Display

---@class difft.Opts
---@field old_path string
---@field new_path string
---@field current difft.CurrentSide
---@field display difft.Display

---@class difft.OpenResult
---@field win integer
---@field difft_win integer
---@field difft_buf integer
---@field group_id integer

local defaults = {
    current = 'new',
    display = 'side-by-side',
}

local function line_after_hunk_header(row)
    if vim.fn.getline(row + 1):match('^%s*%-%s+%S+%s*$') then
        return row + 2
    end

    return row + 1
end

local function find_hunk(direction)
    local flags = direction > 0 and 'W' or 'bW'
    local row = vim.fn.search([[\s---\s\+\d\+/\d\+\s--]], flags)
    if row == 0 then return nil end

    return math.min(line_after_hunk_header(row), vim.api.nvim_buf_line_count(0))
end

local sources = require('difft.sources')

local function blank_virt_lines(count)
    local lines = {}
    for i = 1, count do
        lines[i] = {{'', 'Ignore'}}
    end
    return lines
end

---@param opts difft.OpenOpts
---@param win integer
local function validate_context(opts, win)
    if opts.current ~= 'old' and opts.current ~= 'new' then
        error("difft: current must be 'old' or 'new'")
    end

    if not vim.api.nvim_win_is_valid(win) then
        error('difft: win must be valid')
    end
end

local function nearest_source_lnum(lnum_maps, side, srclnum)
    local side_map = lnum_maps[side]
    local side_lnums = lnum_maps.lnums[side]

    local left = 1
    local right = #side_lnums
    while left <= right do
        local mid = math.floor((left + right) / 2)
        if side_lnums[mid] < srclnum then
            left = mid + 1
        else
            right = mid - 1
        end
    end

    local before = side_lnums[right]
    local after = side_lnums[left]
    local nearest_srclnum = after
    if before and (not after or srclnum - before <= after - srclnum) then
        nearest_srclnum = before
    end

    return nearest_srclnum and side_map[nearest_srclnum]
end

local function nearest_difft_lnum(lnum_maps, side, row)
    local side_map = lnum_maps[side]
    local side_lnums = lnum_maps.lnums[side]

    local left = 1
    local right = #side_lnums
    while left <= right do
        local mid = math.floor((left + right) / 2)
        if side_map[side_lnums[mid]] < row then
            left = mid + 1
        else
            right = mid - 1
        end
    end

    local before = side_lnums[right]
    local after = side_lnums[left]
    local lnum = after
    if before and (not after or row - side_map[before] <= side_map[after] - row) then
        lnum = before
    end

    return lnum
end

---@param raw_opts difft.OpenOpts
---@return difft.OpenResult
function M.open(raw_opts)
    local current_win = vim.fn.win_getid()
    local win = current_win
    local difft_win = nil
    local source_win = vim.w[current_win].difft_source_win
    if type(source_win) == 'number' and vim.api.nvim_win_is_valid(source_win) and vim.w[source_win].difft_win == current_win then
        win = source_win
        difft_win = current_win
    else
        vim.w[current_win].difft_source_win = nil
    end

    local source_opts = vim.tbl_extend('force', {}, defaults, raw_opts or {})
    validate_context(source_opts, win)
    local opts = sources.prepare_opts(source_opts, win)
    local group_id = vim.api.nvim_create_augroup('difft.group.' .. win, {clear = true})
    local ns = vim.api.nvim_create_namespace('difft.padding.' .. win)
    difft_win = difft_win or vim.w[win].difft_win
    if type(difft_win) ~= 'number' or not vim.api.nvim_win_is_valid(difft_win) or vim.w[difft_win].difft_source_win ~= win then
        vim.w[win].difft_win = nil
        difft_win = nil
    end

    local difft_buf = vim.api.nvim_create_buf(false, true)
    if difft_win then
        local old_difft_buf = vim.api.nvim_win_get_buf(difft_win)
        vim.api.nvim_win_set_buf(difft_win, difft_buf)
        pcall(vim.api.nvim_buf_delete, old_difft_buf, {force = true})
    else
        difft_win = vim.api.nvim_open_win(difft_buf, false, {split = 'above', win = -1})
    end
    vim.w[win].difft_win = difft_win
    vim.w[difft_win].difft_source_win = win
    local source_buf = vim.api.nvim_win_get_buf(win)
    local syncing = false

    vim.b[difft_buf].difft_lnum_maps = {old = {}, new = {}, rows = {}, lnums = {old = {}, new = {}}}
    vim.b[difft_buf].difft_display = opts.display
    vim.bo[difft_buf].filetype = 'difftastic'
    vim.wo[difft_win].diff = false
    vim.wo[difft_win].scrollbind = false
    vim.wo[difft_win].cursorbind = false
    vim.wo[difft_win].cursorline = true
    vim.wo[difft_win].wrap = false
    vim.wo[difft_win].scrolloff = 0

    local function valid_windows()
        return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_is_valid(difft_win)
    end

    local function cleanup()
        if vim.api.nvim_win_is_valid(win) and vim.w[win].difft_win == difft_win then
            vim.w[win].difft_win = nil
        end
        if vim.api.nvim_win_is_valid(difft_win) and vim.w[difft_win].difft_source_win == win then
            vim.w[difft_win].difft_source_win = nil
        end
        pcall(vim.api.nvim_del_augroup_by_id, group_id)
        pcall(vim.api.nvim_win_close, difft_win, true)
    end

    local function add_padding_extmarks()
        if not vim.api.nvim_buf_is_valid(difft_buf) or not vim.api.nvim_win_is_valid(difft_win) then return end

        local last_lnum = vim.api.nvim_buf_line_count(difft_buf) - 1
        local padding = math.max(vim.api.nvim_win_get_height(difft_win) - 1, 0)

        vim.api.nvim_buf_clear_namespace(difft_buf, ns, 0, -1)
        vim.api.nvim_buf_set_extmark(difft_buf, ns, 0, 0, {
            virt_lines = blank_virt_lines(padding),
            virt_lines_above = true,
            virt_lines_leftcol = true,
        })
        vim.api.nvim_buf_set_extmark(difft_buf, ns, last_lnum, 0, {
            virt_lines = blank_virt_lines(padding),
            virt_lines_leftcol = true,
        })
    end

    local function sync_scroll(srcwin, dstwin)
        if not vim.api.nvim_win_is_valid(srcwin) or not vim.api.nvim_win_is_valid(dstwin) then return end

        local src_row = vim.api.nvim_win_call(srcwin, function()
            return vim.fn.winline()
        end)
        local src_h = vim.api.nvim_win_get_height(srcwin)
        local dst_h = vim.api.nvim_win_get_height(dstwin)

        vim.api.nvim_win_call(dstwin, function()
            local dst_row = math.ceil(dst_h/2)
            if dst_h >= src_h then
                dst_row = 1
                if src_h > 1 and dst_h > 1 then
                    dst_row = math.floor(((src_row - 1) / (src_h - 1)) * (dst_h - 1) + 1)
                end
            end

            vim.cmd('normal! zt')
            -- Might not handle: virtual lines at top, scroloff, top clamp, folds, etc.
            if dst_row > 1 then
                vim.cmd(('execute "normal! %d\\<C-Y>"'):format(dst_row - 1))
            end
        end)
    end

    local function with_sync_guard(fn)
        if syncing then return end
        syncing = true
        local ok, err = pcall(fn)
        syncing = false
        if not ok then error(err) end
    end

    local function sync_to_difft(srcwin)
        local srclnum = vim.api.nvim_win_get_cursor(srcwin)[1]
        local lnum = nearest_source_lnum(vim.b[difft_buf].difft_lnum_maps, opts.current, srclnum)
        if type(lnum) ~= 'number' then return end
        if lnum < 1 or lnum > vim.api.nvim_buf_line_count(difft_buf) then return end

        vim.api.nvim_win_set_cursor(difft_win, {lnum, 0})
        sync_scroll(srcwin, difft_win)
    end

    local function sync_to_source(srcwin)
        local row = vim.api.nvim_win_get_cursor(srcwin)[1]
        local lnum = nearest_difft_lnum(vim.b[difft_buf].difft_lnum_maps, opts.current, row)
        if type(lnum) ~= 'number' then return end
        if lnum < 1 or lnum > vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) then return end

        vim.api.nvim_win_set_cursor(win, {lnum, 0})
    end

    local job_ok, job_id = pcall(vim.api.nvim_win_call, difft_win, function()
        return vim.fn.jobstart({
            'difft',
            '--color', 'always',
            '--display', opts.display,
            '--width', tostring(vim.api.nvim_win_get_width(difft_win)),
            opts.old_path,
            opts.new_path,
        }, {
            term = true,
            on_exit = function()
                vim.schedule(function()
                    opts:cleanup()
                    if not vim.api.nvim_buf_is_valid(difft_buf) then return end

                    local lines = vim.api.nvim_buf_get_lines(difft_buf, 0, -1, false)
                    vim.b[difft_buf].difft_lnum_maps = parser.lnum_maps(lines, opts.display)
                    add_padding_extmarks()
                    if valid_windows() then
                        with_sync_guard(function()
                            sync_to_difft(win)
                        end)
                    end
                end)
            end
        })
    end)
    if not job_ok then
        opts:cleanup()
        cleanup()
        error(job_id, 0)
    end
    if job_id <= 0 then
        opts:cleanup()
        cleanup()
        error('difft: failed to start difft')
    end

    vim.api.nvim_create_autocmd({'CursorMoved', 'CursorMovedI'}, {
        group = group_id,
        callback = function()
            local evtwin = vim.fn.win_getid()
            if vim.wo[win].scrollbind and vim.wo[evtwin].scrollbind and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_win_get_tabpage(evtwin) then
                evtwin = win
            end
            if syncing or not valid_windows() or evtwin ~= win then return end
            with_sync_guard(function()
                sync_to_difft(win)
            end)
        end
    })

    vim.api.nvim_create_autocmd({'CursorMoved', 'CursorMovedI'}, {
        group = group_id,
        callback = function()
            if syncing or not valid_windows() or vim.fn.win_getid() ~= difft_win then return end
            with_sync_guard(function()
                sync_to_source(difft_win)
            end)
        end
    })

    vim.api.nvim_create_autocmd('WinResized', {
        group = group_id,
        callback = function()
            if syncing or not valid_windows() then return end
            add_padding_extmarks()
            with_sync_guard(function()
                sync_to_difft(win)
            end)
        end
    })

    vim.api.nvim_create_autocmd('BufWinEnter', {
        group = group_id,
        callback = function()
            if not vim.api.nvim_win_is_valid(win) then return end
            if vim.api.nvim_win_get_buf(win) ~= source_buf then
                cleanup()
            end
        end,
    })

    vim.api.nvim_create_autocmd('WinClosed', {
        group = group_id,
        callback = function(args)
            local closed_win = tonumber(args.match)
            if closed_win == win or closed_win == difft_win then
                cleanup()
            end
        end,
    })

    vim.api.nvim_create_autocmd('BufWipeout', {
        group = group_id,
        buffer = difft_buf,
        callback = cleanup,
    })

    return {
        win = win,
        difft_win = difft_win,
        difft_buf = difft_buf,
        group_id = group_id,
    }
end

---Closes the difftastic window paired with the current window, whether the
---current window is the source or the difftastic window itself.  Returns true
---when a window was closed, false when no pair exists.
---@return boolean
function M.close()
    local current_win = vim.fn.win_getid()
    local win = current_win
    local source_win = vim.w[current_win].difft_source_win
    if type(source_win) == 'number' and vim.api.nvim_win_is_valid(source_win) and vim.w[source_win].difft_win == current_win then
        win = source_win
    end

    local difft_win = vim.w[win].difft_win
    if type(difft_win) ~= 'number' or not vim.api.nvim_win_is_valid(difft_win) or vim.w[difft_win].difft_source_win ~= win then
        return false
    end

    vim.api.nvim_win_close(difft_win, true)
    return true
end

---@param direction integer
function M.jump_hunk(direction)
    local target = find_hunk(direction)

    if target then
        vim.api.nvim_win_set_cursor(0, {target, 0})
    else
        vim.notify('difft: no hunk', vim.log.levels.INFO)
    end
end

return M
