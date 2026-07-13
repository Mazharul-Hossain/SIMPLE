#!/usr/bin/env bash
set -Eeuo pipefail
trap 'status=$?; echo "joint2D-SGD smoke runner failed at line ${LINENO}: ${BASH_COMMAND} (exit ${status})" >&2' ERR

usage() {
  cat <<'EOF'
Usage:
  .codex/run-joint2d-sgd-smoke.sh --check
  .codex/run-joint2d-sgd-smoke.sh --prepare-build
  .codex/run-joint2d-sgd-smoke.sh --prepare-betagal-extract
  .codex/run-joint2d-sgd-smoke.sh

Workstation layout:
  Build copy:  ~/Projects/SIMPLE_joint2d_sgd_build
  Test runs:   ~/Projects/simple_joint2d_sgd_smoke_<timestamp>

The smoke matrix runs the baseline plus stage-4 off, alternate, and on. Joint
SGD is always off in stages 1-3, on in stages 5+, and off in the terminal pass.

Environment overrides:
  JOINT2D_SGD_PROJECTS_HOME       Defaults to ~/Projects.
  JOINT2D_SGD_BUILD_COPY          Defaults to ~/Projects/SIMPLE_joint2d_sgd_build.
  JOINT2D_SGD_SMOKE_ROOT          Defaults to ~/Projects/simple_joint2d_sgd_smoke_<timestamp>.
  JOINT2D_SGD_SMOKE_PROJECT       Existing extracted .simple project for smoke tests.
  JOINT2D_SGD_SMOKE_NCLS          abinitio2D ncls. Defaults to 100.
  JOINT2D_SGD_SMOKE_MSKDIAM       abinitio2D mskdiam. Defaults to 190.
  JOINT2D_SGD_SMOKE_NTHR          abinitio2D nthr. Defaults to 32.
  JOINT2D_SGD_BUILD_JOBS          Build jobs for --prepare-build. Defaults to 4.
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

run_case() {
  local case_name="$1"
  local mode="$2"
  local stage4_mode="$3"
  shift 3
  local log_file="$scratch_root/${case_name}.log"

  copy_case_root "$case_name"
  echo "Running $case_name in $case_root"
  (
    cd "$case_root"
    simple_exec prg=abinitio2D ncls="$ncls" mskdiam="$mskdiam" nthr="$nthr" projfile="$project_rel" "$@"
  ) >"$log_file" 2>&1

  "$checker" "$mode" "$log_file" "$stage4_mode" "$case_root"
  echo "Log: $log_file"
}

joint2d_sgd_runner_label="joint2D-SGD smoke runner"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
simple_home="$(cd -- "$script_dir/.." && pwd -P)"
# shellcheck source=.codex/joint2d-sgd-runner-common.sh
. "$script_dir/joint2d-sgd-runner-common.sh"
joint2d_sgd_common_init

checker="$script_dir/check-joint2d-sgd-smoke-log.sh"

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  --prepare-build)
    prepare_build_copy
    exit 0
    ;;
esac

setup_simple_path

if [[ "${1:-}" == "--prepare-betagal-extract" ]]; then
  prepare_betagal_extract JOINT2D_SGD_SMOKE_ROOT JOINT2D_SGD_SMOKE_PROJECT .codex/run-joint2d-sgd-smoke.sh JOINT_SGD_SMOKE_ROOT
  exit 0
fi

common_project_probe JOINT2D_SGD_SMOKE_PROJECT JOINT_SGD_SMOKE_PROJECT

if [[ "${1:-}" == "--check" ]]; then
  print_common_check "Default smoke root: $projects_home/simple_joint2d_sgd_smoke_<timestamp>"
  echo "Smoke cases: baseline, stage4_off, stage4_alternate, stage4_on"
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
nthr="$(env_or_legacy JOINT2D_SGD_SMOKE_NTHR JOINT_SGD_SMOKE_NTHR 32)"

mkdir -p "$scratch_root"

echo "Scratch root: $scratch_root"
echo "Source project: $project_path"
echo "Workflow root: $workflow_root"
echo "Project relative path: $project_rel"
echo "ncls=$ncls mskdiam=$mskdiam nthr=$nthr"
echo "Smoke cases: baseline, stage4_off, stage4_alternate, stage4_on"

run_case baseline baseline off sgd=no
for stage4_mode in off alternate on; do
  case_name="$(joint2d_sgd_stage4_case_name "$stage4_mode")"
  joint2d_sgd_make_joint_args "$stage4_mode" 3 0.5 0.1 0.0
  joint2d_sgd_print_stage_policy "$stage4_mode"
  run_case "$case_name" joint "$stage4_mode" "${joint2d_sgd_case_args[@]}"
done

echo "joint2D-SGD smoke validation complete: $scratch_root"
