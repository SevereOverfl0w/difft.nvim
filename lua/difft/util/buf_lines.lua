-- Portions adapted from gitsigns.nvim:
-- https://github.com/lewis6991/gitsigns.nvim/blob/25050e4ed39e628282831d4cbecb1850454ce915/lua/gitsigns/util.lua?plain=1#L128
--
-- MIT License
--
-- Copyright (c) 2020 Lewis Russell
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.

local function bytes(...)
    local chars = {}
    for i, byte in ipairs({...}) do
        chars[i] = string.char(byte)
    end
    return table.concat(chars)
end

local bom_by_encoding = {
    ['utf-8'] = bytes(0xef, 0xbb, 0xbf),
    ['utf-16'] = bytes(0xfe, 0xff),
    ['utf-16be'] = bytes(0xfe, 0xff),
    ['utf-16le'] = bytes(0xff, 0xfe),
    ['utf-32'] = bytes(0x00, 0x00, 0xfe, 0xff),
    ['utf-32be'] = bytes(0x00, 0x00, 0xfe, 0xff),
    ['utf-32le'] = bytes(0xff, 0xfe, 0x00, 0x00),
    ['ucs-2'] = bytes(0xfe, 0xff),
    ['ucs-2be'] = bytes(0xfe, 0xff),
    ['ucs-2le'] = bytes(0xff, 0xfe),
    ['ucs-4'] = bytes(0x00, 0x00, 0xfe, 0xff),
    ['ucs-4be'] = bytes(0x00, 0x00, 0xfe, 0xff),
    ['ucs-4le'] = bytes(0xff, 0xfe, 0x00, 0x00),
    ['utf-7'] = bytes(0x2b, 0x2f, 0x76),
    ['utf-1'] = bytes(0xf7, 0x54, 0x4c),
}

local function add_bom(line, encoding)
    local bom = bom_by_encoding[encoding:lower()]
    return bom and bom .. line or line
end

local function buf_lines(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local empty_buffer = vim.api.nvim_buf_call(bufnr, function()
        return vim.fn.line2byte(1) == -1
    end)

    if #lines == 1 and lines[1] == '' and empty_buffer then
        return {}
    end

    local dos = vim.bo[bufnr].fileformat == 'dos'
    if dos then
        for i = 1, #lines - 1 do
            lines[i] = lines[i] .. '\r'
        end
    end

    if vim.bo[bufnr].endofline then
        if dos then
            lines[#lines] = lines[#lines] .. '\r'
        end
        lines[#lines + 1] = ''
    end

    if vim.bo[bufnr].bomb and #lines > 0 then
        local encoding = vim.bo[bufnr].fileencoding
        if encoding == '' then
            encoding = vim.o.encoding
        end
        lines[1] = add_bom(lines[1], encoding)
    end

    return lines
end

return buf_lines
