#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  .codex/check-joint2d-sgd-smoke-log.sh baseline         <LOG> [RUN_DIR]
  .codex/check-joint2d-sgd-smoke-log.sh stage4_off       <LOG> [RUN_DIR]
  .codex/check-joint2d-sgd-smoke-log.sh stage4_alternate <LOG> [RUN_DIR]
  .codex/check-joint2d-sgd-smoke-log.sh stage4_alternate_stream <LOG> [RUN_DIR]
  .codex/check-joint2d-sgd-smoke-log.sh stage4_alternate_balance <LOG> [RUN_DIR]
  .codex/check-joint2d-sgd-smoke-log.sh stage4_alternate_assignment_only <LOG> [RUN_DIR]

Checks the shared-memory joint2D-SGD smoke logs produced by
.codex/run-joint2d-sgd-smoke.sh. RUN_DIR is optional; when provided, the checker
also looks for abinitio2D output directories and FRC/class-average-like files.
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
joint2d_checker_label="joint2D-SGD smoke log check"
# shellcheck source=.codex/joint2d-sgd-checker-common.sh
. "$script_dir/joint2d-sgd-checker-common.sh"

if [[ $# -lt 2 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

case_name="$1"
log_file="$2"
run_dir="${3:-}"

[[ -f "$log_file" ]] || fail "log file does not exist: $log_file"

check_common_failure_markers
check_normal_stop

case "$case_name" in
  baseline)
    check_baseline_log
    ;;
  stage4_off)
    check_smoke_joint_log off 1
    ;;
  stage4_alternate)
    check_smoke_joint_log alternate 3
    ;;
  stage4_alternate_stream)
    check_stream_joint_log alternate
    ;;
  stage4_alternate_balance)
    check_smoke_joint_log alternate 3
    check_nonzero_balance_prior
    ;;
  stage4_alternate_balance_eta0p05)
    check_smoke_joint_log alternate 3
    check_nonzero_balance_prior
    ;;
  stage4_alternate_raw_likelihood)
    check_smoke_joint_log alternate 3
    ;;
  stage4_alternate_balance_topk5|stage4_alternate_balance_topk5_raw)
    check_smoke_joint_log alternate 5
    check_nonzero_balance_prior
    ;;
  stage4_alternate_assignment_only)
    check_assignment_only_ablation
    check_smoke_joint_log alternate 3
    ;;
  *)
    fail "unknown smoke case: $case_name"
    ;;
esac

check_run_outputs "$run_dir"
if [[ "$case_name" == stage4_alternate_assignment_only ]]; then
  check_assignment_only_mrc_invariant "$run_dir"
fi
echo "joint2D-SGD smoke log check passed: $case_name $log_file"
