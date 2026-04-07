#!/usr/bin/env bash
# =============================================================================
# run.sh — Reproduce the published Bloom conflict-sensitivity evaluation
#          against any target model(s), using the FROZEN understanding and
#          ideation stages from the original run.
#
# Goal:
#   This bundle ships
#       bloom-results/conflict-insensitivity/understanding.json
#       bloom-results/conflict-insensitivity/ideation.json
#   captured from the published experiment. Their presence is the canonical
#   contract: every target model is evaluated against the SAME 90 scenarios
#   the original paper used, so the results are directly comparable.
#
#   If those frozen files are missing, this script falls back to regenerating
#   them via Bloom, but it warns loudly first because the regenerated scenario
#   set will NOT match the published one and the results will not be
#   comparable to the paper.
#
# Usage:
#   ./run.sh                Reproduce: rollout + judgment for every model in
#                           the MODELS array, in parallel, using the frozen
#                           scenario set.
#   ./run.sh --dry-run      Print the planned workdirs, target IDs, and
#                           seed.yaml patches WITHOUT calling the Bloom CLI
#                           or touching API keys.
#
# Pipeline (per parallel worker):
#   For each (model, reasoning) pair, the script creates an isolated workdir
#   under _runs/, symlinks behaviors.json + models.json, copies a patched
#   seed.yaml, copies in the frozen understanding.json + ideation.json so
#   Bloom skips re-running them, then launches `bloom rollout` + `bloom
#   judgment` in the background. After all jobs complete, results land in
#   bloom-results/conflict-insensitivity-<run_name>/.
#
# Configuration:
#   Edit the MODELS=(...) array below to add or remove target models.
#   Format: "model_key reasoning_effort" — reasoning is "none" or
#   "low" / "medium" / "high".
#
# Prerequisites:
#   - .env contains OPENAI_API_KEY, ANTHROPIC_API_KEY, OPENROUTER_API_KEY
#   - Bloom installed: pip install git+https://github.com/safety-research/bloom.git
#   - pyyaml installed: pip install -r requirements.txt
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# -----------------------------------------------------------------------------
# MODELS — edit this array to change which targets get evaluated
# -----------------------------------------------------------------------------
MODELS=(
    "claude-sonnet-4 none"
    "gpt-5.4-mini none"
    "gpt-5.4-mini medium"
    "deepseek-v3.2 medium"
    "grok-3-mini medium"
)

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: $0 [--dry-run]" >&2
            exit 2
            ;;
    esac
done

SHARED_RESULTS_DIR="bloom-results/conflict-insensitivity"
RUNS_DIR="_runs"

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
echo "============================================="
echo "  Bloom multi-model parallel evaluation"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  MODE: --dry-run (no API calls)"
fi
echo "============================================="

# Verify every model_key in MODELS is in models.json
python3 - <<'PYEOF'
import json, sys, os
with open("models.json") as f:
    models = json.load(f)
raw = os.environ.get("BLOOM_MODELS_LINE", "")
PYEOF

for entry in "${MODELS[@]}"; do
    read -r model_key reasoning <<< "$entry"
    python3 - "$model_key" <<'PYEOF'
import json, sys
key = sys.argv[1]
with open("models.json") as f:
    models = json.load(f)
if key not in models:
    print(f"ERROR: model_key '{key}' not in models.json", file=sys.stderr)
    print(f"Available: {', '.join(sorted(models))}", file=sys.stderr)
    sys.exit(1)
PYEOF
done

# Verify .env unless --dry-run
if [[ "$DRY_RUN" -eq 0 ]]; then
    if [[ ! -f .env ]]; then
        echo "ERROR: .env not found. Copy .env.example to .env and fill in API keys." >&2
        exit 1
    fi
    for key in OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY; do
        if ! grep -q "^${key}=" .env; then
            echo "ERROR: .env is missing $key" >&2
            exit 1
        fi
    done
fi

# -----------------------------------------------------------------------------
# Stage 1+2: frozen scenario contract
#
# The published experiment ships its understanding.json and ideation.json so
# every reproduction targets the SAME 90 scenarios. We treat those files as
# the canonical input. If either is missing, we warn loudly and fall back to
# regenerating from scratch — but the result will NOT be comparable to the
# published paper.
# -----------------------------------------------------------------------------
understanding_path="$SHARED_RESULTS_DIR/understanding.json"
ideation_path="$SHARED_RESULTS_DIR/ideation.json"

frozen_present=1
[[ -f "$understanding_path" ]] || frozen_present=0
[[ -f "$ideation_path"      ]] || frozen_present=0

if [[ "$frozen_present" -eq 1 ]]; then
    u_size=$(du -h "$understanding_path" | cut -f1)
    i_size=$(du -h "$ideation_path"      | cut -f1)
    echo ""
    echo "[scenarios] Using FROZEN scenario set from the published run:"
    echo "              $understanding_path  ($u_size)"
    echo "              $ideation_path  ($i_size)"
    echo "            Every target model below will be evaluated against the"
    echo "            same 90 scenarios used in the published paper."
else
    cat <<'WARN'

============================================================================
  WARNING: frozen scenario set is MISSING
============================================================================
  This bundle is intended to reproduce the published experiment by re-using
  the frozen understanding.json and ideation.json that ship in
      bloom-results/conflict-insensitivity/

  One or both of those files is missing. The script will fall back to
  regenerating them from behaviors.json via Bloom, but the regenerated
  scenarios WILL NOT MATCH the published paper and the resulting scores
  will not be directly comparable to the paper's findings.

  To reproduce the paper exactly, restore the shipped files from the
  GitHub repo:
      https://github.com/akryshtal/conflict-sensitivity-eval-bloom
============================================================================

WARN
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$SHARED_RESULTS_DIR"
fi

if [[ ! -f "$understanding_path" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  would run: bloom understanding ."
    else
        echo "  running: bloom understanding ."
        bloom understanding .
    fi
fi

if [[ ! -f "$ideation_path" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  would run: bloom ideation ."
    else
        echo "  running: bloom ideation ."
        bloom ideation .
    fi
fi

# -----------------------------------------------------------------------------
# Stage 3: launch parallel rollout+judgment per model
# -----------------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 0 ]]; then
    mkdir -p "$RUNS_DIR"
fi

pids=()
names=()

for entry in "${MODELS[@]}"; do
    read -r model_key reasoning <<< "$entry"

    if [[ "$reasoning" == "none" ]]; then
        run_name="$model_key"
    else
        run_name="${model_key}-reasoning-${reasoning}"
    fi

    workdir="$RUNS_DIR/$run_name"

    # Resolve LiteLLM target id
    target_id=$(python3 - "$model_key" <<'PYEOF'
import json, sys
with open("models.json") as f:
    models = json.load(f)
print(models[sys.argv[1]]["id"])
PYEOF
)

    echo ""
    echo "---------------------------------------------"
    echo "  run: $run_name"
    echo "  target: $target_id"
    echo "  workdir: $workdir"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  --- planned seed.yaml patch ---"
        python3 - "$target_id" "$reasoning" <<'PYEOF'
import yaml, sys
target_id, reasoning = sys.argv[1], sys.argv[2]
with open("seed.yaml") as f:
    seed = yaml.safe_load(f)
old_target = seed.get("rollout", {}).get("target")
old_reason = seed.get("target_reasoning_effort")
print(f"  rollout.target:           {old_target}  ->  {target_id}")
print(f"  target_reasoning_effort:  {old_reason}  ->  {reasoning}")
PYEOF
        echo "  --- end planned patch ---"
        continue
    fi

    # Create isolated workdir
    rm -rf "$workdir"
    mkdir -p "$workdir/$SHARED_RESULTS_DIR"

    # Symlink read-only inputs (use relative paths so symlinks resolve from inside workdir)
    ln -sf "../../behaviors.json" "$workdir/behaviors.json"
    ln -sf "../../models.json"    "$workdir/models.json"

    # Copy seed.yaml and patch the target fields
    cp seed.yaml "$workdir/seed.yaml"
    python3 - "$workdir/seed.yaml" "$target_id" "$reasoning" <<'PYEOF'
import yaml, sys
path, target_id, reasoning = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    seed = yaml.safe_load(f)
seed.setdefault("rollout", {})["target"] = target_id
seed["target_reasoning_effort"] = reasoning
with open(path, "w") as f:
    yaml.dump(seed, f, default_flow_style=False, sort_keys=False, width=120)
PYEOF

    # Copy the shared understanding + ideation so Bloom skips those stages
    cp "$SHARED_RESULTS_DIR/understanding.json" "$workdir/$SHARED_RESULTS_DIR/understanding.json"
    cp "$SHARED_RESULTS_DIR/ideation.json"      "$workdir/$SHARED_RESULTS_DIR/ideation.json"

    log_file="$RUNS_DIR/${run_name}.log"
    (
        cd "$workdir"
        bloom rollout . && bloom judgment .
    ) > "$log_file" 2>&1 &

    pids+=("$!")
    names+=("$run_name")
    echo "  launched (pid=${pids[-1]}, log=$log_file)"
done

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo ""
    echo "Dry run complete. No bloom calls were made."
    exit 0
fi

# -----------------------------------------------------------------------------
# Stage 4: wait for all background jobs
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo "  Waiting for ${#pids[@]} parallel runs..."
echo "============================================="

declare -A run_status
for i in "${!pids[@]}"; do
    pid="${pids[$i]}"
    name="${names[$i]}"
    if wait "$pid"; then
        run_status[$name]="ok"
        echo "  [ok]   $name"
    else
        run_status[$name]="FAIL"
        echo "  [FAIL] $name (see $RUNS_DIR/${name}.log)"
    fi
done

# -----------------------------------------------------------------------------
# Stage 5: collect results from successful workdirs
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo "  Collecting results"
echo "============================================="

for name in "${names[@]}"; do
    if [[ "${run_status[$name]}" != "ok" ]]; then
        echo "  [skip] $name (failed)"
        continue
    fi
    src="$RUNS_DIR/$name/$SHARED_RESULTS_DIR"
    dest="bloom-results/conflict-insensitivity-${name}"
    if [[ -d "$src" ]]; then
        rm -rf "$dest"
        mv "$src" "$dest"
        echo "  $name -> $dest"
    else
        echo "  [warn] $name produced no results dir"
    fi
done

# -----------------------------------------------------------------------------
# Stage 6: summary
# -----------------------------------------------------------------------------
echo ""
echo "============================================="
echo "  Summary"
echo "============================================="
ok_count=0
fail_count=0
for name in "${names[@]}"; do
    if [[ "${run_status[$name]}" == "ok" ]]; then
        ok_count=$((ok_count + 1))
    else
        fail_count=$((fail_count + 1))
    fi
done
echo "  succeeded: $ok_count"
echo "  failed:    $fail_count"
echo ""
echo "  Result directories:"
ls -d bloom-results/conflict-insensitivity-*/ 2>/dev/null || echo "    (none)"
