#!/usr/bin/env bash
set -Eeuo pipefail
trap 'status=$?; echo "joint2D-SGD science runner failed at line ${LINENO}: ${BASH_COMMAND} (exit ${status})" >&2' ERR

usage() {
  cat <<'EOF'
Usage:
  .codex/run-joint2d-sgd-science.sh --check
  .codex/run-joint2d-sgd-science.sh --list-cases
  .codex/run-joint2d-sgd-science.sh [--root ROOT] [--shared-stage3] --case CASE [--case CASE ...]
  .codex/run-joint2d-sgd-science.sh --shared-stage3-from PATH --case CASE [--case CASE ...]
  .codex/run-joint2d-sgd-science.sh --profile shift_selection [--reps 3]
  .codex/run-joint2d-sgd-science.sh --prepare-build
  .codex/run-joint2d-sgd-science.sh --prepare-betagal-extract
  .codex/run-joint2d-sgd-science.sh

Workstation layout:
  Build copy:  ~/Projects/SIMPLE_joint2d_sgd_build
  Test runs:   ~/Projects/simple_joint2d_sgd_science_<timestamp>

Default complete matrix (`profile=all`):
  baseline:          sgd=no, independent end-to-end workflow
  checkpoint_baseline:
                     sgd=no continuation from the same stage-3 checkpoint as
                     the joint cases (requires --shared-stage3 or
                     --shared-stage3-from)
  stage4_off:        stage 4 off; stages 5+ on
  stage4_alternate:  stage 4 off/on by local iteration; stages 5+ on
  stage4_on:         stage 4 on; stages 5+ on
  joint_topk1_equiv: K=1 equivalence anchor with stage 4 alternate
  joint_default:     K=3 default optimizer with stage 4 alternate
  latent_eta_0p1 / latent_eta_1p0
  cavg_eta_0p05 / cavg_eta_0p25
  balance_1p0
  balance_eta_0p05
  raw_likelihood
  raw_likelihood_topk1
  stage4_on_raw_likelihood
  balance_raw_likelihood
  balance_stage4_on_raw_likelihood
  balance_topk5 / balance_topk5_raw
  assignment_only

The narrower `activation`, `hyperparameters`, and `shift_selection` profiles
remain available for targeted runs. `shift_selection` is the paired decision
experiment: it runs checkpoint_baseline, balanced raw top-K=3, and raw top-K=1
from each of at least three independently generated stage-3 checkpoints.
Every hyperparameter case uses `sgd_stage4_mode=alternate`.
Repeat --case to rerun any subset; case selection overrides the profile matrix.

  --shared-stage3 Run each replicate's joint-SGD cases from one byte-identical
                  stage-3 checkpoint. Baseline remains independent.
  --shared-stage3-from PATH
                  Reuse completed checkpoint(s). PATH may be a checkpoint or
                  a previous science root. Multi-replicate roots must contain
                  _shared_stage3_checkpoint_repN for every requested replicate.
  --root ROOT     Append into ROOT. Existing runs and manifest rows are kept;
                  reruns receive a _rerunN suffix.
  --profile NAME  all, activation, hyperparameters, or shift_selection.
  --reps N        Number of checkpoint replicates. shift_selection defaults to
                  3 and rejects values below 3.

When --root points to a previous run containing the matching checkpoint(s),
--shared-stage3 reuses them automatically. Use --shared-stage3-from when the
checkpoint and output root are different locations.

Environment overrides:
  JOINT2D_SGD_PROJECTS_HOME        Defaults to ~/Projects.
  JOINT2D_SGD_BUILD_COPY           Defaults to ~/Projects/SIMPLE_joint2d_sgd_build.
  JOINT2D_SGD_SCIENCE_ROOT         Defaults to ~/Projects/simple_joint2d_sgd_science_<timestamp>.
  JOINT2D_SGD_SHARED_STAGE3_FROM   Optional completed checkpoint or prior run root.
  JOINT2D_SGD_SCIENCE_PROJECT      Existing extracted .simple project for validation.
  JOINT2D_SGD_SCIENCE_REPS         Number of replicates. Defaults to 1; recommended 3.
  JOINT2D_SGD_SCIENCE_PROFILE      all, activation, hyperparameters, or shift_selection. Defaults to all.
  JOINT2D_SGD_SCIENCE_NCLS         abinitio2D ncls. Defaults to 100.
  JOINT2D_SGD_SCIENCE_MSKDIAM      abinitio2D mskdiam. Defaults to 190.
  JOINT2D_SGD_SCIENCE_NTHR         abinitio2D nthr. Defaults to 64.
  JOINT2D_SGD_BUILD_JOBS           Build jobs for --prepare-build. Defaults to 32.
  JOINT2D_SGD_CMAKE_BUILD_TYPE     CMake build type. Defaults to Debug.
  JOINT2D_SGD_REWRITE_BUILD        Use yes to refresh an existing build copy without prompting.
  JOINT2D_SGD_PREP_NPARTS          Betagal prep parts. Defaults to 5.
  JOINT2D_SGD_PREP_NTHR            Betagal prep threads. Defaults to 8.
  JOINT2D_SGD_BETAGAL_SAMPLE_COUNT Optional movie sample count for prep.

Legacy compatibility: old JOINT_SGD_* variable names are still accepted as aliases.
  SIMPLE_DATA_TESTING_HOME       Sibling SIMPLE_data_testing repository.
  SIMPLE_EXEC_DIR                Directory containing simple_exec or simple_exec.exe.

NAS rule:
  Do not batch-copy /mnt/beegfs data. On the Oracle Linux workstation, the
  prepare-betagal-extract mode reads /mnt/beegfs files as SIMPLE needs them and
  writes all project/intermediate outputs under ~/Projects.
EOF
}

write_manifest_header() {
  cat > "$manifest" <<'EOF'
case	replicate	profile	mode	stage4_mode	log_file	run_dir	project	ncls	mskdiam	nthr	topk	sgd_eta_latent	sgd_eta_cavg	sgd_balance_weight	params	status
EOF
}

initialize_manifest() {
  local expected_header
  expected_header=$'case\treplicate\tprofile\tmode\tstage4_mode\tlog_file\trun_dir\tproject\tncls\tmskdiam\tnthr\ttopk\tsgd_eta_latent\tsgd_eta_cavg\tsgd_balance_weight\tparams\tstatus'
  if [[ -f "$manifest" ]]; then
    [[ "$(head -n 1 "$manifest")" == "$expected_header" ]] || \
      fail "existing science manifest has an incompatible header: $manifest"
    echo "Appending science results to existing manifest: $manifest"
  else
    write_manifest_header
  fi
}

initialize_checkpoint_manifest() {
  local expected_header
  expected_header=$'replicate\tprofile\tcheckpoint_name\tcheckpoint_path\tlog_file\tlast_iteration\tstate_file\tsha256\tsource'
  if [[ -f "$checkpoint_manifest" ]]; then
    [[ "$(head -n 1 "$checkpoint_manifest")" == "$expected_header" ]] || \
      fail "existing checkpoint manifest has an incompatible header: $checkpoint_manifest"
  else
    printf '%s\n' "$expected_header" > "$checkpoint_manifest"
  fi
}

record_checkpoint() {
  local rep="$1"
  local checkpoint_name="$2"
  local source="$3"
  local iter_tag state_file fingerprint
  iter_tag="$(printf '%03d' "$checkpoint_last_iter")"
  state_file="$(find "$checkpoint_case_root" -type f -name "cavgs_iter${iter_tag}.mrc" -print -quit)"
  [[ -n "$state_file" ]] || fail "stage-3 checkpoint state image not found for replicate $rep below: $checkpoint_case_root"
  command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required to fingerprint stage-3 checkpoints"
  fingerprint="$(sha256sum "$state_file" | awk '{print $1}')"
  [[ "$fingerprint" =~ ^[[:xdigit:]]{64}$ ]] || fail "invalid stage-3 checkpoint fingerprint for replicate $rep"
  checkpoint_fingerprints+=( "$fingerprint" )
  checkpoint_paths+=( "$checkpoint_case_root" )
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$rep" "$manifest_profile" "$checkpoint_name" "$checkpoint_case_root" "$checkpoint_log" \
    "$checkpoint_last_iter" "$state_file" "$fingerprint" "$source" >> "$checkpoint_manifest"
  echo "Shared stage-3 checkpoint fingerprint: replicate=$rep sha256=$fingerprint state=$state_file"
}

validate_shift_selection_checkpoints() {
  local unique_fingerprints unique_paths
  [[ "${#checkpoint_fingerprints[@]}" -eq "$reps" ]] || \
    fail "shift_selection recorded ${#checkpoint_fingerprints[@]} checkpoints; expected $reps"
  unique_fingerprints="$(printf '%s\n' "${checkpoint_fingerprints[@]}" | sort -u | wc -l | tr -d '[:space:]')"
  unique_paths="$(printf '%s\n' "${checkpoint_paths[@]}" | sort -u | wc -l | tr -d '[:space:]')"
  [[ "$unique_paths" -eq "$reps" ]] || \
    fail "shift_selection reused a checkpoint path; expected $reps independent checkpoint paths, found $unique_paths"
  [[ "$unique_fingerprints" -eq "$reps" ]] || \
    fail "shift_selection checkpoints are not independent: only $unique_fingerprints of $reps stage-3 state fingerprints are distinct"
  echo "Shift-selection checkpoint invariant passed: replicates=$reps distinct_paths=$unique_paths distinct_states=$unique_fingerprints"
}

science_all_cases=(
  baseline
  stage4_off
  stage4_alternate
  stage4_on
  joint_topk1_equiv
  joint_default
  latent_eta_0p1
  latent_eta_1p0
  cavg_eta_0p05
  cavg_eta_0p25
  balance_1p0
  balance_eta_0p05
  raw_likelihood
  raw_likelihood_topk1
  stage4_on_raw_likelihood
  balance_raw_likelihood
  balance_stage4_on_raw_likelihood
  balance_topk5
  balance_topk5_raw
  assignment_only
)
science_known_cases=( checkpoint_baseline "${science_all_cases[@]}" )
science_activation_cases=( baseline stage4_off stage4_alternate stage4_on )
science_hyperparameter_cases=(
  baseline
  joint_topk1_equiv
  joint_default
  latent_eta_0p1
  latent_eta_1p0
  cavg_eta_0p05
  cavg_eta_0p25
  balance_1p0
  balance_eta_0p05
  raw_likelihood
  balance_topk5
  balance_topk5_raw
  assignment_only
)
science_shift_selection_cases=( checkpoint_baseline balance_raw_likelihood raw_likelihood_topk1 )

list_cases() {
  printf '%s\n' "${science_known_cases[@]}"
}

add_selected_case() {
  local requested="$1"
  local known selected
  for known in "${science_known_cases[@]}"; do
    if [[ "$requested" == "$known" ]]; then
      for selected in "${selected_cases[@]}"; do
        [[ "$requested" == "$selected" ]] && return 0
      done
      selected_cases+=( "$requested" )
      return 0
    fi
  done
  fail "unknown science case '$requested'; use --list-cases"
}

set_action() {
  local requested="$1"
  if [[ -n "$action" && "$action" != "$requested" ]]; then
    fail "actions --$action and --$requested cannot be combined"
  fi
  action="$requested"
}

remember_failed_case() {
  local case_name="$1"
  local remembered
  for remembered in "${failed_case_names[@]}"; do
    [[ "$case_name" == "$remembered" ]] && return 0
  done
  failed_case_names+=( "$case_name" )
}

record_manifest() {
  local case_name="$1"
  local rep="$2"
  local mode="$3"
  local stage4_mode="$4"
  local log_file="$5"
  local run_dir="$6"
  local topk="$7"
  local eta_latent="$8"
  local eta_cavg="$9"
  local balance_weight="${10}"
  local params="${11}"
  local status="${12}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$case_name" "$rep" "$manifest_profile" "$mode" "$stage4_mode" "$log_file" "$run_dir" "$project_path" \
    "$ncls" "$mskdiam" "$nthr" "$topk" "$eta_latent" "$eta_cavg" \
    "$balance_weight" "$params" "$status" >> "$manifest"
}

run_case() {
  local case_name="$1"
  local rep="$2"
  local mode="$3"
  local stage4_mode="$4"
  local topk="$5"
  local eta_latent="$6"
  local eta_cavg="$7"
  local balance_weight="$8"
  shift 8
  local params=( "$@" )
  local case_id_base="${case_name}_rep${rep}"
  joint2d_sgd_allocate_case_id "$case_id_base"
  local case_id="$case_run_id"
  local log_file="$scratch_root/${case_id}.log"
  local status_file="$scratch_root/${case_id}.check"
  local status="pass"

  total_cases=$((total_cases + 1))
  if [[ "$shared_stage3" == yes && ( "$mode" == joint || "$mode" == checkpoint_baseline ) ]]; then
    local case_parent="$scratch_root/$case_id"
    local resume_dir resume_project
    mkdir -p "$case_parent"
    cp -a "$checkpoint_case_root" "$case_parent/"
    case_root="$case_parent/$(basename -- "$checkpoint_case_root")"
    resume_dir="$(find "$case_root" -maxdepth 1 -type d -iname '*_abinitio2D' -print -quit)"
    resume_project="$resume_dir/$(basename -- "$project_rel")"
    [[ -n "$resume_dir" && -f "$resume_project" ]] || \
      fail "shared-checkpoint project not found below: $case_root"
    cp "$checkpoint_log" "$log_file"
    echo "Running $case_id from shared stage 3 in $case_root"
    (
      cd "$resume_dir"
      JOINT2D_SGD_CHECKPOINT_START_STAGE=4 \
      JOINT2D_SGD_CHECKPOINT_LAST_ITER="$checkpoint_last_iter" \
        simple_exec prg=abinitio2D ncls="$ncls" mskdiam="$mskdiam" nthr="$nthr" \
          projfile="$(basename -- "$resume_project")" mkdir=no "${params[@]}"
    ) >>"$log_file" 2>&1 || status="run_failed"
  else
    copy_case_root "$case_id"
    echo "Running $case_id in $case_root"
    (
      cd "$case_root"
      simple_exec prg=abinitio2D ncls="$ncls" mskdiam="$mskdiam" nthr="$nthr" projfile="$project_rel" "${params[@]}"
    ) >"$log_file" 2>&1 || status="run_failed"
  fi

  if [[ "$status" == "pass" ]]; then
    if "$checker" "$mode" "$log_file" "$stage4_mode" "$case_root" "$case_name" >"$status_file" 2>&1; then
      status="pass"
    else
      status="check_failed"
      cat "$status_file" >&2 || true
    fi
  else
    echo "run failed before checker; see $log_file" > "$status_file"
  fi

  record_manifest "$case_name" "$rep" "$mode" "$stage4_mode" "$log_file" "$case_root" "$topk" \
    "$eta_latent" "$eta_cavg" "$balance_weight" "${params[*]}" "$status"
  if [[ "$status" == "pass" ]]; then
    echo "Log: $log_file"
  else
    failed_cases=$((failed_cases + 1))
    failed_case_list+=( "$case_id:$status:$log_file" )
    remember_failed_case "$case_name"
    echo "Continuing after $case_id failed with status $status; log: $log_file" >&2
  fi
}

prepare_shared_stage3_checkpoint() {
  local rep="$1"
  local checkpoint_name="_shared_stage3_checkpoint"
  if [[ "$reps" -gt 1 ]]; then
    checkpoint_name="${checkpoint_name}_rep${rep}"
  fi

  if [[ -n "$shared_stage3_from" ]]; then
    joint2d_sgd_resolve_shared_stage3_checkpoint "$shared_stage3_from" "$checkpoint_name"
    record_checkpoint "$rep" "$checkpoint_name" "reused:$shared_stage3_from"
    return
  fi
  if [[ -d "$scratch_root/$checkpoint_name" ]]; then
    joint2d_sgd_resolve_shared_stage3_checkpoint "$scratch_root" "$checkpoint_name"
    record_checkpoint "$rep" "$checkpoint_name" "reused:$scratch_root"
    return
  fi

  checkpoint_log="$scratch_root/${checkpoint_name}.log"
  copy_case_root "$checkpoint_name"
  checkpoint_case_root="$case_root"
  joint2d_sgd_make_joint_args alternate 3 0.5 0.1 0.0
  echo "Preparing shared stage-3 checkpoint for replicate $rep in $checkpoint_case_root"
  if (
    cd "$checkpoint_case_root"
    JOINT2D_SGD_CHECKPOINT_STOP_STAGE=3 \
      simple_exec prg=abinitio2D ncls="$ncls" mskdiam="$mskdiam" nthr="$nthr" projfile="$project_rel" \
        "${joint2d_sgd_case_args[@]}"
  ) >"$checkpoint_log" 2>&1; then
    :
  else
    local status=$?
    fail "shared stage-3 checkpoint for replicate $rep exited $status; log=$checkpoint_log"
  fi
  checkpoint_last_iter="$(sed -n \
    's/.*ABINITIO2D CHECKPOINT READY: stage=3 last_iter=\([0-9][0-9]*\).*/\1/p' \
    "$checkpoint_log" | tail -n 1)"
  [[ -n "$checkpoint_last_iter" ]] || \
    fail "shared stage-3 checkpoint has no completion marker: $checkpoint_log"
  echo "Shared stage-3 checkpoint ready: replicate=$rep last_iter=$checkpoint_last_iter log=$checkpoint_log"
  record_checkpoint "$rep" "$checkpoint_name" generated
}

selected_cases_include_joint() {
  local selected
  for selected in "${selected_cases[@]}"; do
    [[ "$selected" != baseline ]] && return 0
  done
  return 1
}

run_selected_case() {
  local case_name="$1"
  local rep="$2"
  local stage4_mode
  case "$case_name" in
    baseline)
      run_case baseline "$rep" baseline off NA NA NA NA sgd=no
      ;;
    checkpoint_baseline)
      run_case checkpoint_baseline "$rep" checkpoint_baseline off NA NA NA NA \
        sgd=no sgd_shadow_stage3=no sgd_diag=no
      ;;
    stage4_off|stage4_alternate|stage4_on)
      stage4_mode="${case_name#stage4_}"
      joint2d_sgd_make_joint_args "$stage4_mode" 3 0.5 0.1 0.0
      run_case "$case_name" "$rep" joint "$stage4_mode" 3 0.5 0.1 0.0 "${joint2d_sgd_case_args[@]}"
      ;;
    joint_topk1_equiv)
      run_case joint_topk1_equiv "$rep" joint alternate 1 0.5 1.0 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=1 sgd_eta_cavg=1.0 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    joint_default)
      run_case joint_default "$rep" joint alternate 3 0.5 0.1 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    latent_eta_0p1)
      run_case latent_eta_0p1 "$rep" joint alternate 3 0.1 0.1 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=0.1 sgd_balance_weight=0.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    latent_eta_1p0)
      run_case latent_eta_1p0 "$rep" joint alternate 3 1.0 0.1 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=1.0 sgd_balance_weight=0.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    cavg_eta_0p05)
      run_case cavg_eta_0p05 "$rep" joint alternate 3 0.5 0.05 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_eta_cavg=0.05 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    cavg_eta_0p25)
      run_case cavg_eta_0p25 "$rep" joint alternate 3 0.5 0.25 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_eta_cavg=0.25 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    balance_1p0)
      # Unit-strength log-support prior: changes class occupancy logits without
      # rescaling the Gaussian likelihood itself.
      run_case balance_1p0 "$rep" joint alternate 3 0.5 0.1 1.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_balance_weight=1.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    balance_eta_0p05)
      run_case balance_eta_0p05 "$rep" joint alternate 3 0.5 0.05 1.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_eta_cavg=0.05 sgd_eta_latent=0.5 sgd_balance_weight=1.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    raw_likelihood)
      run_case raw_likelihood "$rep" joint alternate 3 0.5 0.1 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_inner_its=0 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    raw_likelihood_topk1)
      # K=1 is the hard-assignment anchor.  Keep eta_cavg identical to the
      # K=3 raw-likelihood case so only candidate support changes.
      run_case raw_likelihood_topk1 "$rep" joint alternate 1 0.5 0.1 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=1 sgd_inner_its=0 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_eta_shift=0.25 sgd_shift_its=4 sgd_balance_weight=0.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    stage4_on_raw_likelihood)
      run_case stage4_on_raw_likelihood "$rep" joint on 3 0.5 0.1 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=on sgd_topk=3 sgd_inner_its=0 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    balance_raw_likelihood)
      run_case balance_raw_likelihood "$rep" joint alternate 3 0.5 0.1 1.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_inner_its=0 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_eta_shift=0.25 sgd_shift_its=4 sgd_balance_weight=1.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    balance_stage4_on_raw_likelihood)
      run_case balance_stage4_on_raw_likelihood "$rep" joint on 3 0.5 0.1 1.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=on sgd_topk=3 sgd_inner_its=0 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_balance_weight=1.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    balance_topk5)
      run_case balance_topk5 "$rep" joint alternate 5 0.5 0.1 1.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=5 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_balance_weight=1.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    balance_topk5_raw)
      run_case balance_topk5_raw "$rep" joint alternate 5 0.5 0.1 1.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=5 sgd_inner_its=0 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_balance_weight=1.0 sgd_diag=yes sgd_shadow_stage3=yes
      ;;
    assignment_only)
      run_case assignment_only "$rep" joint alternate 3 0.5 0.1 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_assignment_only=yes sgd_diag=yes sgd_shadow_stage3=yes
      ;;
  esac
}

joint2d_sgd_runner_label="joint2D-SGD science runner"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
simple_home="$(cd -- "$script_dir/.." && pwd -P)"
# shellcheck source=.codex/joint2d-sgd-runner-common.sh
. "$script_dir/joint2d-sgd-runner-common.sh"
joint2d_sgd_common_init

checker="$script_dir/check-joint2d-sgd-science-log.sh"
summarizer="$script_dir/summarize-joint2d-sgd-science.sh"

action=""
selected_cases=()
case_filter_requested=no
shared_stage3=no
shared_stage3_from="$(env_or_legacy JOINT2D_SGD_SHARED_STAGE3_FROM JOINT_SGD_SHARED_STAGE3_FROM "")"
root_override=""
profile_override=""
reps_override=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      set_action help
      shift
      ;;
    --check)
      set_action check
      shift
      ;;
    --list-cases)
      set_action list-cases
      shift
      ;;
    --case)
      [[ $# -ge 2 ]] || fail "--case requires a case name"
      case_filter_requested=yes
      add_selected_case "$2"
      shift 2
      ;;
    --prepare-build)
      set_action prepare-build
      shift
      ;;
    --prepare-betagal-extract)
      set_action prepare-betagal-extract
      shift
      ;;
    --shared-stage3)
      shared_stage3=yes
      shift
      ;;
    --shared-stage3-from)
      [[ $# -ge 2 ]] || fail "--shared-stage3-from requires a path"
      shared_stage3=yes
      shared_stage3_from="$2"
      shift 2
      ;;
    --root)
      [[ $# -ge 2 ]] || fail "--root requires a path"
      root_override="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || fail "--profile requires a profile name"
      profile_override="$2"
      shift 2
      ;;
    --reps)
      [[ $# -ge 2 ]] || fail "--reps requires a positive integer"
      reps_override="$2"
      shift 2
      ;;
    *)
      fail "unknown argument '$1'; use --help"
      ;;
  esac
done
[[ -z "$shared_stage3_from" ]] || shared_stage3=yes
action="${action:-run}"

case "$action" in
  help)
    usage
    exit 0
    ;;
  list-cases)
    list_cases
    exit 0
    ;;
  prepare-build)
    [[ "$case_filter_requested" == no ]] || fail "--case cannot be combined with --prepare-build"
    prepare_build_copy
    exit 0
    ;;
esac

setup_simple_path

if [[ "$action" == "prepare-betagal-extract" ]]; then
  [[ "$case_filter_requested" == no ]] || fail "--case cannot be combined with --prepare-betagal-extract"
  prepare_betagal_extract JOINT2D_SGD_SCIENCE_ROOT JOINT2D_SGD_SCIENCE_PROJECT .codex/run-joint2d-sgd-science.sh JOINT_SGD_SCIENCE_ROOT
  exit 0
fi

common_project_probe JOINT2D_SGD_SCIENCE_PROJECT JOINT_SGD_SCIENCE_PROJECT

if [[ "$action" == "check" ]]; then
  check_profile="${profile_override:-$(env_or_legacy JOINT2D_SGD_SCIENCE_PROFILE JOINT_SGD_SCIENCE_PROFILE all)}"
  check_default_reps=1
  [[ "$check_profile" == shift_selection ]] && check_default_reps=3
  check_reps="${reps_override:-$(env_or_legacy JOINT2D_SGD_SCIENCE_REPS JOINT_SGD_SCIENCE_REPS "$check_default_reps")}"
  check_shared_stage3="$shared_stage3"
  [[ "$check_profile" == shift_selection && "$case_filter_requested" == no ]] && check_shared_stage3=yes
  print_common_check "Default science root: $projects_home/simple_joint2d_sgd_science_<timestamp>"
  echo "Replicates: $check_reps"
  echo "Science threads: $(env_or_legacy JOINT2D_SGD_SCIENCE_NTHR JOINT_SGD_SCIENCE_NTHR 64)"
  echo "Profile: $check_profile"
  if [[ "$case_filter_requested" == yes ]]; then
    echo "Selected science cases: ${selected_cases[*]}"
  else
    echo "Selected science cases: profile matrix"
  fi
  echo "Shared stage-3 checkpoint: $check_shared_stage3"
  echo "Shared stage-3 source: ${shared_stage3_from:-auto/new}"
  echo "Requested output root: ${root_override:-default timestamped root}"
  cat <<'EOF'
All profile: baseline plus the complete activation and 015 hyperparameter matrices.
Activation profile: baseline, stage4_off, stage4_alternate, stage4_on.
Hyperparameters profile: the 015 sweep with stage4_alternate.
Shift-selection profile: three paired checkpoint continuations per independently generated stage-3 state.
Failure policy: each case/replicate is independent; failed cases are recorded and later cases continue.
EOF
  exit 0
fi

require_common_inputs "$checker"
[[ -f "$summarizer" ]] || fail "summarizer script not found: $summarizer"
command -v simple_exec >/dev/null 2>&1 || fail "simple_exec is not on PATH; run --prepare-build or set SIMPLE_EXEC_DIR"
require_project_or_explain "science" JOINT2D_SGD_SCIENCE_PROJECT
infer_workflow_root "$project_path"

timestamp="$(date +%Y%m%d_%H%M%S)"
scratch_root="${root_override:-$(env_or_legacy JOINT2D_SGD_SCIENCE_ROOT JOINT_SGD_SCIENCE_ROOT "$projects_home/simple_joint2d_sgd_science_${timestamp}")}"
ncls="$(env_or_legacy JOINT2D_SGD_SCIENCE_NCLS JOINT_SGD_SCIENCE_NCLS 100)"
mskdiam="$(env_or_legacy JOINT2D_SGD_SCIENCE_MSKDIAM JOINT_SGD_SCIENCE_MSKDIAM 190)"
nthr="$(env_or_legacy JOINT2D_SGD_SCIENCE_NTHR JOINT_SGD_SCIENCE_NTHR 64)"
profile="${profile_override:-$(env_or_legacy JOINT2D_SGD_SCIENCE_PROFILE JOINT_SGD_SCIENCE_PROFILE all)}"
default_reps=1
[[ "$profile" == shift_selection ]] && default_reps=3
reps="${reps_override:-$(env_or_legacy JOINT2D_SGD_SCIENCE_REPS JOINT_SGD_SCIENCE_REPS "$default_reps")}"
manifest_profile="$profile"
manifest="$scratch_root/science_runs.tsv"
checkpoint_manifest="$scratch_root/science_checkpoints.tsv"

[[ "$reps" =~ ^[0-9]+$ && "$reps" -ge 1 ]] || fail "JOINT2D_SGD_SCIENCE_REPS must be a positive integer"
case "$profile" in
  all|activation|hyperparameters|shift_selection) ;;
  *) fail "JOINT2D_SGD_SCIENCE_PROFILE must be all, activation, hyperparameters, or shift_selection" ;;
esac
if [[ "$profile" == shift_selection && "$case_filter_requested" == no ]]; then
  [[ "$reps" -ge 3 ]] || fail "shift_selection requires at least 3 independently generated checkpoint replicates"
  shared_stage3=yes
fi

if [[ "$case_filter_requested" == yes ]]; then
  manifest_profile=selected
else
  case "$profile" in
    all) selected_cases=( "${science_all_cases[@]}" ) ;;
    activation) selected_cases=( "${science_activation_cases[@]}" ) ;;
    hyperparameters) selected_cases=( "${science_hyperparameter_cases[@]}" ) ;;
    shift_selection) selected_cases=( "${science_shift_selection_cases[@]}" ) ;;
  esac
fi

if [[ " ${selected_cases[*]} " == *" checkpoint_baseline "* && "$shared_stage3" != yes ]]; then
  fail "checkpoint_baseline requires --shared-stage3 or --shared-stage3-from so it can resume the matched stage-3 state"
fi

mkdir -p "$scratch_root"
scratch_root="$(cd -- "$scratch_root" && pwd -P)"
initialize_manifest
initialize_checkpoint_manifest
total_cases=0
failed_cases=0
failed_case_list=()
failed_case_names=()
checkpoint_fingerprints=()
checkpoint_paths=()

echo "Science root: $scratch_root"
echo "Source project: $project_path"
echo "Workflow root: $workflow_root"
echo "Project relative path: $project_rel"
echo "ncls=$ncls mskdiam=$mskdiam nthr=$nthr reps=$reps profile=$profile"
echo "Selected science cases: ${selected_cases[*]}"
echo "Shared stage-3 checkpoint: $shared_stage3"
echo "Shared stage-3 source: ${shared_stage3_from:-auto/new}"

for rep in $(seq 1 "$reps"); do
  if [[ "$shared_stage3" == yes ]] && selected_cases_include_joint; then
    prepare_shared_stage3_checkpoint "$rep"
  fi
  for case_name in "${selected_cases[@]}"; do
    run_selected_case "$case_name" "$rep"
  done
done

"$summarizer" "$scratch_root"
if [[ "$profile" == shift_selection && "$case_filter_requested" == no ]]; then
  validate_shift_selection_checkpoints
fi
echo "joint2D-SGD scientific validation complete: $scratch_root"
echo "Cases completed: $total_cases"
echo "Cases failed: $failed_cases"
if [[ "$failed_cases" -gt 0 ]]; then
  rerun_command=( "$0" --root "$scratch_root" )
  if [[ "$shared_stage3" == yes ]]; then
    rerun_command+=( --shared-stage3-from "${shared_stage3_from:-$scratch_root}" )
  fi
  for case_name in "${failed_case_names[@]}"; do
    rerun_command+=( --case "$case_name" )
  done
  echo "Failed cases:" >&2
  printf '  %s\n' "${failed_case_list[@]}" >&2
  echo "Rerun only the failed case types:" >&2
  printf '  JOINT2D_SGD_SCIENCE_REPS=%q' "$reps" >&2
  printf ' %q' "${rerun_command[@]}" >&2
  printf '\n' >&2
  echo "Science root with logs and summary: $scratch_root" >&2
  exit 1
fi
