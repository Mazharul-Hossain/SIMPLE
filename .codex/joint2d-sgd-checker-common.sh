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

check_abinitio_stage_matrix() {
  local stage4_mode="$1"
  local late_mode="$2"
  require_contains 'ABINITIO2D SGD STAGE: stage=1 refine=snhc_smpl prob_assign=inactive ml_reg=no activation=off' 'stage-1 baseline policy'
  require_contains 'ABINITIO2D SGD STAGE: stage=2 refine=snhc_smpl prob_assign=inactive ml_reg=yes activation=off' 'stage-2 baseline policy'
  require_contains 'ABINITIO2D SGD STAGE: stage=3 refine=prob_snhc prob_assign=likelihood ml_reg=yes activation=off' 'stage-3 baseline policy'
  require_contains "ABINITIO2D SGD STAGE: stage=4 refine=prob_snhc prob_assign=likelihood ml_reg=yes activation=${stage4_mode}" 'stage-4 policy'
  require_contains "ABINITIO2D SGD STAGE: stage=5 refine=prob_snhc prob_assign=likelihood ml_reg=yes activation=${late_mode}" 'stage-5 policy'
  require_contains "ABINITIO2D SGD STAGE: stage=6 refine=prob prob_assign=likelihood ml_reg=yes activation=${late_mode}" 'stage-6 policy'
  if grep -Fq 'ABINITIO2D SGD STAGE: stage=terminal' "$log_file"; then
    require_contains 'ABINITIO2D SGD STAGE: stage=terminal refine=prob prob_assign=likelihood ml_reg=yes activation=off' 'terminal SGD-off policy'
  fi
}

check_no_joint_outside_late_stages() {
  if ! awk '
    /ABINITIO2D SGD STAGE: stage=terminal/ { stage = 99; next }
    /ABINITIO2D SGD STAGE: stage=[0-9]+/ {
      line = $0
      sub(/^.*stage=/, "", line)
      sub(/ .*/, "", line)
      stage = line + 0
      next
    }
    /JOINT2D SGD (SCHEDULE|TOPK|LATENT|WINNER|INPL|SHIFT|BALANCE|REFS)/ {
      if ((stage >= 1 && stage <= 3) || stage == 99) exit 1
    }
  ' "$log_file"; then
    fail 'joint-SGD diagnostic found in stages 1-3 or the terminal pass'
  fi
}

check_stage4_iteration_policy() {
  local stage4_mode="$1"
  local count=0
  local line stage_iter actual expected
  case "$stage4_mode" in
    off)
      return 0
      ;;
    alternate|on) ;;
    *) fail "unsupported expected stage-4 mode: $stage4_mode" ;;
  esac
  while IFS= read -r line; do
    stage_iter="$(sed -n 's/.*stage_iter=\([0-9][0-9]*\).*/\1/p' <<<"$line")"
    actual="$(sed -n 's/.*mode=\([^[:space:]]*\).*/\1/p' <<<"$line")"
    [[ -n "$stage_iter" && -n "$actual" ]] || fail "unparseable stage-4 schedule line: $line"
    if [[ "$stage4_mode" == "on" || $((stage_iter % 2)) -eq 0 ]]; then
      expected="joint"
    else
      expected="sgd_off"
    fi
    [[ "$actual" == "$expected" ]] || fail "stage-4 ${stage4_mode} iteration ${stage_iter}: expected ${expected}, got ${actual}"
    count=$((count + 1))
  done < <(grep -F 'JOINT2D SGD SCHEDULE:' "$log_file" | grep -F "policy=${stage4_mode}" || true)
  [[ "$count" -gt 0 ]] || fail "no stage-4 ${stage4_mode} schedule diagnostics found"
}

check_soft_acceptance_observed() {
  require_contains 'JOINT2D SGD RELIABILITY:' 'joint SGD reliability diagnostics'
  if ! grep -Eq 'JOINT2D SGD RELIABILITY:.*soft_accepted=[[:space:]]*[1-9][0-9]*' "$log_file"; then
    fail 'no soft-accepted particles observed; every joint SGD reliability diagnostic used zero soft assignments'
  fi
}

check_baseline_log() {
  check_abinitio_stage_matrix off off
  reject_contains 'JOINT 2D SGD' 'joint2D-SGD marker in baseline log'
  reject_contains 'JOINT2D SGD' 'joint top-K marker in baseline log'
  reject_contains 'CAVG SGD UPDATE' 'joint CAVG update marker in baseline log'
}

check_smoke_joint_log() {
  local stage4_mode="${1:-alternate}"
  local expected_topk="${2:-3}"
  check_abinitio_stage_matrix "$stage4_mode" on
  check_no_joint_outside_late_stages
  check_stage4_iteration_policy "$stage4_mode"
  require_contains "JOINT2D SGD TOPK: prob_align2D topk=${expected_topk}" \
    "prob_align2D top-K=${expected_topk} runtime diagnostics"
  require_contains "JOINT2D SGD TOPK: cluster2D topk=${expected_topk}" \
    "cluster2D top-K=${expected_topk} runtime diagnostics"
  require_contains 'JOINT2D SGD LATENT' 'latent diagnostics'
  require_contains 'JOINT2D SGD TOPK RANGES' 'top-K range diagnostics'
  require_contains 'CAVG SGD UPDATE' 'CAVG update diagnostics'
  require_contains 'CAVG SGD NORMS' 'CAVG norm diagnostics'
  require_contains 'CAVG SGD RESTORE' 'CAVG restoration diagnostics'
  check_soft_acceptance_observed
  if grep -Eq 'nonfinite=[[:space:]]*[1-9][0-9]*' "$log_file"; then
    fail "nonzero nonfinite diagnostic found"
  fi
  if grep -Eiq 'zero accepted|accepted=[[:space:]]*0([^0-9]|$)' "$log_file"; then
    fail "zero accepted top-K diagnostic found"
  fi
}

check_science_joint_log() {
  local case_name="${1:-unknown}"
  local stage4_mode="${2:-alternate}"
  check_abinitio_stage_matrix "$stage4_mode" on
  check_no_joint_outside_late_stages
  check_stage4_iteration_policy "$stage4_mode"
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
  check_soft_acceptance_observed
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
