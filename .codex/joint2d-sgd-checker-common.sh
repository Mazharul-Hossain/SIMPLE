#!/usr/bin/env bash

# Shared checks for joint2D-SGD smoke/science log validators. This file is
# sourced by the checker entrypoints; keep CLI usage text in those wrappers.

fail() {
  echo "${joint2d_checker_label:-joint2D-SGD log check} failed: $*" >&2
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
  if [[ "${joint2d_check_global_nonfinite:-no}" == "yes" ]] &&
      grep -Eq 'nonfinite=[[:space:]]*[1-9][0-9]*' "$log_file"; then
    fail "nonzero nonfinite diagnostic found"
  fi
}

check_normal_stop() {
  require_contains 'SIMPLE_ABINITIO2D NORMAL STOP' 'abinitio2D normal stop marker'
}

check_baseline_log() {
  reject_contains 'JOINT 2D SGD' 'joint2D-SGD marker in baseline log'
  reject_contains 'JOINT2D SGD' 'joint top-K marker in baseline log'
  reject_contains 'CAVG SGD UPDATE' 'joint CAVG update marker in baseline log'
}

check_smoke_joint_log() {
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
}

check_science_joint_log() {
  local case_name="${1:-unknown}"
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
  if grep -E 'JOINT2D SGD (TOPK|BALANCE|INPL|SHIFT)' "$log_file" |
      grep -Eq 'accepted=[[:space:]]*0([^0-9]|$)'; then
    fail "zero accepted joint diagnostic found for case ${case_name}"
  fi
}

check_run_outputs() {
  local run_dir="$1"
  local include_cls2d="${2:-no}"
  local abinitio_dir=""
  local output_file=""
  local -a output_find=( -iname '*frc*' -o -iname '*cavg*' -o -iname '*class*' )

  [[ -n "$run_dir" ]] || return 0
  [[ -d "$run_dir" ]] || fail "RUN_DIR does not exist: $run_dir"

  abinitio_dir="$(find "$run_dir" -maxdepth 2 -type d -iname '*abinitio2D*' -print -quit)"
  if [[ -z "$abinitio_dir" ]]; then
    fail "no abinitio2D output directory found under $run_dir"
  fi

  if [[ "$include_cls2d" == "yes" ]]; then
    output_find+=( -o -iname '*cls2D*' )
  fi
  output_file="$(find "$run_dir" -type f \( "${output_find[@]}" \) -print -quit)"
  if [[ -z "$output_file" ]]; then
    fail "no class-average/FRC-like output files found under $run_dir"
  fi
}
