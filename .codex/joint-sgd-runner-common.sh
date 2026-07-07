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
  inherited_simple_path="${SIMPLE_PATH:-}"
  testing_home="${SIMPLE_DATA_TESTING_HOME:-${simple_home}_data_testing}"
  projects_home="${JOINT_SGD_PROJECTS_HOME:-$HOME/Projects}"
  build_copy="${JOINT_SGD_BUILD_COPY:-$projects_home/SIMPLE_joint_sgd_build}"
  build_jobs="${JOINT_SGD_BUILD_JOBS:-4}"
  cmake_build_type="${JOINT_SGD_CMAKE_BUILD_TYPE:-Debug}"
  betagal_data="${JOINT_SGD_BETAGAL_DATA:-/mnt/beegfs/elmlund/testing-datasets/betagal}"
  betagal_sample_count="${JOINT_SGD_BETAGAL_SAMPLE_COUNT:-}"
  prep_nparts="${JOINT_SGD_PREP_NPARTS:-1}"
  prep_nthr="${JOINT_SGD_PREP_NTHR:-4}"
}

resolve_simple_install_root() {
  local probe="$1"
  local depth

  probe="$(cd -- "$probe" && pwd -P)" || return 1
  for depth in 0 1 2 3 4; do
    if [[ -d "$probe/scripts" ]]; then
      echo "$probe"
      return 0
    fi
    probe="$(cd -- "$probe/.." && pwd -P)" || return 1
  done
  return 1
}

find_simple_exec_dir() {
  local candidate_dir="$1"
  local resolved_root=""
  if [[ -f "$candidate_dir" ]]; then
    candidate_dir="$(dirname -- "$candidate_dir")"
  fi
  [[ -d "$candidate_dir" ]] || return 1

  if [[ -x "$candidate_dir/simple_exec" || -x "$candidate_dir/simple_exec.exe" ]]; then
    simple_exec_dir="$(cd -- "$candidate_dir" && pwd -P)"
    if resolved_root="$(resolve_simple_install_root "$simple_exec_dir")"; then
      simple_install_root="$resolved_root"
    elif [[ "$(basename -- "$simple_exec_dir")" == "bin" ]]; then
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

find_simple_script() {
  local script_name="$1"
  local found_path=""
  local -a candidates=()

  if found_path="$(command -v "$script_name" 2>/dev/null)"; then
    echo "$found_path"
    return 0
  fi

  candidates+=(
    "${SIMPLE_PATH:-}/scripts/$script_name"
    "${simple_install_root:-}/scripts/$script_name"
    "$build_copy/scripts/$script_name"
    "$simple_home/scripts/$script_name"
    "$projects_home/SIMPLE/scripts/$script_name"
  )

  for found_path in "${candidates[@]}"; do
    if [[ -f "$found_path" ]]; then
      found_path="$(cd -- "$(dirname -- "$found_path")" && pwd -P)/$(basename -- "$found_path")"
      echo "$found_path"
      return 0
    fi
  done
  return 1
}

run_simple_script() {
  local script_path="$1"
  shift

  if [[ -x "$script_path" ]]; then
    "$script_path" "$@"
    return
  fi

  command -v perl >/dev/null 2>&1 || fail "Perl is required to run non-executable SIMPLE script: $script_path"
  perl "$script_path" "$@"
}

prep_log() {
  local line
  line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  printf '%s\n' "$line"
  if [[ -n "${PREP_LOG_FILE:-}" ]]; then
    printf '%s\n' "$line" >> "$PREP_LOG_FILE"
  fi
}

run_prep_cmd() {
  local stage="$1"
  local log_file="$2"
  shift 2
  local status

  prep_log "START $stage"
  prep_log "Log: $log_file"
  prep_log "Command: $*"
  set +e
  "$@" 2>&1 | tee -a "$log_file"
  status=${PIPESTATUS[0]}
  set -e
  if [[ "$status" -ne 0 ]]; then
    prep_log "FAILED $stage exit=$status"
    return "$status"
  fi
  prep_log "DONE $stage"
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
    if [[ -z "${SIMPLE_PATH:-}" || ! -d "$SIMPLE_PATH/scripts" ]]; then
      export SIMPLE_PATH="$simple_install_root"
    fi
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
  local filetab_movs_pl=""
  local filetab_mrc_pl=""
  local simple_log=""

  [[ -d "$betagal_data" ]] || fail "betagal NAS data not reachable: $betagal_data"
  command -v simple_exec >/dev/null 2>&1 || fail "simple_exec is not on PATH; run --prepare-build or set SIMPLE_EXEC_DIR"
  filetab_movs_pl="$(find_simple_script filetab_movs.pl)" || fail "filetab_movs.pl not found; set SIMPLE_PATH to a SIMPLE source/build root with scripts/"
  filetab_mrc_pl="$(find_simple_script filetab_mrc.pl)" || fail "filetab_mrc.pl not found; set SIMPLE_PATH to a SIMPLE source/build root with scripts/"

  [[ "$prep_nparts" =~ ^[0-9]+$ && "$prep_nparts" -ge 1 ]] || fail "JOINT_SGD_PREP_NPARTS must be a positive integer"
  [[ "$prep_nthr" =~ ^[0-9]+$ && "$prep_nthr" -ge 1 ]] || fail "JOINT_SGD_PREP_NTHR must be a positive integer"
  if [[ -n "$betagal_sample_count" ]]; then
    [[ "$betagal_sample_count" =~ ^[0-9]+$ && "$betagal_sample_count" -ge 1 ]] || fail "JOINT_SGD_BETAGAL_SAMPLE_COUNT must be a positive integer when set"
  fi

  mkdir -p "$prep_root"
  PREP_LOG_FILE="$prep_root/prepare-betagal-extract.log"
  : > "$PREP_LOG_FILE"

  prep_log "Betagal prep root: $prep_root"
  prep_log "Wrapper log: $PREP_LOG_FILE"
  prep_log "Betagal data root: $betagal_data"
  prep_log "Betagal prep nparts=$prep_nparts nthr=$prep_nthr sample_count=${betagal_sample_count:-all}"
  prep_log "This prep reads NAS files as SIMPLE needs them; it does not batch-copy /mnt/beegfs."

  (
    cd "$prep_root"
    run_prep_cmd "new_project" "$PREP_LOG_FILE" simple_exec prg=new_project projname=betagal
    cd betagal
    simple_log="$PWD/LOG"
    : > "$simple_log"
    prep_log "SIMPLE pipeline log: $simple_log"
    prep_log "Writing movies.txt from NAS movie directory"
    if [[ -n "$betagal_sample_count" ]]; then
      run_prep_cmd "filetab_movs" "$PREP_LOG_FILE" run_simple_script "$filetab_movs_pl" "$betagal_data/movies" "$betagal_sample_count"
    else
      run_prep_cmd "filetab_movs" "$PREP_LOG_FILE" run_simple_script "$filetab_movs_pl" "$betagal_data/movies"
    fi
    echo " >>> PROGRAM: import_movies" | tee -a "$simple_log"
    run_prep_cmd "import_movies" "$simple_log" simple_exec prg=import_movies cs=1.4 fraca=0.1 kv=200 smpd=0.885 filetab=movies.txt
    echo " >>> PROGRAM: motion_correct" | tee -a "$simple_log"
    run_prep_cmd "motion_correct" "$simple_log" simple_exec prg=motion_correct nparts="$prep_nparts" nthr="$prep_nthr" gainref="$betagal_data/gain/gain.mrc" total_dose=30.65 smpd_downscale=1.3
    echo " >>> PROGRAM: ctf_estimate" | tee -a "$simple_log"
    run_prep_cmd "ctf_estimate" "$simple_log" simple_exec prg=ctf_estimate nparts="$prep_nparts" nthr="$prep_nthr" projfile=2_motion_correct/betagal.simple
    run_prep_cmd "filetab_mrc" "$PREP_LOG_FILE" run_simple_script "$filetab_mrc_pl" 2_motion_correct/
    echo " >>> PROGRAM: pick" | tee -a "$simple_log"
    run_prep_cmd "pick" "$simple_log" simple_exec prg=pick picker=segdiam projfile=3_ctf_estimate/betagal.simple nparts="$prep_nparts" nthr="$prep_nthr"
    echo " >>> PROGRAM: extract" | tee -a "$simple_log"
    run_prep_cmd "extract" "$simple_log" simple_exec prg=extract box=256 nparts="$prep_nparts" nthr="$prep_nthr" projfile=4_pick/betagal.simple
  )
  prep_log "Betagal extraction complete"
  echo "Betagal extracted project ready: $prep_root/betagal/5_extract/betagal.simple"
  echo "Wrapper log: $PREP_LOG_FILE"
  echo "SIMPLE pipeline log: $prep_root/betagal/LOG"
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
  local filetab_movs_path
  local filetab_mrc_path
  simple_exec_path="$(command -v simple_exec 2>/dev/null || true)"
  filetab_movs_path="$(find_simple_script filetab_movs.pl 2>/dev/null || true)"
  filetab_mrc_path="$(find_simple_script filetab_mrc.pl 2>/dev/null || true)"

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
  echo "Betagal prep nparts: $prep_nparts"
  echo "Betagal prep nthr: $prep_nthr"
  echo "Betagal sample count: ${betagal_sample_count:-all}"
  echo "Inherited SIMPLE_PATH: ${inherited_simple_path:-not set}"
  echo "Effective SIMPLE_PATH: ${SIMPLE_PATH:-not set}"
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
  echo "filetab_movs.pl: ${filetab_movs_path:-not found}"
  echo "filetab_mrc.pl: ${filetab_mrc_path:-not found}"
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
