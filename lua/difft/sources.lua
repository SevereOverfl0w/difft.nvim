local M = {}

local buf_lines = require('difft.util.buf_lines')

local function temp_path(source)
    local extension = vim.fn.fnamemodify(source or '', ':e')
    local path = vim.fn.tempname()
    if extension ~= '' then
        path = path .. '.' .. extension
    end
    return path
end

local function add_temp(temp_paths, path)
    table.insert(temp_paths, path)
    return path
end

local function buffer_to_disk(bufnr, temp_paths)
    local path = temp_path(vim.api.nvim_buf_get_name(bufnr))
    add_temp(temp_paths, path)
    vim.fn.writefile(buf_lines(bufnr), path, 'b')
    return path
end

local function real_path(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if vim.fn.exists('*FugitiveReal') == 1 then
        local fugitive_real = vim.fn.FugitiveReal(name)
        if type(fugitive_real) == 'string' and fugitive_real ~= '' then
            return fugitive_real
        end
    end
    if name == '' then
        return ''
    end
    return vim.fn.resolve(vim.fn.fnamemodify(name, ':p'))
end

local function gitgutter_base_path(bufnr, base, fallback)
    vim.fn['gitgutter#utility#base_path'](bufnr)
    local basepath = vim.fn['gitgutter#utility#getbufvar'](bufnr, 'basepath', '')
    if type(basepath) ~= 'string' or basepath == '' then
        return fallback
    end

    local parts = vim.split(basepath, ':', {plain = true})
    if parts[1] ~= base then
        return fallback
    end
    return table.concat(parts, ':', 2)
end

local function gitgutter_base_to_file(bufnr, out)
    local repo_fpath = vim.fn['gitgutter#utility#repo_path'](bufnr, 0)
    local base = vim.fn['gitgutter#utility#get_diff_base'](bufnr)
    if type(repo_fpath) ~= 'string' or repo_fpath == '' or type(base) ~= 'string' then
        return false
    end
    local path = gitgutter_base_path(bufnr, base, repo_fpath)

    local fd = vim.uv.fs_open(out, 'w', 438)
    if not fd then return false end

    local git = type(vim.g.gitgutter_git_executable) == 'string' and vim.g.gitgutter_git_executable or 'git'
    vim.system({git, '--no-pager', 'show', '--textconv', base .. ':' .. path}, {
        cwd = vim.fn.fnamemodify(real_path(bufnr), ':h'),
        stdout = function(_, data)
            if data then
                vim.uv.fs_write(fd, data, -1)
            end
        end,
    }):wait()
    vim.uv.fs_close(fd)
    return true
end

---@class difft.SourceOpts
---@field old_path? string
---@field new_path? string
---@field current difft.CurrentSide
---@field display difft.Display

local function gitgutter_base_to_disk(bufnr, source_path, temp_paths)
    local path = add_temp(temp_paths, temp_path(source_path))
    if not gitgutter_base_to_file(bufnr, path) then
        error('difft: could not read vim-gitgutter base for current buffer')
    end
    return path
end

---@param path string
---@param temp_paths string[]
---@return string path
local function to_disk_path(path, temp_paths)
    local bufnr = vim.fn.bufnr(path)
    if bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr) then
        if vim.fn.filereadable(path) == 1 and not vim.bo[bufnr].modified then
            return path
        else
            return buffer_to_disk(bufnr, temp_paths)
        end
    end

    if vim.fn.filereadable(path) == 1 then
        return path
    end

    if path:match('^fugitive:') then
        local lines = vim.fn['fugitive#readfile'](path, 'b')
        if type(lines) == 'table' then
            local temp = add_temp(temp_paths, temp_path(vim.fn.FugitiveReal(path)))
            vim.fn.writefile(lines, temp, 'b')
            return temp
        end
    end

    return path
end

---@param source string?
---@param name string
local function validate_source(source, name)
    if type(source) == 'string' and source ~= '' then
        return
    end

    error('difft: ' .. name .. ' is required')
end

---@class difft.PreparedOpts : difft.Opts
---@field cleanup fun(self: difft.PreparedOpts)

---@param opts difft.SourceOpts
---@param win integer
---@return difft.PreparedOpts opts
function M.prepare_opts(opts, win)
    local temp_paths = {}
    ---@type difft.PreparedOpts?
    local prepared

    local function cleanup_temps()
        for _, path in ipairs(temp_paths) do
            pcall(vim.fn.delete, path)
        end
        temp_paths = {}
    end

    ---@param _ difft.PreparedOpts
    local function cleanup(_)
        cleanup_temps()
    end

    local ok, err = pcall(function()
        if not opts.old_path and not opts.new_path then
            local bufnr = vim.api.nvim_win_get_buf(win)
            local path = real_path(bufnr)
            if path == '' then
                error('difft: current buffer has no path')
            end

            if vim.fn.exists('*gitgutter#git') == 1 then
                if vim.g.gitgutter_diff_relative_to == 'working_tree' then
                    opts.old_path = path
                else
                    opts.old_path = gitgutter_base_to_disk(bufnr, path, temp_paths)
                end
            end
            opts.new_path = path
        end

        local old_path = opts.old_path
        local new_path = opts.new_path
        validate_source(old_path, 'old_path')
        validate_source(new_path, 'new_path')
        ---@cast old_path string
        ---@cast new_path string

        ---@type difft.PreparedOpts
        local prepared_opts = {
            old_path = to_disk_path(old_path, temp_paths),
            new_path = to_disk_path(new_path, temp_paths),
            current = opts.current,
            display = opts.display,
            cleanup = cleanup,
        }
        prepared = prepared_opts
    end)

    if not ok then
        cleanup_temps()
        error(err, 0)
    end

    ---@cast prepared difft.PreparedOpts
    return prepared
end

return M
