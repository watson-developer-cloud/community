#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="cpd-instance-1"
INTERVAL_MINUTES=2
DEPLOYMENT_ARGUMENT=""
CUSTOM_PATTERN=""
RUN_ONCE=false
EXCLUSIONS=()
SCAN_ERRORS_FOUND=0
PROMPT_INPUT=""

ERROR_PATTERN='(^|[^[:alnum:]_])(error|err|fatal|panic|exception|traceback|segmentation fault|oomkilled|crashloopbackoff|failed)([^[:alnum:]_]|$)'
NON_ERROR_LEVEL_PATTERN='(^|[^[:alnum:]_])(info|debug|trace)([^[:alnum:]_]|$)|"level"[[:space:]]*:[[:space:]]*"(INFO|DEBUG|TRACE)"'
EMPTY_ERROR_FIELD_PATTERN='"(error|err)"[[:space:]]*:[[:space:]]*(""|null|\{\}|\[\])[[:space:]]*[,}]'

usage() {
  cat <<'EOF'
Monitor logs and health for selected watsonx Orchestrate deployments.

Usage:
  wxo-deployments-script-monitor-errors-vall.sh [options]

Options:
  -n, --namespace NAME       Operand namespace (default: cpd-instance-1)
  -i, --interval MINUTES    Minutes between scans (default: 2)
  -d, --deployments VALUE   Comma-separated deployment names or "all"
  -g, --grep REGEX          Also show log lines matching this case-insensitive regex
      --once                Scan once and exit
  -h, --help                Show this help

If --deployments is omitted, the script displays WXO-owned deployments and
prompts for comma-separated numbers, deployment names, or "all".

Examples:
  ./scripts/wxo-deployments-script-monitor-errors-vall.sh
  ./scripts/wxo-deployments-script-monitor-errors-vall.sh -d all -i 5
  ./scripts/wxo-deployments-script-monitor-errors-vall.sh -d wo-api-server-runs,wo-archer-server --once
  ./scripts/wxo-deployments-script-monitor-errors-vall.sh -d all -g 'request-id-123|timeout'
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf '⚠️  %s\n' "$*" >&2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      NAMESPACE="$2"
      shift 2
      ;;
    -i|--interval)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      INTERVAL_MINUTES="$2"
      shift 2
      ;;
    -d|--deployments)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      DEPLOYMENT_ARGUMENT="$2"
      shift 2
      ;;
    -g|--grep)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      CUSTOM_PATTERN="$2"
      shift 2
      ;;
    --once)
      RUN_ONCE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ "$INTERVAL_MINUTES" =~ ^[1-9][0-9]*$ ]] || die "Interval must be a positive whole number of minutes"
INTERVAL_SECONDS=$((INTERVAL_MINUTES * 60))
LOOKBACK_SECONDS=0
LAST_SCAN_START=0

require_command oc
require_command jq
oc whoami >/dev/null 2>&1 || die "Not logged in to an OpenShift cluster"
oc get namespace "$NAMESPACE" >/dev/null 2>&1 || die "Namespace not found or not accessible: $NAMESPACE"

# When invoked as `curl ... | bash`, stdin contains the script. Read interactive
# answers directly from the controlling terminal instead.
if [[ -r /dev/tty && -w /dev/tty ]]; then
  PROMPT_INPUT="/dev/tty"
elif [[ -t 0 ]]; then
  PROMPT_INPUT="/dev/stdin"
fi

if [[ -n "$CUSTOM_PATTERN" ]]; then
  set +e
  printf '' | grep -Ei -- "$CUSTOM_PATTERN" >/dev/null 2>&1
  grep_rc=$?
  set -e
  [[ $grep_rc -ne 2 ]] || die "Invalid --grep regular expression: $CUSTOM_PATTERN"
fi

discover_deployments() {
  oc get deployments -n "$NAMESPACE" -o json | jq -r '
    .items[]
    | select(
        (.metadata.name | startswith("wo-"))
        or (.metadata.labels["icpdsupport/addOnId"] == "orchestrate")
        or (.metadata.labels["wo.watsonx.ibm.com/application"] == "watson-orchestrate")
        or (.metadata.labels["app.kubernetes.io/managed-by"] == "ibm-watson-orchestrate-operator")
      )
    | .metadata.name
  ' | sort -u
}

DISCOVERED_FILE=$(mktemp "${TMPDIR:-/tmp}/wxo-deployments.XXXXXX")
LOG_FILE=$(mktemp "${TMPDIR:-/tmp}/wxo-pod-log.XXXXXX")
MATCH_FILE=$(mktemp "${TMPDIR:-/tmp}/wxo-log-match.XXXXXX")
ERROR_MATCH_FILE=$(mktemp "${TMPDIR:-/tmp}/wxo-error-match.XXXXXX")
FILTER_FILE=$(mktemp "${TMPDIR:-/tmp}/wxo-filtered-match.XXXXXX")
trap 'rm -f "$DISCOVERED_FILE" "$LOG_FILE" "$MATCH_FILE" "$ERROR_MATCH_FILE" "$FILTER_FILE"' EXIT INT TERM

discover_deployments > "$DISCOVERED_FILE"
[[ -s "$DISCOVERED_FILE" ]] || die "No WXO-owned deployments found in namespace $NAMESPACE"

discovered=()
while IFS= read -r deployment; do
  [[ -n "$deployment" ]] && discovered+=("$deployment")
done < "$DISCOVERED_FILE"

deployment_exists() {
  local wanted="$1"
  local candidate
  for candidate in "${discovered[@]}"; do
    [[ "$candidate" == "$wanted" ]] && return 0
  done
  return 1
}

validate_custom_pattern() {
  local pattern="$1"
  local grep_rc
  set +e
  printf '' | grep -Ei -- "$pattern" >/dev/null 2>&1
  grep_rc=$?
  set -e
  [[ $grep_rc -ne 2 ]]
}

prompt_for_custom_pattern() {
  local entered_pattern=""
  [[ -z "$CUSTOM_PATTERN" ]] || return 0
  [[ -n "$PROMPT_INPUT" ]] || return 0

  printf 'Optionally enter specific text/regex to find in addition to errors (continuing in 20 seconds): '
  if IFS= read -r -t 20 entered_pattern < "$PROMPT_INPUT"; then
    if [[ -z "$entered_pattern" ]]; then
      printf 'No additional search text entered; scanning errors only.\n'
    elif validate_custom_pattern "$entered_pattern"; then
      CUSTOM_PATTERN="$entered_pattern"
      printf '✅ Added startup search pattern: %s\n' "$CUSTOM_PATTERN"
    else
      warn "Invalid search regular expression; ignoring it: $entered_pattern"
    fi
  else
    printf '\nNo additional search text entered within 20 seconds; scanning errors only.\n'
  fi
}

selected=()
select_all() {
  selected=("${discovered[@]}")
}

if [[ -z "$DEPLOYMENT_ARGUMENT" ]]; then
  [[ -n "$PROMPT_INPUT" ]] || die "Interactive selection requires a terminal; use --deployments all or provide deployment names"
  printf 'WXO-owned deployments in namespace %s:\n' "$NAMESPACE"
  for index in "${!discovered[@]}"; do
    printf '  %2d) %s\n' "$((index + 1))" "${discovered[$index]}"
  done
  printf '   a) all\n'
  printf 'Select comma-separated numbers/names or all: '
  IFS= read -r DEPLOYMENT_ARGUMENT < "$PROMPT_INPUT"
fi

deployment_argument_lower=$(printf '%s' "$DEPLOYMENT_ARGUMENT" | tr '[:upper:]' '[:lower:]')
if [[ "$deployment_argument_lower" == "all" || "$deployment_argument_lower" == "a" ]]; then
  select_all
else
  normalized=${DEPLOYMENT_ARGUMENT//,/ }
  for choice in $normalized; do
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
      (( choice >= 1 && choice <= ${#discovered[@]} )) || die "Selection number out of range: $choice"
      deployment="${discovered[$((choice - 1))]}"
    else
      deployment="$choice"
      deployment_exists "$deployment" || die "Not a discovered WXO deployment: $deployment"
    fi
    already_selected=false
    for existing in "${selected[@]:-}"; do
      [[ "$existing" == "$deployment" ]] && already_selected=true
    done
    $already_selected || selected+=("$deployment")
  done
fi

[[ ${#selected[@]} -gt 0 ]] || die "No deployments selected"
prompt_for_custom_pattern

deployment_selector() {
  oc get deployment "$1" -n "$NAMESPACE" -o json | jq -r '
    .spec.selector.matchLabels // {}
    | to_entries
    | map("\(.key)=\(.value)")
    | join(",")
  '
}

apply_exclusions_to_file() {
  local target_file="$1"
  local exclusion
  for exclusion in "${EXCLUSIONS[@]:-}"; do
    [[ -n "$exclusion" ]] || continue
    grep -Fiv -- "$exclusion" "$target_file" > "$FILTER_FILE" 2>/dev/null || true
    cp "$FILTER_FILE" "$target_file"
  done
}

print_filtered_logs() {
  local pod="$1"
  local container="$2"
  local source_label="$3"
  local log_time_args=()
  shift 3

  : > "$LOG_FILE"
  if (( LOOKBACK_SECONDS > 0 )); then
    log_time_args=(--since="${LOOKBACK_SECONDS}s")
  fi
  if ! oc logs -n "$NAMESPACE" "$pod" -c "$container" --timestamps "${log_time_args[@]}" "$@" >"$LOG_FILE" 2>/dev/null; then
    return 0
  fi

  : > "$MATCH_FILE"
  : > "$ERROR_MATCH_FILE"

  # Default behavior: show error-like lines, but never routine informational
  # levels or empty JSON error fields.
  grep -Ein -- "$ERROR_PATTERN" "$LOG_FILE" 2>/dev/null \
    | grep -Eiv -- "$NON_ERROR_LEVEL_PATTERN" \
    | grep -Eiv -- "$EMPTY_ERROR_FIELD_PATTERN" \
    >> "$ERROR_MATCH_FILE" || true
  apply_exclusions_to_file "$ERROR_MATCH_FILE"
  if [[ -s "$ERROR_MATCH_FILE" ]]; then
    SCAN_ERRORS_FOUND=1
    cp "$ERROR_MATCH_FILE" "$MATCH_FILE"
  fi

  # An explicit custom pattern is intentional and may include INFO lines.
  if [[ -n "$CUSTOM_PATTERN" ]]; then
    grep -Ein -- "$CUSTOM_PATTERN" "$LOG_FILE" >> "$MATCH_FILE" 2>/dev/null || true
  fi
  apply_exclusions_to_file "$MATCH_FILE"

  if [[ -s "$MATCH_FILE" ]]; then
    LC_ALL=C sort -t: -k1,1n -u "$MATCH_FILE" -o "$MATCH_FILE"
    printf '    [%s/%s]\n' "$container" "$source_label"
    sed 's/^/      /' "$MATCH_FILE"
    return 1
  fi
  return 0
}

check_pod() {
  local deployment="$1"
  local pod="$2"
  local pod_json phase ready_summary reason
  local found=0

  pod_json=$(oc get pod "$pod" -n "$NAMESPACE" -o json)
  phase=$(jq -r '.status.phase // "Unknown"' <<<"$pod_json")
  ready_summary=$(jq -r '
    . as $pod
    | [$pod.status.containerStatuses[]? | select(.ready == true)] | length as $ready
    | [$pod.status.containerStatuses[]?] | length as $total
    | "\($ready)/\($total)"
  ' <<<"$pod_json")
  reason=$(jq -r '
    [.status.containerStatuses[]?, .status.initContainerStatuses[]?
     | (.state.waiting.reason // .state.terminated.reason // empty)
     | select(. != "Completed")]
    | unique
    | join(",")
  ' <<<"$pod_json")

  if [[ "$phase" != "Running" || "$ready_summary" == 0/* || -n "$reason" ]]; then
    printf '  ❌ pod/%s phase=%s ready=%s%s\n' "$pod" "$phase" "$ready_summary" "${reason:+ reason=$reason}"
    found=1
  fi

  containers=()
  while IFS= read -r container; do
    [[ -n "$container" ]] && containers+=("$container")
  done < <(jq -r '.spec.initContainers[]?.name, .spec.containers[]?.name' <<<"$pod_json")

  for container in "${containers[@]}"; do
    if ! print_filtered_logs "$pod" "$container" "current"; then
      found=1
    fi

    restart_count=$(jq -r --arg name "$container" '
      ([.status.initContainerStatuses[]?, .status.containerStatuses[]?]
       | map(select(.name == $name))[0].restartCount) // 0
    ' <<<"$pod_json")
    if (( restart_count > 0 )); then
      if ! print_filtered_logs "$pod" "$container" "previous after ${restart_count} restart(s)" --previous; then
        found=1
      fi
    fi
  done

  return "$found"
}

scan() {
  local timestamp deployment selector desired ready available pod
  local scan_found=0
  SCAN_ERRORS_FOUND=0
  timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  if (( LOOKBACK_SECONDS == 0 )); then
    printf '\n=== WXO error scan %s | namespace=%s | log-window=all-available-logs ===\n' "$timestamp" "$NAMESPACE"
  else
    printf '\n=== WXO error scan %s | namespace=%s | log-window=%ss ===\n' "$timestamp" "$NAMESPACE" "$LOOKBACK_SECONDS"
  fi

  for deployment in "${selected[@]}"; do
    desired=$(oc get deployment "$deployment" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || printf '?')
    ready=$(oc get deployment "$deployment" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || printf '0')
    available=$(oc get deployment "$deployment" -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || printf '0')
    ready=${ready:-0}
    available=${available:-0}
    printf '\n-- deployment/%s ready=%s/%s available=%s --\n' "$deployment" "$ready" "$desired" "$available"
    if [[ "$ready" != "$desired" || "$available" != "$desired" ]]; then
      printf '  ❌ deployment is not fully available\n'
      scan_found=1
    fi

    selector=$(deployment_selector "$deployment")
    if [[ -z "$selector" ]]; then
      warn "deployment/$deployment has no matchLabels selector; skipping pod logs"
      scan_found=1
      continue
    fi

    pods=()
    while IFS= read -r pod; do
      [[ -n "$pod" ]] && pods+=("$pod")
    done < <(
      oc get pods -n "$NAMESPACE" -l "$selector" -o json \
        | jq -r '.items[] | select(.status.phase != "Succeeded") | .metadata.name' \
        | sort
    )
    if [[ ${#pods[@]} -eq 0 ]]; then
      printf '  ⏭️  no active pods found; Completed pods are ignored\n'
      continue
    fi

    deployment_found=0
    for pod in "${pods[@]}"; do
      if ! check_pod "$deployment" "$pod"; then
        deployment_found=1
        scan_found=1
      fi
    done
    if [[ $deployment_found -eq 0 ]]; then
      if [[ -n "$CUSTOM_PATTERN" ]]; then
        printf '  ✅ no matching errors or custom text found\n'
      else
        printf '  ✅ no matching errors found\n'
      fi
    fi
  done

  if [[ $scan_found -eq 0 ]]; then
    if [[ -n "$CUSTOM_PATTERN" ]]; then
      printf '\n✅ Scan complete: no matching errors or custom text found in selected deployments\n'
    else
      printf '\n✅ Scan complete: no matching errors found in selected deployments\n'
    fi
  else
    if [[ -n "$CUSTOM_PATTERN" ]]; then
      printf '\n⚠️  Scan complete: matching log lines or unhealthy workloads were found\n'
    else
      printf '\n⚠️  Scan complete: matching errors or unhealthy workloads were found\n'
    fi
  fi
}

prompt_for_exclusion() {
  local answer=""
  local exclusion=""
  [[ $SCAN_ERRORS_FOUND -eq 1 ]] || return 0
  $RUN_ONCE && return 0
  [[ -n "$PROMPT_INPUT" ]] || return 0

  printf '\nErrors were found. Add exclusion text for future scans? [y/N] (continuing in 10 seconds): '
  if ! IFS= read -r -t 10 answer < "$PROMPT_INPUT"; then
    printf '\nNo response within 10 seconds; no exclusion added.\n'
    return 0
  fi

  case "$answer" in
    y|Y|yes|YES|Yes)
      while [[ -z "$exclusion" ]]; do
        printf 'Enter non-empty text to exclude (waiting for input): '
        IFS= read -r exclusion < "$PROMPT_INPUT"
        [[ -n "$exclusion" ]] || printf 'Exclusion text cannot be empty.\n'
      done
      EXCLUSIONS+=("$exclusion")
      printf '✅ Added literal exclusion for subsequent scans: %s\n' "$exclusion"
      printf 'Active exclusions: %s\n' "${EXCLUSIONS[*]}"
      ;;
    *)
      printf 'No exclusion added; continuing.\n'
      ;;
  esac
}

printf 'Selected %d deployment(s): %s\n' "${#selected[@]}" "${selected[*]}"
printf 'Log filter: errors%s\n' "${CUSTOM_PATTERN:+ plus /$CUSTOM_PATTERN/}"
if $RUN_ONCE; then
  printf 'Schedule: one scan\n'
else
  printf 'Schedule: every %s minute(s); press Ctrl+C to stop\n' "$INTERVAL_MINUTES"
fi

while true; do
  scan_start=$(date +%s)
  if (( LAST_SCAN_START > 0 )); then
    # Add one second at the boundary so timestamp rounding cannot hide a line.
    LOOKBACK_SECONDS=$((scan_start - LAST_SCAN_START + 1))
  fi
  LAST_SCAN_START=$scan_start
  scan
  scan_end=$(date +%s)
  scan_duration=$((scan_end - scan_start))
  printf '⏱️  Scan duration: %s second(s).\n' "$scan_duration"
  prompt_for_exclusion
  $RUN_ONCE && break
  printf '⏳ Waiting %s minute(s) before the next scan. Press Ctrl+C to stop.\n' "$INTERVAL_MINUTES"
  sleep "$INTERVAL_SECONDS"
done
