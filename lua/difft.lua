local parser = require('difft.parser')

local M = {}

local defaults = {
    display = 'side-by-side',
}

local function blank_virt_lines(count)
    local lines = {}
    for i = 1, count do
        lines[i] = {{'', 'Ignore'}}
    end
    return lines
end

local function validate_opts(opts)
    opts = vim.tbl_extend('force', defaults, opts or {})

    if type(opts.old_path) ~= 'string' or opts.old_path == '' then
        error('difft: old_path is required')
    end
    if type(opts.new_path) ~= 'string' or opts.new_path == '' then
        error('difft: new_path is required')
    end
    if opts.current ~= 'old' and opts.current ~= 'new' then
        error("difft: current must be 'old' or 'new'")
    end

    opts.win = opts.win or vim.fn.win_getid()
    if not vim.api.nvim_win_is_valid(opts.win) then
        error('difft: win must be valid')
    end

    return opts
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

function M.open(raw_opts)
    local opts = validate_opts(raw_opts)
    local group_id = vim.api.nvim_create_augroup('difft.group.' .. opts.win, {clear = true})
    local ns = vim.api.nvim_create_namespace('difft.padding.' .. opts.win)
    local win = opts.win
    local current = opts.current
    local difft_display = opts.display
    -- TODO: locate existing difft window and close/replace it.
    local difft_buf = vim.api.nvim_create_buf(false, true)
    local difft_win = vim.api.nvim_open_win(difft_buf, false, {split = 'above', win = -1})
    local syncing = false

    vim.b[difft_buf].difft_lnum_maps = {old = {}, new = {}, rows = {}, lnums = {old = {}, new = {}}}
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
        pcall(vim.api.nvim_del_augroup_by_id, group_id)
        vim.api.nvim_win_close(difft_win, true)
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

    vim.api.nvim_win_call(difft_win, function()
        vim.fn.jobstart({
            'difft',
            '--color', 'always',
            '--display', difft_display,
            '--width', tostring(vim.api.nvim_win_get_width(difft_win)),
            opts.old_path,
            opts.new_path,
        }, {
            term = true,
            on_exit = function()
                vim.schedule(function()
                    if not vim.api.nvim_buf_is_valid(difft_buf) then return end

                    local lines = vim.api.nvim_buf_get_lines(difft_buf, 0, -1, false)
                    vim.b[difft_buf].difft_lnum_maps = parser.lnum_maps(lines, difft_display)
                    add_padding_extmarks()
                end)
            end
        })
    end)

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
        local lnum = nearest_source_lnum(vim.b[difft_buf].difft_lnum_maps, current, srclnum)
        if type(lnum) ~= 'number' then return end
        if lnum < 1 or lnum > vim.api.nvim_buf_line_count(difft_buf) then return end

        vim.api.nvim_win_set_cursor(difft_win, {lnum, 0})
        sync_scroll(srcwin, difft_win)
    end

    local function sync_to_source(srcwin)
        local row = vim.api.nvim_win_get_cursor(srcwin)[1]
        local lnum = nearest_difft_lnum(vim.b[difft_buf].difft_lnum_maps, current, row)
        if type(lnum) ~= 'number' then return end
        if lnum < 1 or lnum > vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) then return end

        vim.api.nvim_win_set_cursor(win, {lnum, 0})
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

    with_sync_guard(function()
        sync_to_difft(win)
    end)

    return {
        win = win,
        difft_win = difft_win,
        difft_buf = difft_buf,
        group_id = group_id,
    }
end

return M
