"""Run from the Fibrous checkout with NVIM_BIN and FIBROUS_BENCH_MARKDOWN set."""
import argparse
import json
import os
from pathlib import Path
import subprocess
from statistics import median

parser = argparse.ArgumentParser()
parser.add_argument("--rounds", type=int, default=8)
parser.add_argument("--terminal", action="store_true")
parser.add_argument("--out", type=Path, required=True, help="Writable results directory")
args = parser.parse_args()
if args.rounds < 1:
    parser.error("rounds must be positive")
folder = Path("bench/native_markdown")
bench = "term" if args.terminal else "run"
nvim = os.getenv("NVIM_BIN", "nvim")
args.out.mkdir(parents=True, exist_ok=True)
with (args.out / f"results-{bench}.jsonl").open("w") as output:
    for iteration in range(args.rounds):
        for narrow in (False, True):
            batch = []
            order = ("lua", "rust") if (iteration + narrow) % 2 == 0 else ("rust", "lua")
            for mode in order:
                env = dict(os.environ, BENCH_MODE=mode, BENCH_NARROW=str(int(narrow)))
                for var in ("FIBROUS_NATIVE_WRAP", "FIBROUS_NATIVE_REACTIVE"):
                    env.pop(var, None)
                report = subprocess.check_output([
                    nvim, "--headless", "-u", "NONE", "-i", "NONE", "-l", str(folder / f"{bench}.lua")
                ], env=env, text=True, timeout=120)
                data = json.loads(report)
                data.update(round=iteration + 1, narrow=narrow)
                print(json.dumps(data), file=output, flush=True)
                batch.append(data)
            for key in (("fingerprint", "bytes") if args.terminal else ("fingerprint", "cells", "writes")):
                assert batch[0][key] == batch[1][key], (key, batch)
            print(iteration + 1, "narrow" if narrow else "stock",
                  [(b["mode"], round(median(b["samples"]), 2)) for b in batch], flush=True)
