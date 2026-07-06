-- bench_aggregate.lua — turn the JSONL that bench_history.sh collected into a
-- trend table. Invoked headless:
--   nvim --headless -u NONE -i NONE -l scripts/bench_aggregate.lua RESULTS.jsonl ORDER.tsv
--
-- RESULTS.jsonl: one { label, bench, n, results:[{op,unit,value,iters,error}] }
--   object per line — many per (label,bench) when reps > 1.
-- ORDER.tsv:     label <TAB> subject, one per line, OLDEST first — the column
--   order for the table (the schedule shuffled the runs, losing history order).
--
-- Per (bench, op, label) we reduce the reps to a MEDIAN and a MAD (median
-- absolute deviation, a noise-robust spread). A cell is flagged against the
-- column to its left when the two medians differ by more than the combined
-- noise AND by more than a small relative floor — so run-to-run jitter on a
-- sub-millisecond op doesn't cry regression. Higher is worse for every unit
-- here (ms/op, ms CPU/s), so ▲ = slower, ▼ = faster.

local args = _G.arg or {}
local jsonl_path, order_path = args[1], args[2]
if not jsonl_path or not order_path then
	io.stderr:write("usage: bench_aggregate.lua RESULTS.jsonl ORDER.tsv\n")
	vim.cmd("cquit 2")
end

-- Column order (oldest → newest) and subjects.
local order, subject = {}, {}
for line in io.lines(order_path) do
	local label, subj = line:match("^([^\t]*)\t(.*)$")
	if label then
		order[#order + 1] = label
		subject[label] = subj
	end
end

-- data[bench].ops (first-seen order) + data[bench].cells[op][label] = { values }
-- and unit[bench][op]; n[bench] = the BENCH_N last seen.
local data, unit, bench_order, bench_n = {}, {}, {}, {}
for line in io.lines(jsonl_path) do
	if line ~= "" then
		local ok, obj = pcall(vim.json.decode, line)
		if ok and obj and obj.bench and obj.label then
			local b = data[obj.bench]
			if not b then
				b = { ops = {}, seen = {}, cells = {} }
				data[obj.bench] = b
				unit[obj.bench] = {}
				bench_order[#bench_order + 1] = obj.bench
			end
			if (obj.n or 0) > 0 then
				bench_n[obj.bench] = obj.n
			end
			-- Register one (op → per-label values) series. Called for the latency
			-- value and, right after, for the op's draw throughput — so a "·draw"
			-- row sits directly under its ms row in the table.
			local function push(op, u, value)
				if not b.seen[op] then
					b.seen[op] = true
					b.ops[#b.ops + 1] = op
					b.cells[op] = {}
				end
				unit[obj.bench][op] = u
				if type(value) == "number" then
					local cell = b.cells[op][obj.label] or {}
					cell[#cell + 1] = value
					b.cells[op][obj.label] = cell
				end
			end
			for _, r in ipairs(obj.results or {}) do
				push(r.op, r.unit, r.value)
				-- Draw throughput (cells written to the buffer) as its own series:
				-- deterministic, so its MAD is ~0 and any real change flags at once —
				-- more cells = more redraw = worse, same "higher is worse" polarity.
				if type(r.cells) == "number" then
					push(r.op .. "  ·draw", "cells/op", r.cells)
				end
			end
		end
	end
end

local function median(xs)
	if #xs == 0 then
		return nil
	end
	local s = vim.deepcopy(xs)
	table.sort(s)
	local m = #s
	if m % 2 == 1 then
		return s[(m + 1) / 2]
	end
	return (s[m / 2] + s[m / 2 + 1]) / 2
end

local function mad(xs, med)
	if #xs == 0 then
		return 0
	end
	local dev = {}
	for i, x in ipairs(xs) do
		dev[i] = math.abs(x - med)
	end
	return median(dev) or 0
end

-- reps actually collected (max cell count), for the header.
local reps = 0
for _, b in pairs(data) do
	for _, byLabel in pairs(b.cells) do
		for _, vals in pairs(byLabel) do
			reps = math.max(reps, #vals)
		end
	end
end

local OPW = 46 -- op-name column
local COLW = 11 -- per-point column

local function pad(s, w)
	s = tostring(s)
	if #s >= w then
		return s
	end
	return s .. string.rep(" ", w - #s)
end
local function rpad(s, w) -- right-align in DISPLAY width w (markers are multibyte)
	s = tostring(s)
	local dw = vim.fn.strdisplaywidth(s)
	if dw >= w then
		return s
	end
	return string.rep(" ", w - dw) .. s
end

local out = {}
local function pr(line)
	out[#out + 1] = line
end

pr("")
pr(("bench-history  —  %d points, %d reps each  (median value; ·draw rows = cells/op; ▲ worse / ▼ better vs the column to its left)")
	:format(#order, reps))

for _, bench in ipairs(bench_order) do
	local b = data[bench]
	pr("")
	pr(("== %s  (N=%s) =="):format(bench, tostring(bench_n[bench] or "?")))
	-- header row
	local header = pad("op", OPW)
	for _, label in ipairs(order) do
		header = header .. rpad(label, COLW)
	end
	header = header .. rpad("Δ%", COLW)
	pr(header)
	for _, op in ipairs(b.ops) do
		local row = pad(op:sub(1, OPW - 1), OPW)
		local prev_med, prev_mad, first_med, last_med
		for _, label in ipairs(order) do
			local vals = b.cells[op][label]
			if not vals or #vals == 0 then
				row = row .. rpad("n/a", COLW)
			else
				local med = median(vals)
				local d = mad(vals, med)
				local mark = " "
				if prev_med then
					local delta = med - prev_med
					-- flag only when the shift clears the two columns' combined
					-- noise AND a 3% floor, so sub-ms run-to-run jitter stays quiet
					if math.abs(delta) > 1.5 * (d + prev_mad) and math.abs(delta) > 0.03 * prev_med then
						mark = delta > 0 and "▲" or "▼"
					end
				end
				row = row .. rpad(("%.3f%s"):format(med, mark), COLW)
				prev_med, prev_mad = med, d
				first_med = first_med or med
				last_med = med
			end
		end
		if first_med and last_med and first_med ~= 0 then
			row = row .. rpad(("%+.1f%%"):format((last_med - first_med) / first_med * 100), COLW)
		else
			row = row .. rpad("-", COLW)
		end
		pr(row)
	end
end

pr("")
io.write(table.concat(out, "\n") .. "\n")
