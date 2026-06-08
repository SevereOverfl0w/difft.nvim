vim.keymap.set('n', ']c', function()
    require('difft').jump_hunk(1)
end, {buffer = true, desc = 'Next difftastic hunk'})

vim.keymap.set('n', '[c', function()
    require('difft').jump_hunk(-1)
end, {buffer = true, desc = 'Previous difftastic hunk'})
