#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  .codex/check-joint-sgd-smoke-log.sh baseline <LOG> [RUN_DIR]
  .codex/check-joint-sgd-smoke-log.sh joint    <LOG> [RUN_DIR]

Checks the shared-memory joint-SGD smoke logs produced by
.codex/run-joint-sgd-smoke.sh. RUN_DIR is optional; when provided, the checker
also looks for abinitio2D output directories and FRC/class-average-like files.
EOF
}

fail() {
  echo "joint-SGD smoke log check failed: $*" >&2
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
}

check_run_outputs() {
  local run_dir="$1"
  [[ -n "$run_dir" ]] || return 0
  [[ -d "$run_dir" ]] || fail "RUN_DIR does not exist: $run_dir"

  if ! find "$run_dir" -maxdepth 2 -type d -iname '*abinitio2D*' | grep -q .; then
    fail "no abinitio2D output directory found under $run_dir"
  fi

  if ! find "$run_dir" -type f \( -iname '*frc*' -o -iname '*cavg*' -o -iname '*class*' \) | grep -q .; then
    fail "no FRC/class-average-like output files found under $run_dir"
  fi
}

if [[ $# -lt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mode="$1"
log_file="$2"
run_dir="${3:-}"

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
    require_contains 'JOINT2D SGD LATENT' 'latent diagnostics'
    require_contains 'JOINT2D SGD TOPK RANGES' 'top-K range diagnostics'
    require_contains 'CAVG SGD UPDATE' 'CAVG update diagnostics'
    require_contains 'CAVG SGD NORMS' 'CAVG norm diagnostics'
    require_contains 'CAVG SGD RESTORE' 'CAVG restoration diagnostics'
    if grep -Eq 'nonfinite=[[:space:]]*[1-9][0-9]*' "$log_file"; then
      fail "nonzero nonfinite diagnostic found"
    fi
    if grep -Eiq 'zero accepted|accepted=[[:space:]]*0([^0-9]|$)' "$log_file"; then
      fail "zero accepted top-K diagnostic found"
    fi
    ;;
  *)
    fail "mode must be baseline or joint"
    ;;
esac

check_run_outputs "$run_dir"
echo "joint-SGD smoke log check passed: $mode $log_file"
