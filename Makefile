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

# Launch an interactive, fully isolated Neovim with only this plugin loaded, and
# (optionally) open one example straight away:
#   make example            # opens, then :Examples / :Example <name>
#   make example EX=counter  # opens and runs the counter example
.PHONY: example
example:
	$(NVIM_BIN) --clean -u examples/init.lua $(if $(strip $(EX)),-c "Example $(EX)",)
