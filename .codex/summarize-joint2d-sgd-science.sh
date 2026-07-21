#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  .codex/summarize-joint2d-sgd-science.sh <SCIENCE_ROOT>

Reads SCIENCE_ROOT/science_runs.tsv and writes:
  SCIENCE_ROOT/science_metrics.csv
  SCIENCE_ROOT/science_iterations.csv
  SCIENCE_ROOT/science_summary.md

The summarizer is report-only. It parses existing log markers and text STAR-like
exports when available. Binary SIMPLE project/FRC files are not modified.
EOF
}

fail() {
  echo "joint2D-SGD science summarizer failed: $*" >&2
  exit 1
}

csv_escape() {
  local v="${1:-}"
  v="${v//$'\r'/ }"
  v="${v//$'\n'/ }"
  v="${v//\"/\"\"}"
  printf '"%s"' "$v"
}

emit_csv_row() {
  local first=1
  local v
  for v in "$@"; do
    if [[ "$first" -eq 1 ]]; then
      first=0
    else
      printf ','
    fi
    csv_escape "$v"
  done
  printf '\n'
}

kv_last() {
  local file="$1"
  local marker="$2"
  local key="$3"
  [[ -f "$file" ]] || { echo "NA"; return 0; }
  awk -v marker="$marker" -v key="$key" '
    index($0, marker) { line=$0 }
    END {
      if (line == "") { print "NA"; exit }
      n = split(line, a, /[[:space:]]+/)
      prefix = key "="
      for (i = 1; i <= n; i++) {
        if (a[i] == prefix && i < n) { print a[i+1]; exit }
        if (index(a[i], prefix) == 1) {
          v = substr(a[i], length(prefix) + 1)
          if (v != "") { print v; exit }
          if (i < n) { print a[i+1]; exit }
        }
      }
      print "NA"
    }' "$file"
}

profile_sum() {
  local file="$1"
  local component="$2"
  local key="$3"
  [[ -f "$file" ]] || { echo "NA"; return 0; }
  awk -v component="$component" -v key="$key" '
    function value(line, wanted,    n,a,i,prefix,v) {
      n = split(line, a, /[[:space:]]+/)
      prefix = wanted "="
      for (i = 1; i <= n; i++) {
        if (a[i] == prefix && i < n) return a[i+1]
        if (index(a[i], prefix) == 1) {
          v = substr(a[i], length(prefix) + 1)
          if (v != "") return v
          if (i < n) return a[i+1]
        }
      }
      return ""
    }
    /JOINT2D SGD PROFILE:/ {
      if (value($0, "component") != component) next
      v = value($0, key)
      if (v != "" && v ~ /^[-+0-9.eE]+$/) { total += v; found = 1 }
    }
    END { if (found) printf "%.6f\n", total; else print "NA" }
  ' "$file"
}

execution_seconds() {
  local file="$1"
  [[ -f "$file" ]] || { echo "NA"; return 0; }
  awk '
    /Execution time:/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "seconds" && i > 1 && $(i-1) ~ /^[0-9.eE+-]+$/) value = $(i-1)
      }
    }
    END { if (value == "") print "NA"; else print value }
  ' "$file"
}

resolution_lt10_metrics() {
  local file="$1"
  [[ -f "$file" ]] || { echo "NA,NA"; return 0; }
  awk '
    /SIMPLE_MAKE_CAVGS NORMAL STOP/ { active = 1; count = 0; population = 0; next }
    active && /^[[:space:]]*CLASS:/ {
      pop = ""; res = ""
      for (i = 1; i <= NF; i++) {
        if ($i == "POP:" && i < NF) pop = $(i+1)
        if ($i == "RES:" && i < NF) res = $(i+1)
      }
      if (pop ~ /^[0-9]+$/ && res ~ /^[0-9.eE+-]+$/ && res + 0 < 10.0) {
        count++
        population += pop
      }
    }
    END { if (!active) print "NA,NA"; else printf "%d,%d\n", count, population }
  ' "$file"
}

emit_iteration_rows() {
  local file="$1"
  local profile="$2"
  local case_name="$3"
  local rep="$4"
  local stage4_mode="$5"
  [[ -f "$file" ]] || return 0
  awk -v profile="$profile" -v case_name="$case_name" -v rep="$rep" -v stage4_mode="$stage4_mode" '
    function quoted(v) { gsub(/"/, "\"\"", v); return "\"" v "\"" }
    function value(line, key,    n,a,i,prefix,v) {
      n = split(line, a, /[[:space:]]+/)
      prefix = key "="
      for (i = 1; i <= n; i++) {
        if (index(a[i], prefix) == 1) {
          v = substr(a[i], length(prefix) + 1)
          if (v != "") return v
        }
      }
      return "NA"
    }
    /ABINITIO2D SGD STAGE:/ {
      stage = value($0, "stage")
      iteration = "NA"
      stage_iter = "NA"
      policy = value($0, "activation")
      mode = (policy == "off" ? "sgd_off" : "configured")
      print quoted(profile) "," quoted(case_name) "," quoted(rep) "," quoted(stage4_mode) "," quoted(stage) "," quoted(iteration) "," quoted(stage_iter) "," quoted(policy) "," quoted(mode) "," quoted("stage_policy") "," quoted($0)
      next
    }
    /JOINT2D SGD SCHEDULE:/ {
      iteration = value($0, "iteration")
      stage_iter = value($0, "stage_iter")
      policy = value($0, "policy")
      mode = value($0, "mode")
      print quoted(profile) "," quoted(case_name) "," quoted(rep) "," quoted(stage4_mode) "," quoted(stage) "," quoted(iteration) "," quoted(stage_iter) "," quoted(policy) "," quoted(mode) "," quoted("schedule") "," quoted($0)
      next
    }
    /JOINT2D SGD (TOPK|LATENT|WINNER|INPL|SHIFT|BALANCE|REFS|PROFILE)|CAVG SGD (UPDATE|SUPPORT|NORMS|RESTORE)/ {
      marker = ($0 ~ /JOINT2D SGD/ ? "joint_diagnostic" : "cavg_diagnostic")
      print quoted(profile) "," quoted(case_name) "," quoted(rep) "," quoted(stage4_mode) "," quoted(stage) "," quoted(iteration) "," quoted(stage_iter) "," quoted(policy) "," quoted(mode) "," quoted(marker) "," quoted($0)
    }
  ' "$file"
}

first_existing_star() {
  local run_dir="$1"
  [[ -d "$run_dir" ]] || return 1
  find "$run_dir" -type f \( -iname '*cls2D*.star' -o -iname '*class*.star' -o -iname '*.star' \) \
    -size -25M 2>/dev/null | sort | tail -n 1
}

population_metrics() {
  local run_dir="$1"
  local ncls="$2"
  local star_file
  star_file="$(first_existing_star "$run_dir" || true)"
  if [[ -z "$star_file" || ! -f "$star_file" ]]; then
    echo "NA,NA,NA,NA,NA,NA,NA"
    return 0
  fi

  awk -v ncls_in="$ncls" '
    BEGIN {
      class_col = 0
      total = 0
      maxcls = 0
    }
    /^_/ {
      idx = $2
      gsub(/^#/, "", idx)
      if ($1 ~ /(ClassNumber|class|class_id|icls)$/ && idx ~ /^[0-9]+$/) class_col = idx + 0
      next
    }
    class_col > 0 && $0 !~ /^[[:space:]]*(#|data_|loop_|$)/ && NF >= class_col {
      cls = $(class_col)
      gsub(/[^0-9]/, "", cls)
      if (cls ~ /^[0-9]+$/ && cls + 0 > 0) {
        count[cls]++
        total++
        if (cls + 0 > maxcls) maxcls = cls + 0
      }
    }
    END {
      if (total < 1) {
        print "NA,NA,NA,NA,NA,NA," FILENAME
        exit
      }
      K = ncls_in + 0
      if (K < maxcls) K = maxcls
      if (K < 1) K = maxcls
      active = 0
      maxpop = 0
      entropy = 0.0
      for (i = 1; i <= K; i++) {
        c = count[i] + 0
        if (c > 0) {
          active++
          if (c > maxpop) maxpop = c
          p = c / total
          entropy -= p * log(p)
        }
      }
      if (K > 1) norm_entropy = entropy / log(K)
      else norm_entropy = 0.0
      collapse = 1.0 - norm_entropy
      zero = K - active
      printf "%d,%.6f,%.6f,%d,%.6f,%.6f,%s\n", active, active / K, maxpop / total, zero, norm_entropy, collapse, FILENAME
    }' "$star_file"
}

write_header() {
  cat <<'EOF'
case,replicate,profile,mode,stage4_mode,status,execution_seconds,res_lt10_classes,res_lt10_population,project,ncls,mskdiam,nthr,topk,sgd_eta_latent,sgd_eta_cavg,sgd_balance_weight,accepted_frac,empty,accepted,too_few,high_entropy,avg_entropy,entropy_min,entropy_max,avg_norm_entropy,norm_entropy_min,norm_entropy_max,avg_winner_weight,winner_weight_min,winner_weight_max,posterior_multi_candidate,effective_k_p50,effective_k_p90,expected_loss_delta,winner_churn,inpl_changed,shift_step_mean,shift_step_max,cavg_support_min,cavg_support_mean,cavg_support_max,cavg_updated,cavg_preserved,cavg_trust_clipped,cavg_grad_norm,cavg_step_norm,cavg_rel_step_norm,cavg_proposed_rel_step_max,cavg_applied_rel_step_max,cavg_nonfinite,frc_mean_peak,frc_max_peak,frc_usable_classes,profile_provisional_seconds,profile_transport_seconds,profile_softmax_seconds,profile_inplane_seconds,profile_shift_seconds,profile_class_update_seconds,shift_objective_evals,shift_gradient_evals,shift_accepted_steps,active_classes,active_class_fraction,max_population_fraction,zero_population_classes,pop_entropy,collapse_index,population_source,log_file,run_dir
EOF
}

if [[ $# -lt 1 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

root="$1"
manifest="$root/science_runs.tsv"
metrics="$root/science_metrics.csv"
iterations="$root/science_iterations.csv"
summary="$root/science_summary.md"

[[ -f "$manifest" ]] || fail "manifest not found: $manifest"

write_header > "$metrics"
echo 'profile,case,replicate,stage4_mode,stage,iteration,stage_iter,policy,mode,marker,raw' > "$iterations"

tail -n +2 "$manifest" | while IFS=$'\t' read -r case_name rep profile mode stage4_mode log_file run_dir project ncls mskdiam nthr topk eta_latent eta_cavg balance_weight params status; do
  [[ -n "${case_name:-}" ]] || continue
  if [[ ! -f "$log_file" ]]; then
    status="missing_log"
  fi
  emit_iteration_rows "$log_file" "$profile" "$case_name" "$rep" "$stage4_mode" >> "$iterations"

  run_seconds="$(execution_seconds "$log_file")"
  resolution_csv="$(resolution_lt10_metrics "$log_file")"
  IFS=, read -r res_lt10_classes res_lt10_population <<< "$resolution_csv"

  accepted_frac="$(kv_last "$log_file" 'JOINT2D SGD TOPK RANGES:' 'accepted_frac')"
  empty="$(kv_last "$log_file" 'JOINT2D SGD TOPK:' 'empty')"
  accepted="$(kv_last "$log_file" 'JOINT2D SGD TOPK:' 'accepted')"
  too_few="$(kv_last "$log_file" 'JOINT2D SGD TOPK:' 'too_few')"
  high_entropy="$(kv_last "$log_file" 'JOINT2D SGD TOPK:' 'high_entropy')"
  avg_entropy="$(kv_last "$log_file" 'JOINT2D SGD TOPK STATS:' 'avg_entropy')"
  entropy_min="$(kv_last "$log_file" 'JOINT2D SGD TOPK RANGES:' 'entropy_min')"
  entropy_max="$(kv_last "$log_file" 'JOINT2D SGD TOPK RANGES:' 'entropy_max')"
  avg_norm_entropy="$(kv_last "$log_file" 'JOINT2D SGD TOPK STATS:' 'avg_norm_entropy')"
  norm_entropy_min="$(kv_last "$log_file" 'JOINT2D SGD TOPK RANGES:' 'norm_entropy_min')"
  norm_entropy_max="$(kv_last "$log_file" 'JOINT2D SGD TOPK RANGES:' 'norm_entropy_max')"
  avg_winner_weight="$(kv_last "$log_file" 'JOINT2D SGD TOPK STATS:' 'avg_winner_weight')"
  winner_weight_min="$(kv_last "$log_file" 'JOINT2D SGD WINNER:' 'weight_min')"
  winner_weight_max="$(kv_last "$log_file" 'JOINT2D SGD WINNER:' 'weight_max')"
  posterior_multi_candidate="$(kv_last "$log_file" 'JOINT2D SGD POSTERIOR SUPPORT:' 'multi_candidate')"
  effective_k_p50="$(kv_last "$log_file" 'JOINT2D SGD POSTERIOR SUPPORT:' 'effective_k_p50')"
  effective_k_p90="$(kv_last "$log_file" 'JOINT2D SGD POSTERIOR SUPPORT:' 'effective_k_p90')"
  expected_loss_delta="$(kv_last "$log_file" 'JOINT2D SGD LATENT:' 'avg_loss_delta')"
  winner_churn="$(kv_last "$log_file" 'JOINT2D SGD TOPK STATS:' 'winner_churn')"
  inpl_changed="$(kv_last "$log_file" 'JOINT2D SGD INPL:' 'changed')"
  shift_step_mean="$(kv_last "$log_file" 'JOINT2D SGD SHIFT NORMS:' 'step_mean')"
  shift_step_max="$(kv_last "$log_file" 'JOINT2D SGD SHIFT NORMS:' 'step_max')"
  cavg_support_min="$(kv_last "$log_file" 'CAVG SGD SUPPORT:' 'min')"
  cavg_support_mean="$(kv_last "$log_file" 'CAVG SGD SUPPORT:' 'mean')"
  cavg_support_max="$(kv_last "$log_file" 'CAVG SGD SUPPORT:' 'max')"
  cavg_updated="$(kv_last "$log_file" 'CAVG SGD UPDATE:' 'updated')"
  cavg_preserved="$(kv_last "$log_file" 'CAVG SGD UPDATE:' 'preserved')"
  cavg_trust_clipped="$(kv_last "$log_file" 'CAVG SGD UPDATE:' 'trust_clipped')"
  cavg_grad_norm="$(kv_last "$log_file" 'CAVG SGD NORMS:' 'grad')"
  cavg_step_norm="$(kv_last "$log_file" 'CAVG SGD NORMS:' 'step')"
  cavg_rel_step_norm="$(kv_last "$log_file" 'CAVG SGD NORMS:' 'rel_step')"
  cavg_proposed_rel_step_max="$(kv_last "$log_file" 'CAVG SGD TRUST:' 'proposed_rel_step_max')"
  cavg_applied_rel_step_max="$(kv_last "$log_file" 'CAVG SGD TRUST:' 'applied_rel_step_max')"
  cavg_nonfinite="$(kv_last "$log_file" 'CAVG SGD UPDATE:' 'nonfinite')"
  frc_mean_peak="$(kv_last "$log_file" 'CAVG SGD RESTORE FRC:' 'mean_peak')"
  frc_max_peak="$(kv_last "$log_file" 'CAVG SGD RESTORE FRC:' 'max_peak')"
  frc_usable_classes="$(kv_last "$log_file" 'CAVG SGD RESTORE:' 'usable_frc')"
  profile_provisional_seconds="$(profile_sum "$log_file" provisional_scoring seconds)"
  profile_transport_seconds="$(profile_sum "$log_file" candidate_transport seconds)"
  profile_softmax_seconds="$(profile_sum "$log_file" softmax_transport seconds)"
  profile_inplane_seconds="$(profile_sum "$log_file" inplane_refinement seconds)"
  profile_shift_seconds="$(profile_sum "$log_file" shift_refinement seconds)"
  profile_class_update_seconds="$(profile_sum "$log_file" class_update_restoration seconds)"
  shift_objective_evals="$(profile_sum "$log_file" shift_refinement objective_evals)"
  shift_gradient_evals="$(profile_sum "$log_file" shift_refinement gradient_evals)"
  shift_accepted_steps="$(profile_sum "$log_file" shift_refinement accepted_steps)"
  pop_csv="$(population_metrics "$run_dir" "$ncls")"
  IFS=, read -r active_classes active_class_fraction max_population_fraction zero_population_classes \
    pop_entropy collapse_index population_source <<< "$pop_csv"

  emit_csv_row \
    "$case_name" "$rep" "$profile" "$mode" "$stage4_mode" "$status" \
    "$run_seconds" "$res_lt10_classes" "$res_lt10_population" "$project" "$ncls" "$mskdiam" "$nthr" \
    "$topk" "$eta_latent" "$eta_cavg" "$balance_weight" "$accepted_frac" "$empty" \
    "$accepted" "$too_few" "$high_entropy" "$avg_entropy" "$entropy_min" "$entropy_max" \
    "$avg_norm_entropy" "$norm_entropy_min" "$norm_entropy_max" "$avg_winner_weight" \
    "$winner_weight_min" "$winner_weight_max" "$posterior_multi_candidate" "$effective_k_p50" \
    "$effective_k_p90" "$expected_loss_delta" "$winner_churn" \
    "$inpl_changed" "$shift_step_mean" "$shift_step_max" "$cavg_support_min" \
    "$cavg_support_mean" "$cavg_support_max" "$cavg_updated" "$cavg_preserved" "$cavg_trust_clipped" \
    "$cavg_grad_norm" "$cavg_step_norm" "$cavg_rel_step_norm" "$cavg_proposed_rel_step_max" \
    "$cavg_applied_rel_step_max" "$cavg_nonfinite" \
    "$frc_mean_peak" "$frc_max_peak" "$frc_usable_classes" \
    "$profile_provisional_seconds" "$profile_transport_seconds" "$profile_softmax_seconds" \
    "$profile_inplane_seconds" "$profile_shift_seconds" "$profile_class_update_seconds" \
    "$shift_objective_evals" "$shift_gradient_evals" "$shift_accepted_steps" "$active_classes" \
    "$active_class_fraction" "$max_population_fraction" "$zero_population_classes" \
    "$pop_entropy" "$collapse_index" "$population_source" "$log_file" "$run_dir" >> "$metrics"
done

{
  echo "# Joint 2D SGD Scientific Validation Summary"
  echo
  echo "Root: \`$root\`"
  echo
  echo "Generated files:"
  echo
  echo "- \`science_runs.tsv\`"
  if [[ -f "$root/science_checkpoints.tsv" ]]; then
    echo "- \`science_checkpoints.tsv\`"
  fi
  echo "- \`science_metrics.csv\`"
  echo "- \`science_iterations.csv\`"
  echo "- \`science_summary.md\`"
  echo
  echo "## Cases"
  echo
  awk -F, 'NR > 1 { gsub(/"/, "", $1); gsub(/"/, "", $2); gsub(/"/, "", $3); gsub(/"/, "", $6); print "- " $1 " replicate " $2 " (" $3 "): " $6 }' "$metrics"
  echo
  echo "## Baseline vs Joint Highlights"
  echo
  awk -F, '
    NR == 1 {
      for (i = 1; i <= NF; i++) h[$i] = i
      next
    }
    {
      gsub(/"/, "", $1)
      gsub(/"/, "", $2)
      printf "- %s rep %s: accepted_frac=%s, entropy=%s, winner_weight=%s, frc_mean_peak=%s, active_classes=%s, collapse_index=%s\n", \
        $1, $2, $(h["accepted_frac"]), $(h["avg_norm_entropy"]), $(h["avg_winner_weight"]), \
        $(h["frc_mean_peak"]), $(h["active_classes"]), $(h["collapse_index"])
    }' "$metrics"
  echo
  echo "## Shift-Selection Replicate Means"
  echo
  awk -F, '
    function numeric(v) { return v != "NA" && v ~ /^[-+0-9.eE]+$/ }
    NR == 1 {
      for (i = 1; i <= NF; i++) { gsub(/"/, "", $i); h[$i] = i }
      order[1] = "checkpoint_baseline"
      order[2] = "balance_raw_likelihood"
      order[3] = "raw_likelihood_topk1"
      next
    }
    {
      for (i = 1; i <= NF; i++) gsub(/"/, "", $i)
      if ($(h["profile"]) != "shift_selection") next
      c = $(h["case"])
      runs[c]++
      if ($(h["status"]) == "pass") passed[c]++
      if (numeric($(h["execution_seconds"]))) { runtime[c] += $(h["execution_seconds"]); runtime_n[c]++ }
      if (numeric($(h["res_lt10_classes"]))) { res_count[c] += $(h["res_lt10_classes"]); res_count_n[c]++ }
      if (numeric($(h["res_lt10_population"]))) { res_pop[c] += $(h["res_lt10_population"]); res_pop_n[c]++ }
      if (numeric($(h["active_classes"]))) { active[c] += $(h["active_classes"]); active_n[c]++ }
      if (numeric($(h["collapse_index"]))) { collapse[c] += $(h["collapse_index"]); collapse_n[c]++ }
      found = 1
    }
    END {
      if (!found) { print "- Not a shift-selection result set."; exit }
      for (j = 1; j <= 3; j++) {
        c = order[j]
        rt = (runtime_n[c] ? sprintf("%.2f", runtime[c] / runtime_n[c]) : "NA")
        rc = (res_count_n[c] ? sprintf("%.2f", res_count[c] / res_count_n[c]) : "NA")
        rp = (res_pop_n[c] ? sprintf("%.2f", res_pop[c] / res_pop_n[c]) : "NA")
        ac = (active_n[c] ? sprintf("%.2f", active[c] / active_n[c]) : "NA")
        ci = (collapse_n[c] ? sprintf("%.4f", collapse[c] / collapse_n[c]) : "NA")
        printf "- %s: pass=%d/%d, mean continuation=%ss, mean RES<10 classes=%s, mean RES<10 population=%s, mean active classes=%s, mean collapse index=%s\n", \
          c, passed[c] + 0, runs[c] + 0, rt, rc, rp, ac, ci
      }
    }' "$metrics"
  echo
  echo "## Shift-Selection Paired Deltas"
  echo
  awk -F, '
    function numeric(v) { return v != "NA" && v ~ /^[-+0-9.eE]+$/ }
    NR == 1 {
      for (i = 1; i <= NF; i++) { gsub(/"/, "", $i); h[$i] = i }
      cases[1] = "balance_raw_likelihood"
      cases[2] = "raw_likelihood_topk1"
      next
    }
    {
      for (i = 1; i <= NF; i++) gsub(/"/, "", $i)
      if ($(h["profile"]) != "shift_selection") next
      r = $(h["replicate"]); c = $(h["case"])
      if (r + 0 > maxrep) maxrep = r + 0
      runtime[r,c] = $(h["execution_seconds"])
      res_count[r,c] = $(h["res_lt10_classes"])
      res_pop[r,c] = $(h["res_lt10_population"])
      status[r,c] = $(h["status"])
      found = 1
    }
    END {
      if (!found) { print "- Not a shift-selection result set."; exit }
      for (r = 1; r <= maxrep; r++) {
        for (j = 1; j <= 2; j++) {
          c = cases[j]
          dt = (numeric(runtime[r,c]) && numeric(runtime[r,"checkpoint_baseline"]) ? sprintf("%+.2f", runtime[r,c] - runtime[r,"checkpoint_baseline"]) : "NA")
          dc = (numeric(res_count[r,c]) && numeric(res_count[r,"checkpoint_baseline"]) ? sprintf("%+.0f", res_count[r,c] - res_count[r,"checkpoint_baseline"]) : "NA")
          dp = (numeric(res_pop[r,c]) && numeric(res_pop[r,"checkpoint_baseline"]) ? sprintf("%+.0f", res_pop[r,c] - res_pop[r,"checkpoint_baseline"]) : "NA")
          printf "- rep %d %s vs checkpoint_baseline: status=%s, continuation delta=%ss, RES<10 class delta=%s, RES<10 population delta=%s\n", \
            r, c, status[r,c], dt, dc, dp
        }
      }
    }' "$metrics"
  echo
  echo "## Joint Component Profile"
  echo
  awk -F, '
    NR == 1 { for (i = 1; i <= NF; i++) { gsub(/"/, "", $i); h[$i] = i }; next }
    {
      for (i = 1; i <= NF; i++) gsub(/"/, "", $i)
      printf "- %s rep %s: score=%ss, transport=%ss, SoftMax=%ss, in-plane=%ss, shift=%ss, class-update=%ss, shift-objective-evals=%s, shift-gradient-evals=%s, shift-accepted-steps=%s\n", \
        $(h["case"]), $(h["replicate"]), $(h["profile_provisional_seconds"]), \
        $(h["profile_transport_seconds"]), $(h["profile_softmax_seconds"]), \
        $(h["profile_inplane_seconds"]), $(h["profile_shift_seconds"]), \
        $(h["profile_class_update_seconds"]), $(h["shift_objective_evals"]), \
        $(h["shift_gradient_evals"]), $(h["shift_accepted_steps"])
    }' "$metrics"
  echo
  echo "## Review Flags"
  echo
  awk -F, '
    NR == 1 { for (i = 1; i <= NF; i++) { gsub(/"/, "", $i); h[$i] = i }; next }
    {
      for (i = 1; i <= NF; i++) gsub(/"/, "", $i)
      flagged = 0
      if ($(h["status"]) != "pass") { print "- " $(h["case"]) " rep " $(h["replicate"]) ": status=" $(h["status"]); flagged = 1 }
      if ($(h["cavg_nonfinite"]) != "NA" && $(h["cavg_nonfinite"]) + 0 > 0) { print "- " $(h["case"]) ": nonfinite CAVG updates"; flagged = 1 }
      if ($(h["active_class_fraction"]) != "NA" && $(h["active_class_fraction"]) + 0 < 0.5) { print "- " $(h["case"]) ": active class fraction below 0.5"; flagged = 1 }
      if ($(h["collapse_index"]) != "NA" && $(h["collapse_index"]) + 0 > 0.5) { print "- " $(h["case"]) ": collapse index above 0.5"; flagged = 1 }
      any += flagged
    }
    END { if (any == 0) print "- No automatic failure or collapse flags were triggered." }
  ' "$metrics"
  echo
  echo "## Notes"
  echo
  echo "- Baseline runs intentionally have joint2D-SGD metric fields as \`NA\`."
  echo "- Population metrics are extracted from text STAR-like exports when available; otherwise they are \`NA\`."
  echo "- FRC peak metrics come from joint restoration diagnostics. If a baseline text FRC export is unavailable, baseline FRC fields remain \`NA\`."
  echo "- Shift-selection execution time is the stage-4-and-later continuation only; every trio shares its replicate's stage-3 checkpoint cost."
  echo "- This report flags evidence for review; it does not claim scientific superiority automatically."
  echo "- Per-stage and per-iteration schedule/diagnostic records are retained in \`science_iterations.csv\`; run-level metrics remain compact summaries."
} > "$summary"

echo "Wrote $metrics"
echo "Wrote $iterations"
echo "Wrote $summary"
