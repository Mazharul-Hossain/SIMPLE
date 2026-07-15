#!/usr/bin/env bash
set -Eeuo pipefail
trap 'status=$?; echo "joint2D-SGD science runner failed at line ${LINENO}: ${BASH_COMMAND} (exit ${status})" >&2' ERR

usage() {
  cat <<'EOF'
Usage:
  .codex/run-joint2d-sgd-science.sh --check
  .codex/run-joint2d-sgd-science.sh --list-cases
  .codex/run-joint2d-sgd-science.sh --case CASE [--case CASE ...]
  .codex/run-joint2d-sgd-science.sh --prepare-build
  .codex/run-joint2d-sgd-science.sh --prepare-betagal-extract
  .codex/run-joint2d-sgd-science.sh

Workstation layout:
  Build copy:  ~/Projects/SIMPLE_joint2d_sgd_build
  Test runs:   ~/Projects/simple_joint2d_sgd_science_<timestamp>

Default complete matrix (`profile=all`):
  baseline:          sgd=no
  stage4_off:        stage 4 off; stages 5+ on
  stage4_alternate:  stage 4 off/on by local iteration; stages 5+ on
  stage4_on:         stage 4 on; stages 5+ on
  joint_topk1_equiv: K=1 equivalence anchor with stage 4 alternate
  joint_default:     K=3 default optimizer with stage 4 alternate
  latent_eta_0p1 / latent_eta_1p0
  cavg_eta_0p05 / cavg_eta_0p25
  balance_1p0

The narrower `activation` and `hyperparameters` profiles remain available for
targeted reruns. Every hyperparameter case uses `sgd_stage4_mode=alternate`.
Repeat --case to rerun any subset; case selection overrides the profile matrix.

Environment overrides:
  JOINT2D_SGD_PROJECTS_HOME        Defaults to ~/Projects.
  JOINT2D_SGD_BUILD_COPY           Defaults to ~/Projects/SIMPLE_joint2d_sgd_build.
  JOINT2D_SGD_SCIENCE_ROOT         Defaults to ~/Projects/simple_joint2d_sgd_science_<timestamp>.
  JOINT2D_SGD_SCIENCE_PROJECT      Existing extracted .simple project for validation.
  JOINT2D_SGD_SCIENCE_REPS         Number of replicates. Defaults to 1; recommended 3.
  JOINT2D_SGD_SCIENCE_PROFILE      all, activation, or hyperparameters. Defaults to all.
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
)
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
)

list_cases() {
  printf '%s\n' "${science_all_cases[@]}"
}

add_selected_case() {
  local requested="$1"
  local known selected
  for known in "${science_all_cases[@]}"; do
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
  local case_id="${case_name}_rep${rep}"
  local log_file="$scratch_root/${case_id}.log"
  local status_file="$scratch_root/${case_id}.check"
  local status="pass"

  total_cases=$((total_cases + 1))
  copy_case_root "$case_id"
  echo "Running $case_id in $case_root"
  (
    cd "$case_root"
    simple_exec prg=abinitio2D ncls="$ncls" mskdiam="$mskdiam" nthr="$nthr" projfile="$project_rel" "${params[@]}"
  ) >"$log_file" 2>&1 || status="run_failed"

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

run_selected_case() {
  local case_name="$1"
  local rep="$2"
  local stage4_mode
  case "$case_name" in
    baseline)
      run_case baseline "$rep" baseline off NA NA NA NA sgd=no
      ;;
    stage4_off|stage4_alternate|stage4_on)
      stage4_mode="${case_name#stage4_}"
      joint2d_sgd_make_joint_args "$stage4_mode" 3 0.5 0.1 0.0
      run_case "$case_name" "$rep" joint "$stage4_mode" 3 0.5 0.1 0.0 "${joint2d_sgd_case_args[@]}"
      ;;
    joint_topk1_equiv)
      run_case joint_topk1_equiv "$rep" joint alternate 1 0.5 1.0 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=1 sgd_eta_cavg=1.0 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_diag=yes
      ;;
    joint_default)
      run_case joint_default "$rep" joint alternate 3 0.5 0.1 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_diag=yes
      ;;
    latent_eta_0p1)
      run_case latent_eta_0p1 "$rep" joint alternate 3 0.1 0.1 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=0.1 sgd_balance_weight=0.0 sgd_diag=yes
      ;;
    latent_eta_1p0)
      run_case latent_eta_1p0 "$rep" joint alternate 3 1.0 0.1 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=1.0 sgd_balance_weight=0.0 sgd_diag=yes
      ;;
    cavg_eta_0p05)
      run_case cavg_eta_0p05 "$rep" joint alternate 3 0.5 0.05 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_eta_cavg=0.05 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_diag=yes
      ;;
    cavg_eta_0p25)
      run_case cavg_eta_0p25 "$rep" joint alternate 3 0.5 0.25 0.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_eta_cavg=0.25 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_diag=yes
      ;;
    balance_1p0)
      # Unit-strength log-support prior: changes class occupancy logits without
      # rescaling the Gaussian likelihood itself.
      run_case balance_1p0 "$rep" joint alternate 3 0.5 0.1 1.0 \
        sgd=yes sgd_mode=joint sgd_stage4_mode=alternate sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_balance_weight=1.0 sgd_diag=yes
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
    *)
      fail "unknown argument '$1'; use --help"
      ;;
  esac
done
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
  print_common_check "Default science root: $projects_home/simple_joint2d_sgd_science_<timestamp>"
  echo "Replicates: $(env_or_legacy JOINT2D_SGD_SCIENCE_REPS JOINT_SGD_SCIENCE_REPS 1)"
  echo "Science threads: $(env_or_legacy JOINT2D_SGD_SCIENCE_NTHR JOINT_SGD_SCIENCE_NTHR 64)"
  echo "Profile: $(env_or_legacy JOINT2D_SGD_SCIENCE_PROFILE JOINT_SGD_SCIENCE_PROFILE all)"
  if [[ "$case_filter_requested" == yes ]]; then
    echo "Selected science cases: ${selected_cases[*]}"
  else
    echo "Selected science cases: profile matrix"
  fi
  cat <<'EOF'
All profile: baseline plus the complete activation and 015 hyperparameter matrices.
Activation profile: baseline, stage4_off, stage4_alternate, stage4_on.
Hyperparameters profile: the 015 sweep with stage4_alternate.
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
scratch_root="$(env_or_legacy JOINT2D_SGD_SCIENCE_ROOT JOINT_SGD_SCIENCE_ROOT "$projects_home/simple_joint2d_sgd_science_${timestamp}")"
reps="$(env_or_legacy JOINT2D_SGD_SCIENCE_REPS JOINT_SGD_SCIENCE_REPS 1)"
ncls="$(env_or_legacy JOINT2D_SGD_SCIENCE_NCLS JOINT_SGD_SCIENCE_NCLS 100)"
mskdiam="$(env_or_legacy JOINT2D_SGD_SCIENCE_MSKDIAM JOINT_SGD_SCIENCE_MSKDIAM 190)"
nthr="$(env_or_legacy JOINT2D_SGD_SCIENCE_NTHR JOINT_SGD_SCIENCE_NTHR 64)"
profile="$(env_or_legacy JOINT2D_SGD_SCIENCE_PROFILE JOINT_SGD_SCIENCE_PROFILE all)"
manifest_profile="$profile"
manifest="$scratch_root/science_runs.tsv"

[[ "$reps" =~ ^[0-9]+$ && "$reps" -ge 1 ]] || fail "JOINT2D_SGD_SCIENCE_REPS must be a positive integer"
case "$profile" in
  all|activation|hyperparameters) ;;
  *) fail "JOINT2D_SGD_SCIENCE_PROFILE must be all, activation, or hyperparameters" ;;
esac

if [[ "$case_filter_requested" == yes ]]; then
  manifest_profile=selected
else
  case "$profile" in
    all) selected_cases=( "${science_all_cases[@]}" ) ;;
    activation) selected_cases=( "${science_activation_cases[@]}" ) ;;
    hyperparameters) selected_cases=( "${science_hyperparameter_cases[@]}" ) ;;
  esac
fi

mkdir -p "$scratch_root"
write_manifest_header
total_cases=0
failed_cases=0
failed_case_list=()
failed_case_names=()

echo "Science root: $scratch_root"
echo "Source project: $project_path"
echo "Workflow root: $workflow_root"
echo "Project relative path: $project_rel"
echo "ncls=$ncls mskdiam=$mskdiam nthr=$nthr reps=$reps profile=$profile"
echo "Selected science cases: ${selected_cases[*]}"

for rep in $(seq 1 "$reps"); do
  for case_name in "${selected_cases[@]}"; do
    run_selected_case "$case_name" "$rep"
  done
done

"$summarizer" "$scratch_root"
echo "joint2D-SGD scientific validation complete: $scratch_root"
echo "Cases completed: $total_cases"
echo "Cases failed: $failed_cases"
if [[ "$failed_cases" -gt 0 ]]; then
  rerun_command=( "$0" )
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
