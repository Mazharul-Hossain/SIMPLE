#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  .codex/check-joint-sgd-science-log.sh baseline <LOG> [RUN_DIR] [CASE]
  .codex/check-joint-sgd-science-log.sh joint    <LOG> [RUN_DIR] [CASE]

Checks logs produced by .codex/run-joint-sgd-science.sh. RUN_DIR is optional;
when provided, the checker also verifies that abinitio2D output and class/FRC
artifacts exist.
EOF
}

fail() {
  echo "joint-SGD science log check failed: $*" >&2
  exit 1
}

require_contains() {
  local pattern="$1"
  local label="$2"
  if ! grep -Fq -- "$pattern" "$log_file"; then
    fail "missing ${label}: ${pattern}"
  fi
}

reject_contains() {
  local pattern="$1"
  local label="$2"
  if grep -Fq -- "$pattern" "$log_file"; then
    fail "unexpected ${label}: ${pattern}"
  fi
}

check_common_failure_markers() {
  if grep -Eiq 'THROW_HARD|Fortran runtime error|Segmentation fault|Aborted|core dumped' "$log_file"; then
    fail "runtime failure marker found"
  fi
  if grep -Eq 'nonfinite=[[:space:]]*[1-9][0-9]*' "$log_file"; then
    fail "nonzero nonfinite diagnostic found"
  fi
}

check_run_outputs() {
  local run_dir="$1"
  [[ -n "$run_dir" ]] || return 0
  [[ -d "$run_dir" ]] || fail "RUN_DIR does not exist: $run_dir"

  if ! find "$run_dir" -maxdepth 2 -type d -iname '*abinitio2D*' | grep -q .; then
    fail "no abinitio2D output directory found under $run_dir"
  fi

  if ! find "$run_dir" -type f \( -iname '*frc*' -o -iname '*cavg*' -o -iname '*class*' -o -iname '*cls2D*' \) | grep -q .; then
    fail "no class-average/FRC-like output files found under $run_dir"
  fi
}

if [[ $# -lt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mode="$1"
log_file="$2"
run_dir="${3:-}"
case_name="${4:-unknown}"

[[ -f "$log_file" ]] || fail "log file does not exist: $log_file"

check_common_failure_markers
require_contains 'SIMPLE_ABINITIO2D NORMAL STOP' 'abinitio2D normal stop marker'

case "$mode" in
  baseline)
    reject_contains 'JOINT 2D SGD' 'joint-SGD marker in baseline log'
    reject_contains 'JOINT2D SGD' 'joint top-K marker in baseline log'
    reject_contains 'CAVG SGD UPDATE' 'joint CAVG update marker in baseline log'
    ;;
  joint)
    require_contains 'JOINT2D SGD TOPK: prob_align2D' 'prob_align2D top-K diagnostics'
    require_contains 'JOINT2D SGD TOPK: cluster2D' 'cluster2D top-K diagnostics'
    require_contains 'JOINT2D SGD LATENT' 'latent-logit diagnostics'
    require_contains 'JOINT2D SGD TOPK RANGES' 'top-K range diagnostics'
    require_contains 'JOINT2D SGD WINNER' 'top-K winner diagnostics'
    require_contains 'JOINT2D SGD INPL' 'in-plane refinement diagnostics'
    require_contains 'JOINT2D SGD INPL LOSSES' 'in-plane loss diagnostics'
    require_contains 'JOINT2D SGD SHIFT' 'shift refinement diagnostics'
    require_contains 'JOINT2D SGD BALANCE' 'class-balance diagnostics'
    require_contains 'JOINT2D SGD BALANCE SUPPORT' 'class-balance support diagnostics'
    require_contains 'JOINT2D SGD BALANCE PRIOR' 'class-balance prior diagnostics'
    require_contains 'JOINT2D SGD REFS' 'reference semantics diagnostics'
    require_contains 'CAVG SGD UPDATE' 'CAVG update diagnostics'
    require_contains 'CAVG SGD SUPPORT' 'CAVG support diagnostics'
    require_contains 'CAVG SGD NORMS' 'CAVG norm diagnostics'
    require_contains 'CAVG SGD RESTORE' 'CAVG restoration diagnostics'
    require_contains 'CAVG SGD RESTORE FRC' 'CAVG restoration FRC diagnostics'
    if grep -E 'JOINT2D SGD (TOPK|BALANCE|INPL|SHIFT)' "$log_file" | grep -Eq 'accepted=[[:space:]]*0([^0-9]|$)'; then
      fail "zero accepted joint diagnostic found for case ${case_name}"
    fi
    ;;
  *)
    fail "mode must be baseline or joint"
    ;;
esac

check_run_outputs "$run_dir"
echo "joint-SGD science log check passed: $mode $log_file"
