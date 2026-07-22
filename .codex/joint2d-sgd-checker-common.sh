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

check_stage3_shadow_assignment() {
  require_contains 'JOINT2D SGD ABSOLUTE FIT:' 'absolute best-fit diagnostics'
  require_contains 'JOINT2D SGD SHADOW SUPPORT:' 'shadow top-3 class-support diagnostics'
  if ! awk '
    /ABINITIO2D SGD STAGE: stage=terminal/ { stage = 99; next }
    /ABINITIO2D SGD STAGE: stage=[0-9]+/ {
      line = $0
      sub(/^.*stage=/, "", line)
      sub(/ .*/, "", line)
      stage = line + 0
      next
    }
    /JOINT2D SGD SHADOW SUPPORT:/ {
      samples = active = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^samples=/) { samples = $i; sub(/^samples=/, "", samples) }
        if ($i ~ /^active_classes=/) { active = $i; sub(/^active_classes=/, "", active) }
      }
      if (stage == 3 && samples + 0 > 0 && active + 0 > 0) seen_stage3++
    }
    END { if (seen_stage3 == 0) exit 1 }
  ' "$log_file"; then
    fail 'missing or empty observational assignment diagnostics during stage 3'
  fi
  if ! awk '
    /ABINITIO2D SGD STAGE: stage=terminal/ { stage = 99; next }
    /ABINITIO2D SGD STAGE: stage=[0-9]+/ {
      line = $0
      sub(/^.*stage=/, "", line)
      sub(/ .*/, "", line)
      stage = line + 0
      next
    }
    /PROB_ALIGN2D: sampled [0-9]+ particles/ && stage == 3 {
      expected = $0
      sub(/^.*sampled /, "", expected)
      sub(/ particles.*$/, "", expected)
      next
    }
    /JOINT2D SGD SHADOW SUPPORT:/ && stage == 3 {
      iteration = samples = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^iteration=/) { iteration = $i; sub(/^iteration=/, "", iteration) }
        if ($i ~ /^samples=/)   { samples   = $i; sub(/^samples=/,   "", samples) }
      }
      if (expected == "" || samples + 0 != expected + 0 || ++seen[iteration] != 1) exit 1
      complete++
    }
    END { if (complete == 0) exit 1 }
  ' "$log_file"; then
    fail 'stage-3 shadow diagnostics were split across half-batches or duplicated instead of covering the full sampled table once'
  fi
}

check_assignment_only_ablation() {
  require_contains 'JOINT2D SGD ABLATION: mode=assignment_only assignments=active cavg_update=freeze_restored_output' \
    'assignment-only runtime marker'
  if ! awk '
    /CAVG SGD UPDATE: joint assignment-only output freeze/ {
      seen++
      updated = preserved = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^updated=/) { updated = $i; sub(/^updated=/, "", updated) }
        if ($i ~ /^preserved=/) { preserved = $i; sub(/^preserved=/, "", preserved) }
      }
      if (updated == "" || preserved == "" || updated + 0 != 0 || preserved + 0 < 1) exit 1
    }
    END { if (seen == 0) exit 1 }
  ' "$log_file"; then
    fail 'assignment-only ablation changed a class image or lacked preservation diagnostics'
  fi
  require_contains 'CAVG SGD OUTPUT INVARIANT:' 'assignment-only restored-output invariant'
  if grep -F 'CAVG SGD OUTPUT INVARIANT:' "$log_file" | grep -Fvq 'compatible=T'; then
    fail 'assignment-only restored-output invariant failed'
  fi
  require_contains 'JOINT2D SGD ABLATION TERMINAL:' 'assignment-only terminal-output preservation marker'
  if grep -F 'JOINT2D SGD ABLATION TERMINAL:' "$log_file" | grep -Fvq 'preserved=T'; then
    fail 'assignment-only terminal output was regenerated instead of preserved'
  fi
}

check_assignment_only_mrc_invariant() {
  local run_dir="$1"
  local input_ref output_ref suffix input_path output_path
  local input_hash output_hash
  local compared=0
  [[ -n "$run_dir" ]] || return 0
  while read -r input_ref output_ref; do
    [[ -n "$input_ref" && -n "$output_ref" ]] || continue
    for suffix in '' '_even' '_odd'; do
      input_path="$(find "$run_dir" -type f -name "$(basename -- "${input_ref%.mrc}${suffix}.mrc")" -print -quit)"
      output_path="$(find "$run_dir" -type f -name "$(basename -- "${output_ref%.mrc}${suffix}.mrc")" -print -quit)"
      [[ -n "$input_path" && -n "$output_path" ]] || \
        fail "assignment-only MRC invariant could not locate ${input_ref%.mrc}${suffix}.mrc or ${output_ref%.mrc}${suffix}.mrc"
      input_hash="$(tail -c +1025 "$input_path" | sha256sum | awk '{print $1}')"
      output_hash="$(tail -c +1025 "$output_path" | sha256sum | awk '{print $1}')"
      if [[ "$(wc -c <"$input_path")" -ne "$(wc -c <"$output_path")" || \
            "$input_hash" != "$output_hash" ]]; then
        fail "assignment-only MRC payload changed: $input_path -> $output_path"
      fi
      compared=$((compared + 1))
    done
  done < <(awk '
    /JOINT2D SGD REFS IN: cluster2D/ {
      input = $0
      sub(/^.*refs=/, "", input)
      next
    }
    /JOINT2D SGD REFS OUT: cluster2D/ && input != "" {
      output = $0
      sub(/^.*refs=/, "", output)
      sub(/ .*/, "", output)
      print input, output
      input = ""
    }
  ' "$log_file")
  [[ "$compared" -gt 0 ]] || fail 'assignment-only MRC invariant found no joint input/output reference pairs'
}

check_likelihood_unit_continuity() {
  require_contains 'JOINT2D SGD LIKELIHOOD UNITS: context=prob_align2D_provisional' \
    'provisional likelihood-unit diagnostics'
  require_contains 'JOINT2D SGD LIKELIHOOD UNITS: context=cluster2D_final' \
    'final likelihood-unit diagnostics'
  require_contains 'JOINT2D SGD CALIBRATION HANDOFF:' \
    'provisional-to-refinement calibration handoff diagnostics'
  if grep -F 'JOINT2D SGD CALIBRATION HANDOFF:' "$log_file" | grep -Fvq 'active=provisional_scale'; then
    fail 'refinement did not retain the provisional Gaussian-NLL calibration'
  fi
  if ! awk '
    /JOINT2D SGD SCHEDULE:/ {
      joint_active = ($0 ~ /mode=joint/)
      next
    }
    /JOINT2D SGD LIKELIHOOD UNITS:/ {
      context = units = active = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^context=/) { context = $i; sub(/^context=/, "", context) }
        if ($i ~ /^units=/)   { units   = $i; sub(/^units=/,   "", units) }
        if ($i ~ /^active=/)  { active  = $i; sub(/^active=/,  "", active) }
      }
      if (joint_active && context == "prob_align2D_provisional") {
        provisional++
        if (units != "gaussian_nll" || active != "T") bad = 1
      }
      if (joint_active && context == "cluster2D_final") {
        final++
        if (units != "gaussian_nll" || active != "T") bad = 1
      }
    }
    END {
      if (bad || provisional == 0 || final == 0 || provisional != final) exit 1
    }
  ' "$log_file"; then
    fail 'provisional/final likelihood-unit discontinuity or inactive Gaussian-NLL calibration found'
  fi
}

check_posterior_mode() {
  # Older completed logs predate this marker and remain re-checkable. New
  # executables emit it at both provisional and final posterior boundaries.
  grep -Fq 'JOINT2D SGD POSTERIOR MODE:' "$log_file" || return 0
  if ! awk '
    /JOINT2D SGD POSTERIOR MODE:/ {
      inner = raw = temperature = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^inner_its=/)   { inner = $i; sub(/^inner_its=/, "", inner) }
        if ($i ~ /^raw_likelihood=/) { raw = $i; sub(/^raw_likelihood=/, "", raw) }
        if ($i ~ /^temperature=/) { temperature = $i; sub(/^temperature=/, "", temperature) }
      }
      if (inner == "" || raw == "" || temperature != "none") exit 1
      inner += 0
      if ((inner == 0 && raw != "T") || (inner > 0 && raw != "F")) exit 1
      seen++
    }
    END { if (seen == 0) exit 1 }
  ' "$log_file"; then
    fail 'posterior calibration-state diagnostics are inconsistent or use temperature'
  fi
}

check_score_calibration() {
  grep -Fq 'JOINT2D SGD SCORE CALIBRATION:' "$log_file" || return 0
  require_contains 'JOINT2D SGD SCORE SCALE TRANSPORT:' 'Gaussian-NLL assignment scale transport diagnostics'
  if ! awk '
    function value_after_key(i, prefix, value) {
      value = $i
      sub(prefix, "", value)
      if (value == "" && i < NF) value = $(i + 1)
      return value
    }
    /JOINT2D SGD SCORE SCALE TRANSPORT:/ {
      samples = min_scale = max_scale = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^samples=/) samples = value_after_key(i, "^samples=")
        if ($i ~ /^min=/) min_scale = value_after_key(i, "^min=")
        if ($i ~ /^max=/) max_scale = value_after_key(i, "^max=")
      }
      if (samples == "" || min_scale == "" || max_scale == "" || samples + 0 < 1 ||
          min_scale + 0 <= 0 || max_scale + 0 < min_scale + 0) exit 1
      seen++
    }
    END { if (seen == 0) exit 1 }
  ' "$log_file"; then
    fail 'Gaussian-NLL assignment scale transport is invalid or unparseable'
  fi
  if ! awk '
    /SCORE \[0,1\]/ && /AVG\/SDEV\/MIN\/MAX:/ {
      seen++
      values = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ /AVG\/SDEV\/MIN\/MAX:/) { values = 1; continue }
        if (!values) continue
        token = $i
        gsub(/[^0-9.eE+-]/, "", token)
        if (token != "" && (token + 0) > 0) nonzero = 1
      }
    }
    END { if (seen == 0 || !nonzero) exit 1 }
  ' "$log_file"; then
    fail 'Gaussian-NLL score calibration is missing a nonzero [0,1] particle score'
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
    function value_after_key(i, prefix, value) {
      value = $i
      sub(prefix, "", value)
      if (value == "" && i < NF) value = $(i + 1)
      return value
    }
    /JOINT2D SGD LATENT: cluster2D final reliability/ {
      seen++
      initial = final = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^avg_initial_loss=/) initial = value_after_key(i, "^avg_initial_loss=")
        if ($i ~ /^avg_final_loss=/)   final   = value_after_key(i, "^avg_final_loss=")
      }
      if (initial == "" || final == "") exit 1
      initial += 0
      final += 0
      if ((initial <= 0 && final > 1.0e-6) || (initial > 0 && final > 100.0 * initial)) exit 1
      if (min_final == "" || final < min_final) min_final = final
      if (max_final == "" || final > max_final) max_final = final
    }
    END {
      if (seen == 0) exit 1
      if ((min_final <= 0 && max_final > 1.0e-6) || (min_final > 0 && max_final > 100.0 * min_final)) exit 1
    }
  ' "$log_file"; then
    fail 'missing final latent-loss diagnostics or within/across-update loss increased by at least two orders of magnitude'
  fi
}

check_class_starvation() {
  require_contains 'JOINT2D SGD BALANCE SUPPORT: cluster2D final' 'final class-support diagnostics'
  if ! awk '
    function value_after_key(i, prefix, value) {
      value = $i
      sub(prefix, "", value)
      if (value == "" && i < NF) value = $(i + 1)
      return value
    }
    /JOINT2D SGD BALANCE SUPPORT: cluster2D final/ {
      active = zero = support_max = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^active_classes=/)      active      = value_after_key(i, "^active_classes=")
        if ($i ~ /^zero_support_classes=/) zero       = value_after_key(i, "^zero_support_classes=")
        if ($i ~ /^support_max=/)         support_max = value_after_key(i, "^support_max=")
      }
      if (active == "" || zero == "" || support_max == "") exit 1
      active += 0
      zero += 0
      support_max += 0
      if (seen == 0) {
        first_active = active
        first_zero = zero
        first_support_max = support_max
        nclasses = active + zero
      }
      last_active = active
      last_zero = zero
      last_support_max = support_max
      seen++
    }
    END {
      if (seen == 0 || nclasses < 1 || first_active < 1) exit 1
      zero_growth_limit = int(nclasses / 10)
      if (zero_growth_limit < 1) zero_growth_limit = 1
      if (100 * last_active < 80 * first_active) exit 1
      if (last_zero > first_zero + zero_growth_limit) exit 1
      if (first_support_max > 0 && last_support_max > 2.0 * first_support_max) exit 1
    }
  ' "$log_file"; then
    fail 'class starvation detected: active support contracted, zero-support classes grew, or support concentration doubled'
  fi
}

check_nonzero_balance_prior() {
  require_contains 'JOINT2D SGD BALANCE: cluster2D final' 'nonzero balance-weight diagnostics'
  if ! awk '
    function value_after_key(i, prefix, value) {
      value = $i
      sub(prefix, "", value)
      if (value == "" && i < NF) value = $(i + 1)
      return value
    }
    /JOINT2D SGD BALANCE: cluster2D final/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^weight=/ && value_after_key(i, "^weight=") + 0 > 0) positive_weight++
      }
    }
    /JOINT2D SGD BALANCE PRIOR: cluster2D final/ {
      prior_min = prior_max = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^prior_min=/) prior_min = value_after_key(i, "^prior_min=")
        if ($i ~ /^prior_max=/) prior_max = value_after_key(i, "^prior_max=")
      }
      if (prior_min != "" && prior_max != "" && (prior_min + 0 < 0 || prior_max + 0 > 0)) active_prior++
    }
    END { if (positive_weight == 0 || active_prior == 0) exit 1 }
  ' "$log_file"; then
    fail 'controlled balance case did not activate a nonzero class-occupancy prior'
  fi
}

check_cavg_update_trust() {
  require_contains 'CAVG SGD TRUST:' 'CAVG trust-bound diagnostics'
  if grep -Eq 'CAVG SGD UPDATE:.*trust_rejected=[[:space:]]*[1-9][0-9]*' "$log_file"; then
    fail 'one or more half-class updates exceeded the trust bound'
  fi
  if ! awk '
    function value_after_key(i, prefix, value) {
      value = $i
      sub(prefix, "", value)
      if (value == "" && i < NF) value = $(i + 1)
      return value
    }
    /CAVG SGD NORMS: joint/ {
      have_rel = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^rel_step=/) {
          rel = value_after_key(i, "^rel_step=")
          rel += 0
          have_rel = 1
        }
      }
    }
    /CAVG SGD TRUST: joint/ {
      proposed = applied = bound = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^proposed_rel_step_max=/) proposed = value_after_key(i, "^proposed_rel_step_max=")
        if ($i ~ /^applied_rel_step_max=/)  applied  = value_after_key(i, "^applied_rel_step_max=")
        if ($i ~ /^bound=/)                 bound    = value_after_key(i, "^bound=")
      }
      if (proposed == "" || bound == "" || !have_rel) exit 1
      if (applied == "") applied = proposed
      proposed += 0
      applied += 0
      bound += 0
      if (applied > bound || rel > bound) exit 1
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

check_checkpoint_baseline_log() {
  check_abinitio_stage_matrix off off
  check_stage3_shadow_assignment
  reject_contains 'CAVG SGD UPDATE' 'class-average SGD update in checkpoint-matched baseline'
  if ! awk '
    /ABINITIO2D SGD STAGE: stage=terminal/ { stage = 99; next }
    /ABINITIO2D SGD STAGE: stage=[0-9]+/ {
      line = $0
      sub(/^.*stage=/, "", line)
      sub(/ .*/, "", line)
      stage = line + 0
      next
    }
    /JOINT2D SGD (SCHEDULE|TOPK|LATENT|WINNER|INPL|SHIFT|BALANCE|REFS|PARTICLE SUPPORT)|CAVG SGD/ {
      if (stage >= 4 || stage == 99) exit 1
    }
  ' "$log_file"; then
    fail 'joint-SGD update diagnostic found after stage 3 in checkpoint-matched baseline'
  fi
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
  require_contains 'JOINT2D SGD NLL CALIBRATION: sigma2=variance_per_real_component estimator=sum_abs2/(2*pftsz)' \
    'derived Gaussian-NLL calibration diagnostics'
  require_contains 'JOINT2D SGD NLL SCALE QUANTILES:' 'shadow Gaussian-NLL scale diagnostics'
  require_contains 'JOINT2D SGD NLL SHADOW POSTERIOR:' 'shadow Gaussian-NLL posterior diagnostics'
  check_stage3_shadow_assignment
  require_contains 'JOINT2D SGD PARTICLE SUPPORT:' 'particle-support diagnostics'
  require_contains 'CAVG SGD UPDATE' 'CAVG update diagnostics'
  require_contains 'CAVG SGD NORMS' 'CAVG norm diagnostics'
  require_contains 'CAVG SGD TRUST' 'CAVG trust-bound diagnostics'
  require_contains 'CAVG SGD RESTORE' 'CAVG restoration diagnostics'
  require_contains 'CAVG SGD REPRESENTATION: old_space=restored_real batch_space=restored_real preconditioner=identity compatible=T' \
    'restored-output representation/unit invariant'
  check_likelihood_unit_continuity
  check_posterior_mode
  check_score_calibration
  check_refinement_deltas
  check_final_loss_scale
  check_class_starvation
  check_cavg_update_trust
  check_soft_acceptance_observed
  if grep -Eq 'nonfinite=[[:space:]]*[1-9][0-9]*' "$log_file"; then
    fail "nonzero nonfinite diagnostic found"
  fi
}

check_stream_joint_log() {
  local stage4_mode="${1:-alternate}"
  check_abinitio_stage_matrix "$stage4_mode" on
  check_no_joint_outside_late_stages
  check_stage4_iteration_policy "$stage4_mode"
  check_stage3_shadow_assignment
  require_contains 'JOINT2D SGD STREAM CONFIG:' 'stream Design-A configuration'
  require_contains 'JOINT2D SGD PATH: stream hard class-angle assignment plus bounded direct shift gradients' \
    'stream path activation diagnostics'
  require_contains 'JOINT2D SGD STREAM ACTIVE:' 'active streaming iteration diagnostics'
  reject_contains 'JOINT 2D SGD: consuming top-K assignment from prob_align2D' \
    'probabilistic top-K transport in stream mode'
  reject_contains 'JOINT2D SGD TOPK:' 'top-K diagnostics in stream mode'
  require_contains 'standard greedy class-angle search; direct shift gradients active' \
    'stream greedy search diagnostics'
  require_contains 'SIMPLE_ABINITIO2D NORMAL STOP' 'normal completion'
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
  require_contains 'JOINT2D SGD NLL CALIBRATION: sigma2=variance_per_real_component estimator=sum_abs2/(2*pftsz)' \
    'derived Gaussian-NLL calibration diagnostics'
  require_contains 'JOINT2D SGD NLL SCALE QUANTILES:' 'shadow Gaussian-NLL scale diagnostics'
  require_contains 'JOINT2D SGD NLL SHADOW POSTERIOR:' 'shadow Gaussian-NLL posterior diagnostics'
  check_stage3_shadow_assignment
  require_contains 'JOINT2D SGD PARTICLE SUPPORT:' 'particle-support diagnostics'
  require_contains 'JOINT2D SGD INPL' 'in-plane refinement diagnostics'
  require_contains 'JOINT2D SGD INPL LOSSES' 'in-plane loss diagnostics'
  require_contains 'JOINT2D SGD SHIFT' 'shift refinement diagnostics'
  require_contains 'JOINT2D SGD SHIFT OPTIMIZER:' 'bounded shift-optimizer configuration'
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
  require_contains 'component=provisional_scoring' 'provisional-scoring profile diagnostics'
  require_contains 'component=candidate_transport' 'candidate-transport profile diagnostics'
  require_contains 'component=softmax_transport' 'SoftMax profile diagnostics'
  require_contains 'component=inplane_refinement' 'in-plane profile diagnostics'
  require_contains 'component=shift_refinement' 'shift-minimizer profile diagnostics'
  require_contains 'optimizer=direct_gradient' 'bounded direct-gradient shift diagnostics'
  require_contains 'component=class_update_restoration' 'class-update/restoration profile diagnostics'
  check_likelihood_unit_continuity
  check_posterior_mode
  check_score_calibration
  check_shift_provenance
  check_refinement_roundtrip
  check_refinement_deltas
  check_final_loss_scale
  check_class_starvation
  check_cavg_update_trust
  check_soft_acceptance_observed
  if [[ "$case_name" == balance_* ]]; then
    check_nonzero_balance_prior
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
