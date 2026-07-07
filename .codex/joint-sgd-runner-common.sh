#!/usr/bin/env bash

# Shared helpers for the joint-SGD smoke and science runners. This file is
# sourced by wrapper scripts; keep user-facing entrypoints in those wrappers.

joint_sgd_common_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
joint_sgd_default_simple_home="$(cd -- "$joint_sgd_common_dir/.." && pwd -P)"

fail() {
  echo "${joint_sgd_runner_label:-joint-SGD runner} failed: $*" >&2
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

joint_sgd_common_init() {
  script_dir="${script_dir:-$joint_sgd_common_dir}"
  simple_home="${simple_home:-$joint_sgd_default_simple_home}"
  testing_home="${SIMPLE_DATA_TESTING_HOME:-${simple_home}_data_testing}"
  projects_home="${JOINT_SGD_PROJECTS_HOME:-$HOME/Projects}"
  build_copy="${JOINT_SGD_BUILD_COPY:-$projects_home/SIMPLE_joint_sgd_build}"
  build_jobs="${JOINT_SGD_BUILD_JOBS:-4}"
  cmake_build_type="${JOINT_SGD_CMAKE_BUILD_TYPE:-Debug}"
  betagal_data="${JOINT_SGD_BETAGAL_DATA:-/mnt/beegfs/elmlund/testing-datasets/betagal}"
}

find_simple_exec_dir() {
  local candidate_dir="$1"
  if [[ -f "$candidate_dir" ]]; then
    candidate_dir="$(dirname -- "$candidate_dir")"
  fi
  [[ -d "$candidate_dir" ]] || return 1

  if [[ -x "$candidate_dir/simple_exec" || -x "$candidate_dir/simple_exec.exe" ]]; then
    simple_exec_dir="$(cd -- "$candidate_dir" && pwd -P)"
    if [[ "$(basename -- "$simple_exec_dir")" == "bin" ]]; then
      simple_install_root="$(cd -- "$simple_exec_dir/.." && pwd -P)"
    elif [[ "$(basename -- "$simple_exec_dir")" == "production" && "$(basename -- "$(dirname -- "$simple_exec_dir")")" == build* ]]; then
      simple_install_root="$(cd -- "$simple_exec_dir/../.." && pwd -P)"
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
  local -a candidate_dirs=()

  if [[ -d /ucrt64/bin ]]; then
    prepend_path /ucrt64/bin
  fi

  if [[ -n "${SIMPLE_PATH:-}" ]]; then
    prepend_path "$SIMPLE_PATH/bin"
    prepend_path "$SIMPLE_PATH/scripts"
    candidate_dirs+=(
      "$SIMPLE_PATH/bin"
      "$SIMPLE_PATH"
      "$SIMPLE_PATH/build-debug/bin"
      "$SIMPLE_PATH/build-debug"
      "$SIMPLE_PATH/build-debug/production"
      "$SIMPLE_PATH/build/bin"
      "$SIMPLE_PATH/build"
      "$SIMPLE_PATH/build/production"
    )
  fi

  if [[ -n "${SIMPLE_EXEC_DIR:-}" ]]; then
    find_simple_exec_dir "$SIMPLE_EXEC_DIR" || fail "SIMPLE_EXEC_DIR does not contain simple_exec: $SIMPLE_EXEC_DIR"
  else
    candidate_dirs+=(
      "$build_copy/build-debug/bin" \
      "$build_copy/build-debug" \
      "$build_copy/build-debug/production" \
      "$build_copy/build/bin" \
      "$build_copy/build" \
      "$build_copy/build/production" \
      "$simple_home/build-debug/bin" \
      "$simple_home/build-debug" \
      "$simple_home/build-debug/production" \
      "$simple_home/build-release/bin" \
      "$simple_home/build-release" \
      "$simple_home/build-release/production" \
      "$simple_home/bin" \
      "$simple_home/build/bin" \
      "$simple_home/build" \
      "$simple_home/build/production" \
      "$projects_home/SIMPLE/build-debug/bin" \
      "$projects_home/SIMPLE/build-debug" \
      "$projects_home/SIMPLE/build-debug/production" \
      "$projects_home/SIMPLE/build/bin" \
      "$projects_home/SIMPLE/build" \
      "$projects_home/SIMPLE/build/production"
    )

    for candidate_dir in "${candidate_dirs[@]}"
    do
      if find_simple_exec_dir "$candidate_dir"; then
        break
      fi
    done
  fi

  if [[ -n "$simple_install_root" ]]; then
    export SIMPLE_PATH="${SIMPLE_PATH:-$simple_install_root}"
    prepend_path "$simple_exec_dir"
    prepend_path "$simple_install_root/bin"
    prepend_path "$simple_install_root/scripts"
    prepend_path "$SIMPLE_PATH/bin"
    prepend_path "$SIMPLE_PATH/scripts"
  elif [[ -n "$simple_exec_dir" ]]; then
    prepend_path "$simple_exec_dir"
  fi

  export SIMPLE_QSYS="${SIMPLE_QSYS:-local}"
}

discover_project_from_env() {
  local project_env_var="$1"
  local explicit_project="${!project_env_var:-}"
  local -a search_roots=()

  if [[ -n "$explicit_project" ]]; then
    [[ -f "$explicit_project" ]] || fail "$project_env_var does not exist: $explicit_project"
    project_path="$(cd -- "$(dirname -- "$explicit_project")" && pwd -P)/$(basename -- "$explicit_project")"
    return 0
  fi

  [[ -d "$projects_home" ]] && search_roots+=("$projects_home")
  [[ -d "$testing_home" ]] && search_roots+=("$testing_home")
  [[ "${#search_roots[@]}" -gt 0 ]] || return 1

  project_path="$(find "${search_roots[@]}" -path '*/5_extract/*.simple' -type f 2>/dev/null | sort | head -n 1 || true)"
  [[ -n "$project_path" ]] || return 1
  project_path="$(cd -- "$(dirname -- "$project_path")" && pwd -P)/$(basename -- "$project_path")"
  return 0
}

common_project_probe() {
  local project_env_var="$1"
  project_path=""
  project_found="yes"
  if ! discover_project_from_env "$project_env_var"; then
    project_found="no"
  fi

  data_hint="available"
  if [[ ! -d "$betagal_data" ]]; then
    data_hint="missing"
  fi
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
    mkdir -p build-debug
    echo "Configuring CMake build type: $cmake_build_type"
    cmake -S . -B build-debug -DCMAKE_BUILD_TYPE="$cmake_build_type" 2>&1 | tee build-debug/configure.log
    echo "Building with verbose output; logs: $build_copy/build-debug/build.log"
    cmake --build build-debug --parallel "$build_jobs" --verbose 2>&1 | tee build-debug/build.log
  )
  echo "Build copy ready: $build_copy"
}

prepare_betagal_extract() {
  local prep_root_env_var="$1"
  local project_env_var="$2"
  local runner_script="$3"
  local prep_root="${!prep_root_env_var:-$projects_home/simple_joint_sgd_betagal_extract_$(date +%Y%m%d_%H%M%S)}"

  [[ -d "$betagal_data" ]] || fail "betagal NAS data not reachable: $betagal_data"
  command -v simple_exec >/dev/null 2>&1 || fail "simple_exec is not on PATH; run --prepare-build or set SIMPLE_EXEC_DIR"
  command -v filetab_movs.pl >/dev/null 2>&1 || fail "filetab_movs.pl is not on PATH through SIMPLE_PATH/scripts"

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
  echo "Run validation with:"
  echo "$project_env_var=$prep_root/betagal/5_extract/betagal.simple $runner_script"
}

copy_case_root() {
  local case_id="$1"
  local dest="$scratch_root/$case_id/$(basename -- "$workflow_root")"
  mkdir -p "$scratch_root/$case_id"
  cp -a "$workflow_root" "$scratch_root/$case_id/"
  case_root="$dest"
  case_project="$case_root/$project_rel"
  [[ -f "$case_project" ]] || fail "copied project not found: $case_project"
}

print_common_check() {
  local root_line="$1"
  local simple_exec_path
  simple_exec_path="$(command -v simple_exec 2>/dev/null || true)"

  echo "SIMPLE home: $simple_home"
  echo "Projects home: $projects_home"
  echo "Build copy: $build_copy"
  if [[ -e "$build_copy" ]]; then
    echo "Build copy exists: yes"
  else
    echo "Build copy exists: no"
  fi
  echo "Build type: $cmake_build_type"
  echo "Build jobs: $build_jobs"
  echo "SIMPLE path: ${SIMPLE_PATH:-not set}"
  if [[ -d "$testing_home" ]]; then
    echo "Testing home: $testing_home"
  else
    echo "Testing home: missing ($testing_home)"
  fi
  if [[ -n "${simple_exec_dir:-}" ]]; then
    echo "Discovered simple_exec dir: $simple_exec_dir"
  fi
  echo "simple_exec: ${simple_exec_path:-not found}"
  if [[ -z "$simple_exec_path" ]]; then
    echo "simple_exec hint: run --prepare-build, or set SIMPLE_EXEC_DIR to the directory containing simple_exec"
  fi
  echo "Project found: $project_found"
  [[ "$project_found" == "yes" ]] && echo "Project: $project_path"
  echo "Betagal NAS data: $data_hint ($betagal_data)"
  echo "$root_line"
}

require_common_inputs() {
  local checker="$1"
  [[ -f "$checker" ]] || fail "checker script not found: $checker"
}

require_project_or_explain() {
  local label="$1"
  local project_env_var="$2"

  if [[ "$project_found" == "yes" ]]; then
    return 0
  fi

  if [[ "$data_hint" == "missing" ]]; then
    fail "no extracted $label project found and betagal NAS data are unavailable; set $project_env_var or run on the workstation after SSH/NAS setup"
  fi
  fail "NAS data are available, but no extracted $label project was found; run --prepare-betagal-extract or set $project_env_var"
}
