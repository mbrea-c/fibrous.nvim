#!/usr/bin/env bash
# bench_history.sh — run the fibrous benchmarks across a span of git history and
# aggregate the results into a trend table.
#
# SAFETY CONTRACT: this never modifies the real repository or its working tree,
# under any circumstances. The real repo is only ever READ (rev-list, and the
# clone reads objects). Every git operation that writes — worktrees, checkouts —
# happens inside a throwaway `git clone --no-hardlinks` in a temp dir, which is
# deleted on exit. The uncommitted working tree, when benched, is snapshotted by
# COPYING lua/ into the temp area; the originals are never touched.
#
# How each commit is measured with IDENTICAL bench code: the bench scripts are
# PINNED (this script's --harness dir, the flake bakes it from `self`) and run
# against each commit's library via `--cmd 'set rtp^=<worktree>'`, so only
# lua/fibrous/ varies between points — never the scenarios or the harness.
#
# Usage:
#   scripts/bench_history.sh [--last N] [--step S] [--reps R]
#                            [--benches run,transcript] [--n BENCH_N]
#                            [--no-working] [--out results.jsonl]
#
#   --last N       how many commits back from HEAD to include (default 8)
#   --step S       take every S-th commit (default 1)
#   --reps R       measurement batches; each batch runs every (point,bench) once
#                  in a fresh random order, so drift is spread evenly (default 6)
#   --benches L    comma list of bench files under bench/ (default run,transcript)
#   --n VALUE      override BENCH_N for every bench (default: each bench's own)
#   --no-working   don't bench the uncommitted working tree (benched by default
#                  when it differs from HEAD)
#   --out FILE     also write the raw JSONL (one bench run per line) here
#
# Env overrides (the flake app sets the first two): NVIM_BIN, HARNESS_DIR,
# REPO_DIR.
set -euo pipefail

LAST=8
STEP=1
REPS=6
BENCHES="run,transcript"
BENCH_N_OVERRIDE=""
WORKING=auto
OUT=""

while [ $# -gt 0 ]; do
	case "$1" in
	--last) LAST="$2"; shift 2 ;;
	--step) STEP="$2"; shift 2 ;;
	--reps) REPS="$2"; shift 2 ;;
	--benches) BENCHES="$2"; shift 2 ;;
	--n) BENCH_N_OVERRIDE="$2"; shift 2 ;;
	--no-working) WORKING=no; shift ;;
	--working) WORKING=yes; shift ;;
	--out) OUT="$2"; shift 2 ;;
	-h | --help) sed -n '2,40p' "$0"; exit 0 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

NVIM="${NVIM_BIN:-nvim}"
REPO="${REPO_DIR:-$(git -C "${PWD}" rev-parse --show-toplevel)}"
# The pinned harness: default to this script's own repo (the bench/ + aggregator
# beside it), so a dev can run it straight from a checkout; the flake app passes
# HARNESS_DIR pointing at the store snapshot of `self`.
HARNESS="${HARNESS_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

IFS=',' read -r -a BENCH_LIST <<<"$BENCHES"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fibrous-benchhist.XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

echo "bench-history: repo=$REPO" >&2
echo "  harness=$HARNESS  nvim=$($NVIM --version | head -1)" >&2

# 1. Clone to temp (independent object store: no hardlinks reach the real repo).
git clone --no-hardlinks --no-checkout --quiet "$REPO" "$TMP/repo"

# 2. Pick commits: every STEP-th of the last LAST*STEP, oldest last in rev-list.
mapfile -t ALL < <(git -C "$TMP/repo" rev-list --first-parent -n "$((LAST * STEP))" HEAD)
SHAS=()
for ((i = 0; i < ${#ALL[@]}; i += STEP)); do SHAS+=("${ALL[$i]}"); done

# points: parallel arrays label[]/dir[]. Order here is NEWEST→OLDEST (rev-list
# order); the ORDER file below is written OLDEST→NEWEST for the table columns.
LABELS=()
DIRS=()
ORDER="$TMP/order.tsv" # label \t subject, oldest first
: >"$ORDER"

# Working tree first (newest point) when it differs from HEAD.
if [ "$WORKING" = auto ]; then
	if [ -n "$(git -C "$REPO" status --porcelain)" ]; then WORKING=yes; else WORKING=no; fi
fi
if [ "$WORKING" = yes ]; then
	mkdir -p "$TMP/wt/working"
	# snapshot the live library — READ-ONLY on the originals — so uncommitted
	# edits are a real data point. Only lua/ matters (rtp loads require paths).
	cp -a "$REPO/lua" "$TMP/wt/working/lua"
	LABELS+=("working")
	DIRS+=("$TMP/wt/working")
fi

# 3. One worktree per commit, in the CLONE (never the real repo).
for sha in "${SHAS[@]}"; do
	short="$(git -C "$TMP/repo" rev-parse --short "$sha")"
	git -C "$TMP/repo" worktree add --quiet --detach "$TMP/wt/$sha" "$sha"
	LABELS+=("$short")
	DIRS+=("$TMP/wt/$sha")
done

# ORDER file, oldest→newest: reverse the commit shas, then working last.
for ((i = ${#SHAS[@]} - 1; i >= 0; i--)); do
	sha="${SHAS[$i]}"
	short="$(git -C "$TMP/repo" rev-parse --short "$sha")"
	subj="$(git -C "$TMP/repo" log -1 --format=%s "$sha")"
	printf '%s\t%s\n' "$short" "$subj" >>"$ORDER"
done
[ "$WORKING" = yes ] && printf 'working\t(uncommitted working tree)\n' >>"$ORDER"

echo "  points: ${LABELS[*]}" >&2
echo "  benches: ${BENCHES}  reps: ${REPS}" >&2

JSONL="$TMP/results.jsonl"
: >"$JSONL"

# 4. Randomized-batch schedule: each rep runs every (point,bench) once, in a
#    fresh random order, so a thermal/background drift within a batch lands on
#    all points rather than biasing whichever ran during it.
NP=${#LABELS[@]}
total=$((REPS * NP * ${#BENCH_LIST[@]}))
done_n=0
for ((rep = 1; rep <= REPS; rep++)); do
	# build this batch's (index,bench) pairs and shuffle them
	pairs=()
	for ((p = 0; p < NP; p++)); do
		for bench in "${BENCH_LIST[@]}"; do pairs+=("$p|$bench"); done
	done
	mapfile -t shuffled < <(printf '%s\n' "${pairs[@]}" | shuf)
	for entry in "${shuffled[@]}"; do
		p="${entry%%|*}"
		bench="${entry##*|}"
		label="${LABELS[$p]}"
		dir="${DIRS[$p]}"
		done_n=$((done_n + 1))
		printf '\r  rep %d/%d  [%d/%d] %-9s %-11s        ' \
			"$rep" "$REPS" "$done_n" "$total" "$label" "$bench" >&2
		script="$HARNESS/bench/$bench.lua"
		if [ ! -f "$script" ]; then
			echo "" >&2; echo "  no such bench: $script" >&2; exit 2
		fi
		# `env` (not a bare VAR=val prefix): the BENCH_N assignment is built by
		# expansion, which the shell would otherwise treat as a command name.
		set +e
		out="$(cd "$dir" && env BENCH_JSON=1 BENCH_LABEL="$label" \
			${BENCH_N_OVERRIDE:+BENCH_N="$BENCH_N_OVERRIDE"} \
			"$NVIM" --headless -u NONE -i NONE \
			--cmd "set runtimepath^=$dir" -l "$script" 2>/dev/null | tail -1)"
		rc=$?
		set -e
		if [ $rc -ne 0 ] || [ -z "$out" ] || [ "${out:0:1}" != "{" ]; then
			# the pinned harness could not run against this commit (API drift, or
			# a crash): record an empty run so the point shows n/a, don't abort.
			out="{\"label\":\"$label\",\"bench\":\"$bench\",\"n\":0,\"results\":[],\"load_error\":true}"
		fi
		printf '%s\n' "$out" >>"$JSONL"
	done
done
printf '\r%*s\r' 60 '' >&2 # clear the progress line

[ -n "$OUT" ] && cp "$JSONL" "$OUT" && echo "raw JSONL → $OUT" >&2

# 5. Aggregate to a trend table.
"$NVIM" --headless -u NONE -i NONE -l "$HARNESS/scripts/bench_aggregate.lua" "$JSONL" "$ORDER"
