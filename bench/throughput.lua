-- Draw-throughput instrumentation — the companion metric to latency ms.
--
-- Latency (ms/op) says how long a commit's CPU takes; it says nothing about how
-- many cells that commit then shoves at the display. Over ssh+tmux the display
-- is the bottleneck (every changed cell is bytes down a high-latency link, and a
-- big per-frame redraw is what makes the terminal — and the cursor — flicker),
-- so "cells written per op" is the number that governs whether a workload stays
-- smooth remotely, independent of how fast the CPU is.
--
-- It's measured by wrapping the two buffer-write APIs the host flush actually
-- uses — nvim_buf_set_lines (the splice / full paint) and nvim_buf_set_text (the
-- subwindow mirrors) — and summing the DISPLAY WIDTH of everything written.
-- Display width, not byte length: a multibyte glyph is one cell on screen, and
-- it's screen cells the terminal has to push. The host calls both through the
-- vim.api table (no cached upvalues), so the wrappers see every write.

local width = require("fibrous.inline.width")

local M = {}

-- Run `fn` with the buffer-write APIs wrapped; return the draw it produced:
--   cells  total display cells written (set_lines + set_text)
--   writes number of API calls (a proxy for redraw fragmentation)
-- The APIs are always restored, even if `fn` raises (the error re-propagates).
---@param fn fun()
---@return { cells: integer, writes: integer }
function M.counting(fn)
	local set_lines = vim.api.nvim_buf_set_lines
	local set_text = vim.api.nvim_buf_set_text
	local cells, writes = 0, 0

	vim.api.nvim_buf_set_lines = function(buf, s, e, strict, repl)
		for _, l in ipairs(repl) do
			cells = cells + width.str(l)
		end
		writes = writes + 1
		return set_lines(buf, s, e, strict, repl)
	end
	vim.api.nvim_buf_set_text = function(buf, sr, sc, er, ec, repl)
		for _, l in ipairs(repl) do
			cells = cells + width.str(l)
		end
		writes = writes + 1
		return set_text(buf, sr, sc, er, ec, repl)
	end

	local ok, err = pcall(fn)

	vim.api.nvim_buf_set_lines = set_lines
	vim.api.nvim_buf_set_text = set_text

	if not ok then
		error(err, 0)
	end
	return { cells = cells, writes = writes }
end

return M
