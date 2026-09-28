#!/usr/bin/env bash

set -euo pipefail

# Version applicability: verified against WXO 5.3.4 with the EDB PostgreSQL 15
# operator layout. Other WXO 5.x versions are expected to work but are not yet
# verified; rename this artifact if version-specific behavior is discovered.

NAMESPACE="cpd-instance-1"
CLUSTER_NAME=""
POD_NAME=""
DATABASE="postgres"
SINCE="1h"
BLOCKED_SECONDS=300
SKIP_LOGS=false
TERMINATE_BLOCKERS=false
TEMP_LOG=""

usage() {
  cat <<'EOF'
Check the WXO EDB PostgreSQL cluster for deadlocks and lock waits.

Usage:
  wxo-postgres-script-check-deadlocks-vall.sh [options]

Options:
  -n, --namespace NAME       WXO operand namespace (default: cpd-instance-1)
  -c, --cluster NAME         EDB cluster name (auto-discovered by default)
  -p, --pod NAME             Primary PostgreSQL pod (bypasses discovery)
  -d, --database NAME        Database used for psql (default: postgres)
  -s, --since DURATION       PostgreSQL log lookback (default: 1h)
      --blocked-seconds N    Minimum lock-wait age (default: 300 seconds)
      --terminate-blockers   Terminate qualifying blockers without prompting
      --skip-logs            Do not search PostgreSQL logs
  -h, --help                 Show this help

Checks are read-only unless termination is explicitly approved at the prompt or
--terminate-blockers is supplied. The script does not retrieve database
passwords; it executes psql as the postgres role inside the EDB primary pod.

In an interactive terminal, the script asks whether to terminate blockers when
qualifying waits are found. The default answer is no. Non-interactive runs do
not terminate blockers unless --terminate-blockers is explicitly supplied.

Examples:
  ./scripts/wxo-postgres-script-check-deadlocks-vall.sh
  ./scripts/wxo-postgres-script-check-deadlocks-vall.sh -n my-cpd-instance -s 24h
  ./scripts/wxo-postgres-script-check-deadlocks-vall.sh --blocked-seconds 30
  ./scripts/wxo-postgres-script-check-deadlocks-vall.sh --blocked-seconds 60 --terminate-blockers

Exit codes:
  0  No current qualifying lock waits and no recent deadlock log entries
  1  Current lock waits or recent deadlock log entries found
  2  Usage, discovery, connection, or query error

Note: pg_stat_database.deadlocks is cumulative since the statistics reset. A
nonzero historical counter is reported but does not by itself cause exit 1.

WARNING: --terminate-blockers calls pg_terminate_backend() for client sessions
blocking qualifying waits. PostgreSQL rolls back their open transactions, and
applications may report errors or retry work. Internal PostgreSQL workers and
the checker session are never targeted.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

cleanup() {
  [[ -z "$TEMP_LOG" ]] || rm -f "$TEMP_LOG"
}
trap cleanup EXIT INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      NAMESPACE="$2"
      shift 2
      ;;
    -c|--cluster)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      CLUSTER_NAME="$2"
      shift 2
      ;;
    -p|--pod)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      POD_NAME="$2"
      shift 2
      ;;
    -d|--database)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      DATABASE="$2"
      shift 2
      ;;
    -s|--since)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      SINCE="$2"
      shift 2
      ;;
    --blocked-seconds)
      [[ $# -ge 2 ]] || die "$1 requires a value"
      BLOCKED_SECONDS="$2"
      shift 2
      ;;
    --terminate-blockers)
      TERMINATE_BLOCKERS=true
      shift
      ;;
    --skip-logs)
      SKIP_LOGS=true
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

[[ "$BLOCKED_SECONDS" =~ ^[0-9]+$ ]] || die "--blocked-seconds must be a non-negative whole number"
[[ "$SINCE" =~ ^[1-9][0-9]*(s|m|h)$ ]] || die "--since must use a positive duration such as 30m, 1h, or 24h"
if $TERMINATE_BLOCKERS && [[ "$BLOCKED_SECONDS" -eq 0 ]]; then
  die "--terminate-blockers requires an explicit --blocked-seconds value greater than 0"
fi

require_command oc
oc whoami >/dev/null 2>&1 || die "Not logged in to an OpenShift cluster"
oc get namespace "$NAMESPACE" >/dev/null 2>&1 || die "Namespace not found or not accessible: $NAMESPACE"

discover_primary_pod() {
  local selector
  local pods

  if [[ -n "$CLUSTER_NAME" ]]; then
    selector="k8s.enterprisedb.io/cluster=${CLUSTER_NAME},role=primary"
  else
    selector="wo.watsonx.ibm.com/component=postgresedb,role=primary"
  fi

  pods=$(oc get pods -n "$NAMESPACE" \
    --field-selector=status.phase=Running \
    -l "$selector" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || return 1

  if [[ -z "$pods" ]]; then
    die "No running WXO PostgreSQL primary pod found with selector: $selector"
  fi
  if [[ $(printf '%s\n' "$pods" | sed '/^$/d' | wc -l | tr -d ' ') -ne 1 ]]; then
    printf 'Matching primary pods:\n%s\n' "$pods" >&2
    die "Expected exactly one primary pod; use --cluster or --pod to select one"
  fi
  printf '%s\n' "$pods"
}

if [[ -z "$POD_NAME" ]]; then
  POD_NAME=$(discover_primary_pod) || die "Failed to discover the PostgreSQL primary pod"
else
  oc get pod "$POD_NAME" -n "$NAMESPACE" >/dev/null 2>&1 || \
    die "Pod not found or not accessible: $POD_NAME"
fi

psql_exec() {
  oc exec -n "$NAMESPACE" "$POD_NAME" -c postgres -- \
    psql -X -v ON_ERROR_STOP=1 -U postgres -d "$DATABASE" "$@"
}

identity=$(psql_exec -Atqc \
  "SELECT current_database() || '|' || current_user || '|' || pg_is_in_recovery();") || \
  die "Could not connect to PostgreSQL in pod $POD_NAME"

IFS='|' read -r connected_database connected_user is_replica <<< "$identity"
[[ "$is_replica" == "f" || "$is_replica" == "false" ]] || \
  die "Selected pod is a replica, not the primary: $POD_NAME"

printf 'WXO PostgreSQL deadlock check\n'
printf '  Namespace: %s\n' "$NAMESPACE"
printf '  Primary pod: %s\n' "$POD_NAME"
printf '  Database/user: %s / %s\n' "$connected_database" "$connected_user"
printf '  Checked at: %s\n\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

printf 'Cumulative deadlocks by database (since each statistics reset)\n'
psql_exec -P pager=off -P null='-' -c "
SELECT datname AS database,
       deadlocks,
       stats_reset
FROM pg_stat_database
WHERE datname IS NOT NULL
ORDER BY deadlocks DESC, datname;
" || die "Failed to query pg_stat_database"

printf '\nCurrent lock waits (minimum age: %s seconds)\n' "$BLOCKED_SECONDS"
wait_count=$(psql_exec -Atqc "
SELECT count(*)
FROM pg_stat_activity AS blocked
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0
  AND clock_timestamp() - COALESCE(blocked.query_start, blocked.xact_start, blocked.backend_start)
      >= make_interval(secs => ${BLOCKED_SECONDS});
") || die "Failed to count blocked sessions"

if [[ "$wait_count" -eq 0 ]]; then
  printf 'No qualifying blocked sessions found.\n'
else
  psql_exec -P pager=off -P null='-' -c "
SELECT blocked.datname AS database,
       blocked.pid AS blocked_pid,
       blocked.usename AS blocked_user,
       blocker.pid AS blocker_pid,
       blocker.usename AS blocker_user,
       age(clock_timestamp(), COALESCE(blocked.query_start, blocked.xact_start, blocked.backend_start))
         AS wait_age,
       blocked.wait_event_type,
       blocked.wait_event,
       left(regexp_replace(blocked.query, E'[\\n\\r\\t]+', ' ', 'g'), 120) AS blocked_query,
       left(regexp_replace(blocker.query, E'[\\n\\r\\t]+', ' ', 'g'), 120) AS blocker_query
FROM pg_stat_activity AS blocked
CROSS JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS blocking(blocker_pid)
JOIN pg_stat_activity AS blocker ON blocker.pid = blocking.blocker_pid
WHERE clock_timestamp() - COALESCE(blocked.query_start, blocked.xact_start, blocked.backend_start)
      >= make_interval(secs => ${BLOCKED_SECONDS})
ORDER BY wait_age DESC, blocked.pid, blocker.pid;
" || die "Failed to query current lock waits"
fi

remaining_wait_count="$wait_count"
if [[ "$wait_count" -gt 0 && "$BLOCKED_SECONDS" -eq 0 ]] && ! $TERMINATE_BLOCKERS; then
  printf '\nTermination prompt disabled because --blocked-seconds is 0; use a positive threshold.\n'
elif [[ "$wait_count" -gt 0 ]] && ! $TERMINATE_BLOCKERS; then
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    printf '\nTerminate these blocker sessions? [y/N] ' > /dev/tty
    IFS= read -r terminate_answer < /dev/tty || terminate_answer=""
    case "$terminate_answer" in
      y|Y|yes|YES|Yes)
        TERMINATE_BLOCKERS=true
        ;;
      *)
        printf 'Blocker sessions were not terminated.\n'
        ;;
    esac
  else
    printf '\nNon-interactive run: blocker sessions were not terminated.\n'
  fi
fi

if $TERMINATE_BLOCKERS; then
  printf '\nBlocker termination\n'
  if [[ "$wait_count" -eq 0 ]]; then
    printf 'No qualifying blocker sessions to terminate.\n'
  else
    psql_exec -P pager=off -P null='-' -c "
WITH blocker_pids AS (
  SELECT DISTINCT unnest(pg_blocking_pids(blocked.pid)) AS pid
  FROM pg_stat_activity AS blocked
  WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0
    AND clock_timestamp() - COALESCE(blocked.query_start, blocked.xact_start, blocked.backend_start)
        >= make_interval(secs => ${BLOCKED_SECONDS})
),
targets AS (
  SELECT activity.pid,
         activity.datname,
         activity.usename,
         left(regexp_replace(activity.query, E'[\\n\\r\\t]+', ' ', 'g'), 120) AS query
  FROM blocker_pids
  JOIN pg_stat_activity AS activity USING (pid)
  WHERE activity.backend_type = 'client backend'
    AND activity.pid <> pg_backend_pid()
)
SELECT pid,
       datname AS database,
       usename,
       query,
       pg_terminate_backend(pid) AS terminated
FROM targets
ORDER BY pid;
" || die "Failed while terminating blocker sessions"

    remaining_wait_count=$(psql_exec -Atqc "
SELECT count(*)
FROM pg_stat_activity AS blocked
WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0
  AND clock_timestamp() - COALESCE(blocked.query_start, blocked.xact_start, blocked.backend_start)
      >= make_interval(secs => ${BLOCKED_SECONDS});
") || die "Failed to verify blocker termination"

    if [[ "$remaining_wait_count" -eq 0 ]]; then
      printf 'No qualifying lock waits remain.\n'
    else
      printf 'WARNING: %s qualifying lock wait(s) remain after termination.\n' \
        "$remaining_wait_count" >&2
    fi
  fi
fi

recent_deadlock_count=0
if ! $SKIP_LOGS; then
  printf '\nRecent PostgreSQL deadlock log entries (last %s)\n' "$SINCE"
  TEMP_LOG=$(mktemp "${TMPDIR:-/tmp}/wxo-postgres-deadlocks.XXXXXX")
  if ! oc logs -n "$NAMESPACE" "$POD_NAME" -c postgres --since="$SINCE" > "$TEMP_LOG"; then
    die "Failed to read PostgreSQL logs from pod $POD_NAME"
  fi
  recent_deadlock_count=$(grep -Eic 'deadlock detected' "$TEMP_LOG" || true)
  if [[ "$recent_deadlock_count" -eq 0 ]]; then
    printf 'No "deadlock detected" entries found.\n'
  else
    grep -Ei -B 1 -A 8 'deadlock detected' "$TEMP_LOG" || true
    printf '\nMatched deadlock entries: %s\n' "$recent_deadlock_count"
  fi
else
  printf '\nPostgreSQL log search skipped.\n'
fi

printf '\nSummary: detected_blocked_sessions=%s remaining_blocked_sessions=%s recent_deadlock_log_entries=%s\n' \
  "$wait_count" "$remaining_wait_count" "$recent_deadlock_count"

if [[ "$wait_count" -gt 0 || "$recent_deadlock_count" -gt 0 ]]; then
  exit 1
fi
exit 0
