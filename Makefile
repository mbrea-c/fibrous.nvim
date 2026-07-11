# Note: avoid the name NVIM — Neovim sets $NVIM to its server socket in child
# processes, which would shadow a `NVIM ?= nvim` default.
NVIM_BIN ?= nvim

# Run the full suite in a fully isolated headless Neovim: `-u NONE` loads no
# user config and no plugins, so failures can only come from our own code.
.PHONY: test
test:
	$(NVIM_BIN) --headless -u NONE -i NONE -l tests/run.lua

# Run a single spec file for focused red-green TDD:
#   make test-file FILE=tests/reactive/use_state_spec.lua
.PHONY: test-file
test-file:
	$(NVIM_BIN) --headless -u NONE -i NONE -l tests/run.lua $(FILE)

# Benchmarks for the inline host (headless, isolated like the tests):
#   make bench            # default N=100 sections (~600 nodes)
#   make bench BENCH_N=500
.PHONY: bench
bench:
	BENCH_N=$(BENCH_N) $(NVIM_BIN) --headless -u NONE -i NONE -l bench/run.lua

# Transcript-shaped workload (long chat log: append / stream / mid-edit):
#   make bench-transcript            # default N=1000 entries
#   make bench-transcript BENCH_N=4000
.PHONY: bench-transcript
bench-transcript:
	BENCH_N=$(BENCH_N) $(NVIM_BIN) --headless -u NONE -i NONE -l bench/transcript.lua

# Markdown workload (parse / render / mount a large markdown document):
#   make bench-markdown            # default N=200 sections
#   make bench-markdown BENCH_N=800
.PHONY: bench-markdown
bench-markdown:
	BENCH_N=$(BENCH_N) $(NVIM_BIN) --headless -u NONE -i NONE -l bench/markdown.lua

# Terminal-draw throughput — bytes nvim's TUI pushes at a real pty per frame
# (the tmux+ssh cost, highlight repaints included), "one layer down" from the
# buffer-write cells/op figure. Spawns child nvim TUIs, so it runs plain (not
# under `-u NONE`, which the children get themselves via --clean):
#   make bench-term            # 80x24 pty, 60 frames
#   make bench-term BENCH_FRAMES=120 BENCH_COLS=120
.PHONY: bench-term
bench-term:
	$(NVIM_BIN) --headless -u NONE -i NONE -l bench/term.lua

# Run the benches across a span of git history and print a trend table. Reads
# the repo read-only (clones to temp). HARNESS_DIR pins the scenarios so only
# lua/fibrous/ varies between points; defaults to this tree for dev use.
#   make bench-history ARGS="--last 12 --reps 8 --benches transcript"
.PHONY: bench-history
bench-history:
	NVIM_BIN=$(NVIM_BIN) HARNESS_DIR=$${HARNESS_DIR:-$(CURDIR)} scripts/bench_history.sh $(ARGS)

# Launch an interactive, fully isolated Neovim with only this plugin loaded, and
# (optionally) open one example straight away:
#   make example            # opens, then :Examples / :Example <name>
#   make example EX=counter  # opens and runs the counter example
.PHONY: example
example:
	$(NVIM_BIN) --clean -u examples/init.lua $(if $(strip $(EX)),-c "Example $(EX)",)
