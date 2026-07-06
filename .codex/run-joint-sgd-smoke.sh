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
  SIMPLE_DATA_TESTING_HOME      Sibling SIMPLE_data_testing repository.
  SIMPLE_EXEC_DIR               Directory containing simple_exec or simple_exec.exe.

NAS rule:
  Do not batch-copy /mnt/beegfs data. On the Oracle Linux workstation, the
  prepare-betagal-extract mode reads /mnt/beegfs files as SIMPLE needs them and
  writes all project/intermediate outputs under ~/Projects.
EOF
}

fail() {
  echo "joint-SGD smoke runner failed: $*" >&2
  exit 1
}

prepend_path() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  case ":$PATH:" in
    *":$dir:"*) ;;
    *) PATH="$dir:$PATH" ;;
  esac
}

find_simple_exec_dir() {
  local candidate_dir="$1"
  [[ -d "$candidate_dir" ]] || return 1

  if [[ -x "$candidate_dir/simple_exec" || -x "$candidate_dir/simple_exec.exe" ]]; then
    simple_exec_dir="$(cd -- "$candidate_dir" && pwd -P)"
    if [[ "$(basename -- "$simple_exec_dir")" == "bin" ]]; then
      simple_install_root="$(cd -- "$simple_exec_dir/.." && pwd -P)"
    else
      simple_install_root="$simple_exec_dir"
    fi
    return 0
  fi
  return 1
}

setup_simple_path() {
  simple_exec_dir=""
  simple_install_root=""

  if [[ -d /ucrt64/bin ]]; then
    prepend_path /ucrt64/bin
  fi

  if [[ -n "${SIMPLE_EXEC_DIR:-}" ]]; then
    find_simple_exec_dir "$SIMPLE_EXEC_DIR" || fail "SIMPLE_EXEC_DIR does not contain simple_exec: $SIMPLE_EXEC_DIR"
  else
    for candidate_dir in \
      "$build_copy/build-debug/bin" \
      "$build_copy/build-debug" \
      "$simple_home/build-debug/bin" \
      "$simple_home/build-debug" \
      "$simple_home/build-release/bin" \
      "$simple_home/build-release" \
      "$simple_home/bin" \
      "$simple_home/build/bin" \
      "$simple_home/build"
    do
      if find_simple_exec_dir "$candidate_dir"; then
        break
      fi
    done
  fi

  if [[ -n "$simple_install_root" ]]; then
    export SIMPLE_PATH="${SIMPLE_PATH:-$simple_install_root}"
    prepend_path "$SIMPLE_PATH/bin"
    prepend_path "$SIMPLE_PATH/scripts"
  elif [[ -n "$simple_exec_dir" ]]; then
    prepend_path "$simple_exec_dir"
  fi

  export SIMPLE_QSYS="${SIMPLE_QSYS:-local}"
}

discover_project() {
  if [[ -n "${JOINT_SGD_SMOKE_PROJECT:-}" ]]; then
    [[ -f "$JOINT_SGD_SMOKE_PROJECT" ]] || fail "JOINT_SGD_SMOKE_PROJECT does not exist: $JOINT_SGD_SMOKE_PROJECT"
    project_path="$(cd -- "$(dirname -- "$JOINT_SGD_SMOKE_PROJECT")" && pwd -P)/$(basename -- "$JOINT_SGD_SMOKE_PROJECT")"
    return 0
  fi

  project_path="$(find "$projects_home" "$testing_home" -path '*/5_extract/*.simple' -type f 2>/dev/null | sort | head -n 1 || true)"
  [[ -n "$project_path" ]] || return 1
  project_path="$(cd -- "$(dirname -- "$project_path")" && pwd -P)/$(basename -- "$project_path")"
  return 0
}

infer_workflow_root() {
  local project="$1"
  local project_dir parent_dir parent_name
  project_dir="$(cd -- "$(dirname -- "$project")" && pwd -P)"
  parent_dir="$(cd -- "$project_dir/.." && pwd -P)"
  parent_name="$(basename -- "$project_dir")"

  case "$parent_name" in
    [0-9]_*|[0-9][0-9]_*)
      workflow_root="$parent_dir"
      project_rel="${project#$workflow_root/}"
      ;;
    *)
      workflow_root="$project_dir"
      project_rel="$(basename -- "$project")"
      ;;
  esac
}

prepare_build_copy() {
  mkdir -p "$projects_home"
  if [[ -e "$build_copy" ]]; then
    fail "build copy already exists: $build_copy; move it aside or set JOINT_SGD_BUILD_COPY"
  fi

  git clone "$simple_home" "$build_copy"
  (
    cd "$build_copy"
    cmake -S . -B build-debug
    cmake --build build-debug -j "$build_jobs"
  )
  echo "Build copy ready: $build_copy"
}

prepare_betagal_extract() {
  [[ -d "$betagal_data" ]] || fail "betagal NAS data not reachable: $betagal_data"
  command -v simple_exec >/dev/null 2>&1 || fail "simple_exec is not on PATH; run --prepare-build or set SIMPLE_EXEC_DIR"
  command -v filetab_movs.pl >/dev/null 2>&1 || fail "filetab_movs.pl is not on PATH through SIMPLE_PATH/scripts"

  local prep_root="${JOINT_SGD_SMOKE_ROOT:-$projects_home/simple_joint_sgd_betagal_extract_$(date +%Y%m%d_%H%M%S)}"
  mkdir -p "$prep_root"
  (
    cd "$prep_root"
    simple_exec prg=new_project projname=betagal > LOG
    cd betagal
    filetab_movs.pl "$betagal_data/movies"
    echo " >>> PROGRAM: import_movies" > LOG
    simple_exec prg=import_movies cs=1.4 fraca=0.1 kv=200 smpd=0.885 filetab=movies.txt >> LOG
    echo " >>> PROGRAM: motion_correct" >> LOG
    simple_exec prg=motion_correct nparts=5 nthr=8 gainref="$betagal_data/gain/gain.mrc" total_dose=30.65 smpd_downscale=1.3 >> LOG
    echo " >>> PROGRAM: ctf_estimate" >> LOG
    simple_exec prg=ctf_estimate nparts=5 nthr=8 projfile=2_motion_correct/betagal.simple >> LOG
    filetab_mrc.pl 2_motion_correct/
    echo " >>> PROGRAM: pick" >> LOG
    simple_exec prg=pick picker=segdiam projfile=3_ctf_estimate/betagal.simple nparts=5 nthr=8 >> LOG
    echo " >>> PROGRAM: extract" >> LOG
    simple_exec prg=extract box=256 nparts=5 nthr=8 projfile=4_pick/betagal.simple >> LOG
  )
  echo "Betagal extracted project ready: $prep_root/betagal/5_extract/betagal.simple"
  echo "Run smoke with:"
  echo "JOINT_SGD_SMOKE_PROJECT=$prep_root/betagal/5_extract/betagal.simple .codex/run-joint-sgd-smoke.sh"
}

copy_case_root() {
  local case_name="$1"
  local dest="$scratch_root/$case_name/$(basename -- "$workflow_root")"
  mkdir -p "$scratch_root/$case_name"
  cp -a "$workflow_root" "$scratch_root/$case_name/"
  case_root="$dest"
  case_project="$case_root/$project_rel"
  [[ -f "$case_project" ]] || fail "copied project not found: $case_project"
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

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
simple_home="$(cd -- "$script_dir/.." && pwd -P)"
testing_home="${SIMPLE_DATA_TESTING_HOME:-${simple_home}_data_testing}"
projects_home="${JOINT_SGD_PROJECTS_HOME:-$HOME/Projects}"
build_copy="${JOINT_SGD_BUILD_COPY:-$projects_home/SIMPLE_joint_sgd_build}"
build_jobs="${JOINT_SGD_BUILD_JOBS:-4}"
checker="$script_dir/check-joint-sgd-smoke-log.sh"
betagal_data="/mnt/beegfs/elmlund/testing-datasets/betagal"

[[ -d "$testing_home" ]] || fail "SIMPLE_data_testing repo was not found: $testing_home"
[[ -x "$checker" || -f "$checker" ]] || fail "checker script not found: $checker"

setup_simple_path

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

if [[ "${1:-}" == "--prepare-betagal-extract" ]]; then
  setup_simple_path
  prepare_betagal_extract
  exit 0
fi

project_path=""
project_found="yes"
if ! discover_project; then
  project_found="no"
fi

data_hint="available"
if [[ ! -d "$betagal_data" ]]; then
  data_hint="missing"
fi

if [[ "${1:-}" == "--check" ]]; then
  echo "SIMPLE home: $simple_home"
  echo "Projects home: $projects_home"
  echo "Build copy: $build_copy"
  echo "SIMPLE path: ${SIMPLE_PATH:-not set}"
  echo "Testing home: $testing_home"
  echo "simple_exec: $(command -v simple_exec || echo not found)"
  echo "Project found: $project_found"
  [[ "$project_found" == "yes" ]] && echo "Project: $project_path"
  echo "Betagal NAS data: $data_hint ($betagal_data)"
  echo "Default smoke root: $projects_home/simple_joint_sgd_smoke_<timestamp>"
  exit 0
fi

command -v simple_exec >/dev/null 2>&1 || fail "simple_exec is not on PATH; run --prepare-build or set SIMPLE_EXEC_DIR"

if [[ "$project_found" != "yes" ]]; then
  if [[ "$data_hint" == "missing" ]]; then
    fail "no extracted smoke project found and betagal NAS data are unavailable; set JOINT_SGD_SMOKE_PROJECT or run on the workstation after SSH/NAS setup"
  fi
  fail "NAS data are available, but no extracted smoke project was found; run --prepare-betagal-extract or set JOINT_SGD_SMOKE_PROJECT"
fi

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
