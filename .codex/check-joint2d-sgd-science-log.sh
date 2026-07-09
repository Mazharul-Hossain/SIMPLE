#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  .codex/check-joint2d-sgd-science-log.sh baseline <LOG> [RUN_DIR] [CASE]
  .codex/check-joint2d-sgd-science-log.sh joint    <LOG> [RUN_DIR] [CASE]

Checks logs produced by .codex/run-joint2d-sgd-science.sh. RUN_DIR is optional;
when provided, the checker also verifies that abinitio2D output and class/FRC
artifacts exist.
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
joint2d_checker_label="joint2D-SGD science log check"
joint2d_check_global_nonfinite="yes"
# shellcheck source=.codex/joint2d-sgd-checker-common.sh
. "$script_dir/joint2d-sgd-checker-common.sh"

if [[ $# -lt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

mode="$1"
log_file="$2"
run_dir="${3:-}"
case_name="${4:-unknown}"

[[ -f "$log_file" ]] || fail "log file does not exist: $log_file"

check_common_failure_markers
check_normal_stop

case "$mode" in
  baseline)
    check_baseline_log
    ;;
  joint)
    check_science_joint_log "$case_name"
    ;;
  *)
    fail "mode must be baseline or joint"
    ;;
esac

check_run_outputs "$run_dir" yes
echo "joint2D-SGD science log check passed: $mode $log_file"
