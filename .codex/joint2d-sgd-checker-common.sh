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
  require_contains 'JOINT2D SGD RELIABILITY: cluster2D final reliability' \
    'final joint SGD reliability diagnostics'
  if ! grep -Eq 'JOINT2D SGD RELIABILITY: cluster2D final reliability.*soft_accepted=[[:space:]]*[1-9][0-9]*' "$log_file"; then
    fail 'no soft-accepted particles observed at any final joint SGD update boundary'
  fi
  if grep -Fq 'DISTRIBUTED EXECUTION' "$log_file"; then
    require_contains 'JOINT2D SGD DISTR FINAL AGGREGATE:' \
      'distributed final reliability aggregate'
  fi
}

check_likelihood_unit_continuity() {
  require_contains 'JOINT2D SGD LIKELIHOOD UNITS: context=prob_align2D_provisional' \
    'provisional likelihood-unit diagnostics'
  require_contains 'JOINT2D SGD LIKELIHOOD UNITS: context=cluster2D_final' \
    'final likelihood-unit diagnostics'
  if ! awk '
    /JOINT2D SGD LIKELIHOOD UNITS:/ {
      context = units = active = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^context=/) { context = $i; sub(/^context=/, "", context) }
        if ($i ~ /^units=/)   { units   = $i; sub(/^units=/,   "", units) }
        if ($i ~ /^active=/)  { active  = $i; sub(/^active=/,  "", active) }
      }
      if (context == "prob_align2D_provisional" || context == "cluster2D_final") {
        if (units != "gaussian_nll" || active != "T") exit 1
      }
    }
  ' "$log_file"; then
    fail 'provisional/final likelihood-unit discontinuity or inactive Gaussian-NLL calibration found'
  fi
}

check_refinement_deltas() {
  require_contains 'JOINT2D SGD INPL:' 'in-plane refinement diagnostics'
  if ! awk '
    /JOINT2D SGD INPL:/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^negative_delta=/) {
          value = $i
          sub(/^negative_delta=/, "", value)
          if ((value + 0) > 0) exit 1
        }
      }
    }
  ' "$log_file"; then
    fail 'negative in-plane refinement delta found'
  fi
}

check_shift_provenance() {
  require_contains 'JOINT2D SGD SHIFT PROVENANCE:' 'candidate shift-provenance diagnostics'
  require_contains 'JOINT2D SGD SHIFT CONVENTION:' 'candidate shift-convention diagnostics'
  if ! awk '
    /JOINT2D SGD SHIFT PROVENANCE:/ {
      seen++
      total = invalid = missing = nonfinite_delta = nonfinite_base = 0
      for (i = 1; i <= NF; i++) {
        value = $i
        if ($i ~ /^class_refined=/)    { sub(/^class_refined=/, "", value); total += value + 0 }
        if ($i ~ /^materialized_seed=/) { sub(/^materialized_seed=/, "", value); total += value + 0 }
        if ($i ~ /^genuine_zero=/)     { sub(/^genuine_zero=/, "", value); total += value + 0 }
        if ($i ~ /^invalid=/)          { sub(/^invalid=/, "", value); invalid = value + 0 }
        if ($i ~ /^missing_shift=/)    { sub(/^missing_shift=/, "", value); missing = value + 0 }
        if ($i ~ /^nonfinite_delta=/)  { sub(/^nonfinite_delta=/, "", value); nonfinite_delta = value + 0 }
        if ($i ~ /^nonfinite_base=/)   { sub(/^nonfinite_base=/, "", value); nonfinite_base = value + 0 }
      }
      if (total < 1 || invalid > 0 || missing > 0 || nonfinite_delta > 0 || nonfinite_base > 0) exit 1
    }
    END { if (seen == 0) exit 1 }
  ' "$log_file"; then
    fail 'invalid, missing, or nonfinite candidate shift provenance found'
  fi
}

check_refinement_roundtrip() {
  require_contains 'JOINT2D SGD INPL ROUNDTRIP:' 'in-plane stored-candidate round-trip diagnostics'
  require_contains 'JOINT2D SGD SHIFT ROUNDTRIP:' 'shift stored-candidate round-trip diagnostics'
  if ! awk '
    /JOINT2D SGD (INPL|SHIFT) ROUNDTRIP:/ {
      seen++
      checked = mismatch = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^checked=/)  { checked = $i; sub(/^checked=/, "", checked) }
        if ($i ~ /^mismatch=/) { mismatch = $i; sub(/^mismatch=/, "", mismatch) }
      }
      if (checked == "" || mismatch == "" || (checked + 0) < 1 || (mismatch + 0) > 0) exit 1
    }
    END { if (seen == 0) exit 1 }
  ' "$log_file"; then
    fail 'stored candidate distance/shift round-trip invariant failed'
  fi
}

check_final_loss_scale() {
  if ! awk '
    /JOINT2D SGD LATENT: cluster2D final reliability/ {
      seen++
      initial = final = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^avg_initial_loss=/) { initial = $i; sub(/^avg_initial_loss=/, "", initial) }
        if ($i ~ /^avg_final_loss=/)   { final   = $i; sub(/^avg_final_loss=/,   "", final) }
      }
      if (initial == "" || final == "") exit 1
      initial += 0
      final += 0
      if ((initial <= 0 && final > 1.0e-6) || (initial > 0 && final > 100.0 * initial)) exit 1
    }
    END { if (seen == 0) exit 1 }
  ' "$log_file"; then
    fail 'missing final latent-loss diagnostics or final loss increased by at least two orders of magnitude'
  fi
}

check_cavg_update_trust() {
  require_contains 'CAVG SGD TRUST:' 'CAVG trust-bound diagnostics'
  if grep -Eq 'CAVG SGD UPDATE:.*trust_rejected=[[:space:]]*[1-9][0-9]*' "$log_file"; then
    fail 'one or more half-class updates exceeded the trust bound'
  fi
  if ! awk '
    /CAVG SGD NORMS:/ {
      have_rel = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^rel_step=/) {
          rel = $i
          sub(/^rel_step=/, "", rel)
          rel += 0
          have_rel = 1
        }
      }
    }
    /CAVG SGD TRUST:/ {
      proposed = bound = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^proposed_rel_step_max=/) {
          proposed = $i
          sub(/^proposed_rel_step_max=/, "", proposed)
        }
        if ($i ~ /^bound=/) { bound = $i; sub(/^bound=/, "", bound) }
      }
      if (proposed == "" || bound == "" || !have_rel) exit 1
      proposed += 0
      bound += 0
      if (proposed > bound || rel > bound) exit 1
      have_rel = 0
    }
    END { if (have_rel) exit 1 }
  ' "$log_file"; then
    fail 'excessive or unparseable relative class-step diagnostic found'
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
  require_contains "JOINT2D SGD TOPK: prob_align2D provisional reliability topk=${expected_topk}" \
    "prob_align2D top-K=${expected_topk} runtime diagnostics"
  require_contains "JOINT2D SGD TOPK: cluster2D provisional reliability topk=${expected_topk}" \
    "cluster2D top-K=${expected_topk} runtime diagnostics"
  require_contains "JOINT2D SGD TOPK: cluster2D final reliability topk=${expected_topk}" \
    "final cluster2D top-K=${expected_topk} runtime diagnostics"
  require_contains 'JOINT2D SGD LATENT' 'latent diagnostics'
  require_contains 'JOINT2D SGD TOPK RANGES' 'top-K range diagnostics'
  require_contains 'JOINT2D SGD SOFTMAX:' 'SoftMax normalization diagnostics'
  require_contains 'JOINT2D SGD WEIGHTS:' 'rank-wise SoftMax weight diagnostics'
  require_contains 'JOINT2D SGD NLL SHADOW MODEL:' 'shadow Gaussian-NLL model diagnostics'
  require_contains 'JOINT2D SGD NLL SCALE QUANTILES:' 'shadow Gaussian-NLL scale diagnostics'
  require_contains 'JOINT2D SGD NLL SHADOW POSTERIOR:' 'shadow Gaussian-NLL posterior diagnostics'
  require_contains 'JOINT2D SGD PARTICLE SUPPORT:' 'particle-support diagnostics'
  require_contains 'CAVG SGD UPDATE' 'CAVG update diagnostics'
  require_contains 'CAVG SGD NORMS' 'CAVG norm diagnostics'
  require_contains 'CAVG SGD TRUST' 'CAVG trust-bound diagnostics'
  require_contains 'CAVG SGD RESTORE' 'CAVG restoration diagnostics'
  check_likelihood_unit_continuity
  check_refinement_deltas
  check_final_loss_scale
  check_cavg_update_trust
  check_soft_acceptance_observed
  if grep -Eq 'nonfinite=[[:space:]]*[1-9][0-9]*' "$log_file"; then
    fail "nonzero nonfinite diagnostic found"
  fi
}

check_science_joint_log() {
  local case_name="${1:-unknown}"
  local stage4_mode="${2:-alternate}"
  check_abinitio_stage_matrix "$stage4_mode" on
  check_no_joint_outside_late_stages
  check_stage4_iteration_policy "$stage4_mode"
  require_contains 'JOINT2D SGD TOPK: prob_align2D provisional reliability' 'prob_align2D provisional diagnostics'
  require_contains 'JOINT2D SGD TOPK: cluster2D provisional reliability' 'cluster2D provisional diagnostics'
  require_contains 'JOINT2D SGD TOPK: cluster2D final reliability' 'cluster2D final diagnostics'
  require_contains 'JOINT2D SGD LATENT' 'latent-logit diagnostics'
  require_contains 'JOINT2D SGD TOPK RANGES' 'top-K range diagnostics'
  require_contains 'JOINT2D SGD WINNER' 'top-K winner diagnostics'
  require_contains 'JOINT2D SGD SOFTMAX:' 'SoftMax normalization diagnostics'
  require_contains 'JOINT2D SGD WEIGHTS:' 'rank-wise SoftMax weight diagnostics'
  require_contains 'JOINT2D SGD NLL SHADOW MODEL:' 'shadow Gaussian-NLL model diagnostics'
  require_contains 'JOINT2D SGD NLL SCALE QUANTILES:' 'shadow Gaussian-NLL scale diagnostics'
  require_contains 'JOINT2D SGD NLL SHADOW POSTERIOR:' 'shadow Gaussian-NLL posterior diagnostics'
  require_contains 'JOINT2D SGD PARTICLE SUPPORT:' 'particle-support diagnostics'
  require_contains 'JOINT2D SGD INPL' 'in-plane refinement diagnostics'
  require_contains 'JOINT2D SGD INPL LOSSES' 'in-plane loss diagnostics'
  require_contains 'JOINT2D SGD SHIFT' 'shift refinement diagnostics'
  require_contains 'JOINT2D SGD SHIFT PROVENANCE' 'candidate shift-provenance diagnostics'
  require_contains 'JOINT2D SGD BALANCE' 'class-balance diagnostics'
  require_contains 'JOINT2D SGD BALANCE SUPPORT' 'class-balance support diagnostics'
  require_contains 'JOINT2D SGD BALANCE PRIOR' 'class-balance prior diagnostics'
  require_contains 'JOINT2D SGD REFS' 'reference semantics diagnostics'
  require_contains 'CAVG SGD UPDATE' 'CAVG update diagnostics'
  require_contains 'CAVG SGD SUPPORT' 'CAVG support diagnostics'
  require_contains 'CAVG SGD NORMS' 'CAVG norm diagnostics'
  require_contains 'CAVG SGD TRUST' 'CAVG trust-bound diagnostics'
  require_contains 'CAVG SGD RESTORE' 'CAVG restoration diagnostics'
  require_contains 'CAVG SGD RESTORE FRC' 'CAVG restoration FRC diagnostics'
  check_likelihood_unit_continuity
  check_shift_provenance
  check_refinement_roundtrip
  check_refinement_deltas
  check_final_loss_scale
  check_cavg_update_trust
  check_soft_acceptance_observed
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
