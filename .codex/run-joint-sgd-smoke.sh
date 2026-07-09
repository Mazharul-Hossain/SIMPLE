#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  .codex/run-joint-sgd-smoke.sh --check
  .codex/run-joint-sgd-smoke.sh --prepare-build
  .codex/run-joint-sgd-smoke.sh --prepare-betagal-extract
  .codex/run-joint-sgd-smoke.sh

Workstation layout:
  Build copy:  ~/Projects/SIMPLE_joint_sgd_build
  Test runs:   ~/Projects/simple_joint_sgd_smoke_<timestamp>

Environment overrides:
  JOINT_SGD_PROJECTS_HOME       Defaults to ~/Projects.
  JOINT_SGD_BUILD_COPY          Defaults to ~/Projects/SIMPLE_joint_sgd_build.
  JOINT_SGD_SMOKE_ROOT          Defaults to ~/Projects/simple_joint_sgd_smoke_<timestamp>.
  JOINT_SGD_SMOKE_PROJECT       Existing extracted .simple project for smoke tests.
  JOINT_SGD_SMOKE_NCLS          abinitio2D ncls. Defaults to 100.
  JOINT_SGD_SMOKE_MSKDIAM       abinitio2D mskdiam. Defaults to 190.
  JOINT_SGD_SMOKE_NTHR          abinitio2D nthr. Defaults to 32.
  JOINT_SGD_BUILD_JOBS          Build jobs for --prepare-build. Defaults to 4.
  JOINT_SGD_CMAKE_BUILD_TYPE    CMake build type. Defaults to Debug.
  JOINT_SGD_REWRITE_BUILD       Use yes to refresh an existing build copy without prompting.
  JOINT_SGD_PREP_NPARTS         Betagal prep parts. Defaults to 5.
  JOINT_SGD_PREP_NTHR           Betagal prep threads. Defaults to 8.
  JOINT_SGD_BETAGAL_SAMPLE_COUNT Optional movie sample count for prep.
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
  shift 2
  local log_file="$scratch_root/${case_name}.log"

  copy_case_root "$case_name"
  echo "Running $case_name in $case_root"
  (
    cd "$case_root"
    simple_exec prg=abinitio2D ncls="$ncls" mskdiam="$mskdiam" nthr="$nthr" projfile="$project_rel" "$@"
  ) >"$log_file" 2>&1

  "$checker" "$mode" "$log_file" "$case_root"
  echo "Log: $log_file"
}

joint_sgd_runner_label="joint-SGD smoke runner"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
simple_home="$(cd -- "$script_dir/.." && pwd -P)"
# shellcheck source=.codex/joint-sgd-runner-common.sh
. "$script_dir/joint-sgd-runner-common.sh"
joint_sgd_common_init

checker="$script_dir/check-joint-sgd-smoke-log.sh"

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
  prepare_betagal_extract JOINT_SGD_SMOKE_ROOT JOINT_SGD_SMOKE_PROJECT .codex/run-joint-sgd-smoke.sh
  exit 0
fi

common_project_probe JOINT_SGD_SMOKE_PROJECT

if [[ "${1:-}" == "--check" ]]; then
  print_common_check "Default smoke root: $projects_home/simple_joint_sgd_smoke_<timestamp>"
  exit 0
fi

require_common_inputs "$checker"
command -v simple_exec >/dev/null 2>&1 || fail "simple_exec is not on PATH; run --prepare-build or set SIMPLE_EXEC_DIR"
require_project_or_explain "smoke" JOINT_SGD_SMOKE_PROJECT
infer_workflow_root "$project_path"

timestamp="$(date +%Y%m%d_%H%M%S)"
scratch_root="${JOINT_SGD_SMOKE_ROOT:-$projects_home/simple_joint_sgd_smoke_${timestamp}}"
ncls="${JOINT_SGD_SMOKE_NCLS:-100}"
mskdiam="${JOINT_SGD_SMOKE_MSKDIAM:-190}"
nthr="${JOINT_SGD_SMOKE_NTHR:-32}"

mkdir -p "$scratch_root"

echo "Scratch root: $scratch_root"
echo "Source project: $project_path"
echo "Workflow root: $workflow_root"
echo "Project relative path: $project_rel"
echo "ncls=$ncls mskdiam=$mskdiam nthr=$nthr"

run_case baseline baseline sgd=no
run_case joint_topk1 joint sgd=yes sgd_mode=joint sgd_topk=1 sgd_eta_cavg=1.0 sgd_diag=yes
run_case joint_topk3 joint sgd=yes sgd_mode=joint sgd_topk=3 sgd_eta_cavg=0.1 sgd_diag=yes

echo "joint-SGD smoke validation complete: $scratch_root"
