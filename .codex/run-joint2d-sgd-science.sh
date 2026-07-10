#!/usr/bin/env bash
set -Eeuo pipefail
trap 'status=$?; echo "joint2D-SGD science runner failed at line ${LINENO}: ${BASH_COMMAND} (exit ${status})" >&2' ERR

usage() {
  cat <<'EOF'
Usage:
  .codex/run-joint2d-sgd-science.sh --check
  .codex/run-joint2d-sgd-science.sh --prepare-build
  .codex/run-joint2d-sgd-science.sh --prepare-betagal-extract
  .codex/run-joint2d-sgd-science.sh

Workstation layout:
  Build copy:  ~/Projects/SIMPLE_joint2d_sgd_build
  Test runs:   ~/Projects/simple_joint2d_sgd_science_<timestamp>

Default validation matrix:
  baseline:              sgd=no
  joint_topk1_equiv:     sgd=yes sgd_mode=joint sgd_topk=1 sgd_eta_cavg=1.0 sgd_eta_latent=0.5 sgd_balance_weight=0.0
  joint_default:         sgd=yes sgd_mode=joint sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_balance_weight=0.0
  latent_eta_0p1:        joint_default with sgd_eta_latent=0.1
  latent_eta_1p0:        joint_default with sgd_eta_latent=1.0
  cavg_eta_0p05:         joint_default with sgd_eta_cavg=0.05
  cavg_eta_0p25:         joint_default with sgd_eta_cavg=0.25
  balance_0p05:          joint_default with sgd_balance_weight=0.05

Environment overrides:
  JOINT2D_SGD_PROJECTS_HOME        Defaults to ~/Projects.
  JOINT2D_SGD_BUILD_COPY           Defaults to ~/Projects/SIMPLE_joint2d_sgd_build.
  JOINT2D_SGD_SCIENCE_ROOT         Defaults to ~/Projects/simple_joint2d_sgd_science_<timestamp>.
  JOINT2D_SGD_SCIENCE_PROJECT      Existing extracted .simple project for validation.
  JOINT2D_SGD_SCIENCE_REPS         Number of replicates. Defaults to 1; recommended 3.
  JOINT2D_SGD_SCIENCE_NCLS         abinitio2D ncls. Defaults to 100.
  JOINT2D_SGD_SCIENCE_MSKDIAM      abinitio2D mskdiam. Defaults to 190.
  JOINT2D_SGD_SCIENCE_NTHR         abinitio2D nthr. Defaults to 32.
  JOINT2D_SGD_BUILD_JOBS           Build jobs for --prepare-build. Defaults to 4.
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
case	replicate	mode	log_file	run_dir	project	ncls	mskdiam	nthr	topk	sgd_eta_latent	sgd_eta_cavg	sgd_balance_weight	params	status
EOF
}

record_manifest() {
  local case_name="$1"
  local rep="$2"
  local mode="$3"
  local log_file="$4"
  local run_dir="$5"
  local topk="$6"
  local eta_latent="$7"
  local eta_cavg="$8"
  local balance_weight="$9"
  local params="${10}"
  local status="${11}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$case_name" "$rep" "$mode" "$log_file" "$run_dir" "$project_path" \
    "$ncls" "$mskdiam" "$nthr" "$topk" "$eta_latent" "$eta_cavg" \
    "$balance_weight" "$params" "$status" >> "$manifest"
}

run_case() {
  local case_name="$1"
  local rep="$2"
  local mode="$3"
  local topk="$4"
  local eta_latent="$5"
  local eta_cavg="$6"
  local balance_weight="$7"
  shift 7
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
    if "$checker" "$mode" "$log_file" "$case_root" "$case_name" >"$status_file" 2>&1; then
      status="pass"
    else
      status="check_failed"
      cat "$status_file" >&2 || true
    fi
  else
    echo "run failed before checker; see $log_file" > "$status_file"
  fi

  record_manifest "$case_name" "$rep" "$mode" "$log_file" "$case_root" "$topk" \
    "$eta_latent" "$eta_cavg" "$balance_weight" "${params[*]}" "$status"
  if [[ "$status" == "pass" ]]; then
    echo "Log: $log_file"
  else
    failed_cases=$((failed_cases + 1))
    failed_case_list+=( "$case_id:$status:$log_file" )
    echo "Continuing after $case_id failed with status $status; log: $log_file" >&2
  fi
}

joint2d_sgd_runner_label="joint2D-SGD science runner"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
simple_home="$(cd -- "$script_dir/.." && pwd -P)"
# shellcheck source=.codex/joint2d-sgd-runner-common.sh
. "$script_dir/joint2d-sgd-runner-common.sh"
joint2d_sgd_common_init

checker="$script_dir/check-joint2d-sgd-science-log.sh"
summarizer="$script_dir/summarize-joint2d-sgd-science.sh"

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
  prepare_betagal_extract JOINT2D_SGD_SCIENCE_ROOT JOINT2D_SGD_SCIENCE_PROJECT .codex/run-joint2d-sgd-science.sh JOINT_SGD_SCIENCE_ROOT
  exit 0
fi

common_project_probe JOINT2D_SGD_SCIENCE_PROJECT JOINT_SGD_SCIENCE_PROJECT

if [[ "${1:-}" == "--check" ]]; then
  print_common_check "Default science root: $projects_home/simple_joint2d_sgd_science_<timestamp>"
  echo "Replicates: $(env_or_legacy JOINT2D_SGD_SCIENCE_REPS JOINT_SGD_SCIENCE_REPS 1)"
  cat <<'EOF'
Default validation matrix:
  baseline:              sgd=no
  joint_topk1_equiv:     sgd=yes sgd_mode=joint sgd_topk=1 sgd_eta_cavg=1.0 sgd_eta_latent=0.5 sgd_balance_weight=0.0
  joint_default:         sgd=yes sgd_mode=joint sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_balance_weight=0.0
  latent_eta_0p1:        joint_default with sgd_eta_latent=0.1
  latent_eta_1p0:        joint_default with sgd_eta_latent=1.0
  cavg_eta_0p05:         joint_default with sgd_eta_cavg=0.05
  cavg_eta_0p25:         joint_default with sgd_eta_cavg=0.25
  balance_0p05:          joint_default with sgd_balance_weight=0.05
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
nthr="$(env_or_legacy JOINT2D_SGD_SCIENCE_NTHR JOINT_SGD_SCIENCE_NTHR 32)"
manifest="$scratch_root/science_runs.tsv"

[[ "$reps" =~ ^[0-9]+$ && "$reps" -ge 1 ]] || fail "JOINT2D_SGD_SCIENCE_REPS must be a positive integer"

mkdir -p "$scratch_root"
write_manifest_header
total_cases=0
failed_cases=0
failed_case_list=()

echo "Science root: $scratch_root"
echo "Source project: $project_path"
echo "Workflow root: $workflow_root"
echo "Project relative path: $project_rel"
echo "ncls=$ncls mskdiam=$mskdiam nthr=$nthr reps=$reps"

for rep in $(seq 1 "$reps"); do
  run_case baseline "$rep" baseline NA NA NA NA sgd=no
  run_case joint_topk1_equiv "$rep" joint 1 0.5 1.0 0.0 \
    sgd=yes sgd_mode=joint sgd_topk=1 sgd_eta_cavg=1.0 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_diag=yes
  run_case joint_default "$rep" joint 3 0.5 0.1 0.0 \
    sgd=yes sgd_mode=joint sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_diag=yes
  run_case latent_eta_0p1 "$rep" joint 3 0.1 0.1 0.0 \
    sgd=yes sgd_mode=joint sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=0.1 sgd_balance_weight=0.0 sgd_diag=yes
  run_case latent_eta_1p0 "$rep" joint 3 1.0 0.1 0.0 \
    sgd=yes sgd_mode=joint sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=1.0 sgd_balance_weight=0.0 sgd_diag=yes
  run_case cavg_eta_0p05 "$rep" joint 3 0.5 0.05 0.0 \
    sgd=yes sgd_mode=joint sgd_topk=3 sgd_eta_cavg=0.05 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_diag=yes
  run_case cavg_eta_0p25 "$rep" joint 3 0.5 0.25 0.0 \
    sgd=yes sgd_mode=joint sgd_topk=3 sgd_eta_cavg=0.25 sgd_eta_latent=0.5 sgd_balance_weight=0.0 sgd_diag=yes
  run_case balance_0p05 "$rep" joint 3 0.5 0.1 0.05 \
    sgd=yes sgd_mode=joint sgd_topk=3 sgd_eta_cavg=0.1 sgd_eta_latent=0.5 sgd_balance_weight=0.05 sgd_diag=yes
done

"$summarizer" "$scratch_root"
echo "joint2D-SGD scientific validation complete: $scratch_root"
echo "Cases completed: $total_cases"
echo "Cases failed: $failed_cases"
if [[ "$failed_cases" -gt 0 ]]; then
  echo "Failed cases:" >&2
  printf '  %s\n' "${failed_case_list[@]}" >&2
  echo "Science root with logs and summary: $scratch_root" >&2
  exit 1
fi
