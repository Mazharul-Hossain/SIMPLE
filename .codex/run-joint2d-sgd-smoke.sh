#!/usr/bin/env bash
set -Eeuo pipefail
trap 'status=$?; echo "joint2D-SGD smoke runner failed at line ${LINENO}: ${BASH_COMMAND} (exit ${status})" >&2' ERR

usage() {
  cat <<'EOF'
Usage:
  .codex/run-joint2d-sgd-smoke.sh --check
  .codex/run-joint2d-sgd-smoke.sh --list-cases
  .codex/run-joint2d-sgd-smoke.sh --case CASE [--case CASE ...]
  .codex/run-joint2d-sgd-smoke.sh --prepare-build
  .codex/run-joint2d-sgd-smoke.sh --prepare-betagal-extract
  .codex/run-joint2d-sgd-smoke.sh

Workstation layout:
  Build copy:  ~/Projects/SIMPLE_joint2d_sgd_build
  Test runs:   ~/Projects/simple_joint2d_sgd_smoke_<timestamp>

The server smoke matrix runs baseline, stage-4 off with K=1, and stage-4
alternate with K=3. The complete activation matrix remains in the science runner.
Use repeatable --case options to run only selected cases.

Environment overrides:
  JOINT2D_SGD_PROJECTS_HOME       Defaults to ~/Projects.
  JOINT2D_SGD_BUILD_COPY          Defaults to ~/Projects/SIMPLE_joint2d_sgd_build.
  JOINT2D_SGD_SMOKE_ROOT          Defaults to ~/Projects/simple_joint2d_sgd_smoke_<timestamp>.
  JOINT2D_SGD_SMOKE_PROJECT       Existing extracted .simple project for smoke tests.
  JOINT2D_SGD_SMOKE_NCLS          abinitio2D ncls. Defaults to 100.
  JOINT2D_SGD_SMOKE_MSKDIAM       abinitio2D mskdiam. Defaults to 190.
  JOINT2D_SGD_SMOKE_NTHR          abinitio2D nthr. Defaults to 64.
  JOINT2D_SGD_BUILD_JOBS          Build jobs for --prepare-build. Defaults to 32.
  JOINT2D_SGD_CMAKE_BUILD_TYPE    CMake build type. Defaults to Debug.
  JOINT2D_SGD_REWRITE_BUILD       Use yes to refresh an existing build copy without prompting.
  JOINT2D_SGD_PREP_NPARTS         Betagal prep parts. Defaults to 5.
  JOINT2D_SGD_PREP_NTHR           Betagal prep threads. Defaults to 8.
  JOINT2D_SGD_BETAGAL_SAMPLE_COUNT Optional movie sample count for prep.

Legacy compatibility: old JOINT_SGD_* variable names are still accepted as aliases.
  SIMPLE_DATA_TESTING_HOME      Sibling SIMPLE_data_testing repository.
  SIMPLE_EXEC_DIR               Directory containing simple_exec or simple_exec.exe.

NAS rule:
  Do not batch-copy /mnt/beegfs data. On the Oracle Linux workstation, the
  prepare-betagal-extract mode reads /mnt/beegfs files as SIMPLE needs them and
  writes all project/intermediate outputs under ~/Projects.
EOF
}

smoke_cases=( baseline stage4_off stage4_alternate )

list_cases() {
  printf '%s\n' "${smoke_cases[@]}"
}

add_selected_case() {
  local requested="$1"
  local known selected
  for known in "${smoke_cases[@]}"; do
    if [[ "$requested" == "$known" ]]; then
      for selected in "${selected_cases[@]}"; do
        [[ "$requested" == "$selected" ]] && return 0
      done
      selected_cases+=( "$requested" )
      return 0
    fi
  done
  fail "unknown smoke case '$requested'; use --list-cases"
}

set_action() {
  local requested="$1"
  if [[ -n "$action" && "$action" != "$requested" ]]; then
    fail "actions --$action and --$requested cannot be combined"
  fi
  action="$requested"
}

run_case() {
  local case_name="$1"
  shift
  local log_file="$scratch_root/${case_name}.log"

  copy_case_root "$case_name"
  echo "Running $case_name in $case_root"
  (
    cd "$case_root"
    simple_exec prg=abinitio2D ncls="$ncls" mskdiam="$mskdiam" nthr="$nthr" projfile="$project_rel" "$@"
  ) >"$log_file" 2>&1

  "$checker" "$case_name" "$log_file" "$case_root"
  echo "Log: $log_file"
}

run_selected_case() {
  local case_name="$1"
  case "$case_name" in
    baseline)
      run_case baseline sgd=no
      ;;
    stage4_off)
      joint2d_sgd_make_joint_args off 1 0.5 1.0 0.0
      joint2d_sgd_print_stage_policy off
      run_case stage4_off "${joint2d_sgd_case_args[@]}"
      ;;
    stage4_alternate)
      joint2d_sgd_make_joint_args alternate 3 0.5 0.1 0.0
      joint2d_sgd_print_stage_policy alternate
      run_case stage4_alternate "${joint2d_sgd_case_args[@]}"
      ;;
  esac
}

joint2d_sgd_runner_label="joint2D-SGD smoke runner"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
simple_home="$(cd -- "$script_dir/.." && pwd -P)"
# shellcheck source=.codex/joint2d-sgd-runner-common.sh
. "$script_dir/joint2d-sgd-runner-common.sh"
joint2d_sgd_common_init

checker="$script_dir/check-joint2d-sgd-smoke-log.sh"

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

if [[ "${#selected_cases[@]}" -eq 0 ]]; then
  selected_cases=( "${smoke_cases[@]}" )
fi

setup_simple_path

if [[ "$action" == "prepare-betagal-extract" ]]; then
  [[ "$case_filter_requested" == no ]] || fail "--case cannot be combined with --prepare-betagal-extract"
  prepare_betagal_extract JOINT2D_SGD_SMOKE_ROOT JOINT2D_SGD_SMOKE_PROJECT .codex/run-joint2d-sgd-smoke.sh JOINT_SGD_SMOKE_ROOT
  exit 0
fi

common_project_probe JOINT2D_SGD_SMOKE_PROJECT JOINT_SGD_SMOKE_PROJECT

if [[ "$action" == "check" ]]; then
  print_common_check "Default smoke root: $projects_home/simple_joint2d_sgd_smoke_<timestamp>"
  echo "Smoke threads: $(env_or_legacy JOINT2D_SGD_SMOKE_NTHR JOINT_SGD_SMOKE_NTHR 64)"
  echo "Selected smoke cases: ${selected_cases[*]}"
  joint2d_sgd_print_stage_policy alternate
  exit 0
fi

require_common_inputs "$checker"
command -v simple_exec >/dev/null 2>&1 || fail "simple_exec is not on PATH; run --prepare-build or set SIMPLE_EXEC_DIR"
require_project_or_explain "smoke" JOINT2D_SGD_SMOKE_PROJECT
infer_workflow_root "$project_path"

timestamp="$(date +%Y%m%d_%H%M%S)"
scratch_root="$(env_or_legacy JOINT2D_SGD_SMOKE_ROOT JOINT_SGD_SMOKE_ROOT "$projects_home/simple_joint2d_sgd_smoke_${timestamp}")"
ncls="$(env_or_legacy JOINT2D_SGD_SMOKE_NCLS JOINT_SGD_SMOKE_NCLS 100)"
mskdiam="$(env_or_legacy JOINT2D_SGD_SMOKE_MSKDIAM JOINT_SGD_SMOKE_MSKDIAM 190)"
nthr="$(env_or_legacy JOINT2D_SGD_SMOKE_NTHR JOINT_SGD_SMOKE_NTHR 64)"

mkdir -p "$scratch_root"

echo "Scratch root: $scratch_root"
echo "Source project: $project_path"
echo "Workflow root: $workflow_root"
echo "Project relative path: $project_rel"
echo "ncls=$ncls mskdiam=$mskdiam nthr=$nthr"
echo "Selected smoke cases: ${selected_cases[*]}"

for case_name in "${selected_cases[@]}"; do
  run_selected_case "$case_name"
done

echo "joint2D-SGD smoke validation complete: $scratch_root"
