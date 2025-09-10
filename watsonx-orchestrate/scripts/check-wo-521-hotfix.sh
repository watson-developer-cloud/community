#!/bin/sh
# hotfixcheck.sh — POSIX /bin/sh
# - Autodetect namespaces (operators via CSV; operands via WO CRs)
# - Check SHAs in Deployments, then Pods (image+imageID), then Jobs (spec images)
# - If SHA not found anywhere, search by IMAGE NAME in Deployments/Pods/Jobs and prompt to delete
# - Retry each test every 15s; press 'c' to move to next test
# - Includes WO readiness & pod health checks

set -eu

# Pick oc or kubectl
if command -v kubectl >/dev/null 2>&1; then K=kubectl
elif command -v oc >/dev/null 2>&1; then K=oc
else echo "kubectl or oc not found" >&2; exit 2; fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "$1 required" >&2; exit 2; }; }
need awk; need sed; need grep; need sort; need tr; need mktemp; need wc; need head; need dd; need stty

SLEEP_SECONDS="${SLEEP_SECONDS:-15}"

hr() { printf '\n%s\n\n' '------------------------------------------------------------'; }
mktempf() { mktemp 2>/dev/null || mktemp -t wxo; }

# ---------------- Targets (image@sha256:...) ----------------
# Operators first (check this namespace before operands)
OPERATOR_TARGETS=$(cat <<'EOF'
ibm-watsonx-orchestrate-operator@sha256:b376e87164fdba54be0d04a313ae398bca54ddfa2949d2b3189dcdf6cad2139a
ibm-document-processing-operator@sha256:c71b04d765b386e8baf739e139d5654369d8271f97e61af4b40b0337c8365d0c
ibm-wxo-component-operator@sha256:63c5aa1f297fffd4682cfb1591f0048872bc116a83c4bf4ffda445c47def4e83
ba-saas-uab-wf-operator@sha256:d4c2a3f274a26dfc26bac9282ed94bac3ef1138f0a6a1ed6d8ba1f2a393a1642
ibm-watsonx-orchestrate-digital-employee-operator@sha256:36d7e9d9294ab245954b2ea378df3e07c92b3c3401866e912241682f226deac4
EOF
)

# Operands next
OPERAND_TARGETS=$(cat <<'EOF'
wxo-server-server@sha256:33a9688d28e199d33e9a725d6a9c519b4c3869ca1a67c2247c3197bd005adf49
wxo-server-conversation_controller@sha256:099db6499f82741f26bf53a66eaf54ac6b5563bc1dcd4958abddb8c6c0af122e
tools-runtime-manager@sha256:c82707bc376e1b410177db36c9599302cd84ba718a4fa45075c4faaa6b5abd94
tools-runtime-scheduler@sha256:774651f7a352019bcdb032796e37f1561af20716a904b59d039f41b7c7cf194b
tools-runtime@sha256:15e6990405e1afec0f4c0b37e9c3afd3b8718103db228781ee3818df1c69175a
ibm-watsonx-orchestrate-onprem-utils@sha256:76baafdd811f2bab5c632d38272f3f4cb05f416d3bf819db4d5288ece3c7afaf
wxo-flow-runtime@sha256:0fe1ff660ba27db1e52fd5329a5c6371b83b6dadf2c5c4857416bf9f33af6389
wxo-builder@sha256:1bfd141ce05ba261f1dbffe6e5133813774c7ee71bca98c0170b037b33e45ae3
ads-restapi@sha256:c93089a467232d7945c9093c2fe8a19c5e51705d32b5ce5c4d98d998a2543389
ads-parsing@sha256:4b9769b9e1946e3df05a8dd65bb27a325e59ef050da0b79ad049be69edf5098c
EOF
)

# ---------------- Helpers ----------------
to_name_sha_lines() {
  # stdin -> "<name>\t<sha256:...>" (lowercased, deduped)
  awk 'BEGIN{IGNORECASE=1}
       { line=$0; sub(/[[:space:]]*#.*$/,"",line); gsub(/\r/,"",line);
         if (line ~ /^[[:space:]]*$/) next;
         for (i=1;i<=length(line);i++){ c=substr(line,i,1); if(c ~ /[A-Z]/) line=substr(line,1,i-1) tolower(c) substr(line,i+1) }
         name=""; sha="";
         at=index(line,"@");
         if (at>0) { name=substr(line,1,at-1); sha=substr(line,at+1) }
         else if (match(line,/(sha256:[0-9a-f]{64})/,m)) { sha=m[1] }
         if (sha!="") printf "%s\t%s\n", name, sha;
       }' | awk -F '\t' '!seen[$0]++'
}

detect_operators_ns() {
  if [ "${PROJECT_CPD_INST_OPERATORS:-}" ]; then
    printf '%s' "$PROJECT_CPD_INST_OPERATORS"; return
  fi
  $K get csv -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null \
  | awk '$2 ~ /^ibm-watsonx-orchestrate-operator\./ {print $1; exit}'
}

detect_operand_namespaces() {
  if [ "${PROJECT_CPD_INST_OPERANDS:-}" ]; then
    printf '%s\n' "$PROJECT_CPD_INST_OPERANDS"; return
  fi
  $K get wo -A -o custom-columns=NS:.metadata.namespace --no-headers 2>/dev/null | sort -u
}

dump_deploy_yaml_once() {
  ns="$1"; outfile="$2"
  if ! $K -n "$ns" get deploy >/dev/null 2>&1; then return 2; fi
  $K -n "$ns" get deploy -o yaml > "$outfile" 2>/dev/null || return 3
  return 0
}

# Build per-namespace lines for pods (image + imageID) and jobs (images)
dump_pod_lines_once() {
  ns="$1"; outfile="$2"
  $K -n "$ns" get pods -o jsonpath='
{range .items[*]}
{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.imageID}{"\n"}{end}
{.metadata.name}{"\t"}{range .status.initContainerStatuses[*]}{.imageID}{"\n"}{end}
{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.image}{"\n"}{end}
{.metadata.name}{"\t"}{range .status.initContainerStatuses[*]}{.image}{"\n"}{end}
{end}' 2>/dev/null \
  | awk -F '\t' 'NF>=2 {print "pod\t"$1"\t"$2}' > "$outfile" 2>/dev/null || true
}

dump_job_lines_once() {
  ns="$1"; outfile="$2"
  $K -n "$ns" get jobs -o jsonpath='
{range .items[*]}
{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{" "}{end}{range .spec.template.spec.initContainers[*]}{.image}{" "}{end}{"\n"}
{end}' 2>/dev/null \
  | awk -F '\t' 'NF>=2 {print "job\t"$1"\t"$2}' > "$outfile" 2>/dev/null || true
}

# Wait/skip gate for each test
press_c_or_wait() {
  secs="${SLEEP_SECONDS:-15}"
  echo "Press 'c' to continue to next check, or wait ${secs}s to retry..."
  if [ -r /dev/tty ]; then
    TTY=/dev/tty
    oldstty="$(stty -g < "$TTY" 2>/dev/null || true)"
    stty -icanon -echo min 0 time 10 < "$TTY" 2>/dev/null || true
    i="$secs"
    while [ "$i" -gt 0 ]; do
      printf "  %2ds remaining... \r" "$i"
      c="$(dd if="$TTY" bs=1 count=1 2>/dev/null || true)"
      case "$c" in
        c|C)
          echo ""
          stty "$oldstty" < "$TTY" 2>/dev/null || true
          echo "Continuing to next check (user pressed 'c')."
          return 0
          ;;
      esac
      i=$((i - 1))
    done
    stty "$oldstty" < "$TTY" 2>/dev/null || true
    echo ""
    return 1
  else
    sleep "$secs"
    return 1
  fi
}

# Name-based searches (fallback)
collect_pod_refs() {
  ns="$1"
  $K -n "$ns" get pods -o jsonpath='
{range .items[*]}
{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.image}{"\n"}{end}
{.metadata.name}{"\t"}{range .status.initContainerStatuses[*]}{.image}{"\n"}{end}
{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{"\n"}{end}
{.metadata.name}{"\t"}{range .spec.initContainers[*]}{.image}{"\n"}{end}
{end}' 2>/dev/null | awk -F '\t' 'NF>=2 {print "pod\t"$1"\t"$2}'
}

collect_job_refs() {
  ns="$1"
  $K -n "$1" get jobs -o jsonpath='
{range .items[*]}
{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}
{.metadata.name}{"\t"}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}
{end}' 2>/dev/null | awk -F '\t' 'NF>=2 {print "job\t"$1"\t"$2}'
}

collect_deploy_refs() {
  ns="$1"
  $K -n "$ns" get deploy -o jsonpath='
{range .items[*]}
{.metadata.name}{"\t"}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}
{.metadata.name}{"\t"}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}
{end}' 2>/dev/null | awk -F '\t' 'NF>=2 {print "deploy\t"$1"\t"$2}'
}

search_name_in_pods_jobs() {
  ns="$1"; name="$2"; outpods="$3"; outjobs="$4"
  : > "$outpods"; : > "$outjobs"
  collect_pod_refs "$ns" | awk -F '\t' -v n="$name" 'BEGIN{IGNORECASE=1} index($3,n)>0 {print $2}' | sort -u > "$outpods"
  collect_job_refs "$ns" | awk -F '\t' -v n="$name" 'BEGIN{IGNORECASE=1} index($3,n)>0 {print $2}' | sort -u > "$outjobs"
}

search_name_in_deploys() {
  ns="$1"; name="$2"; outdeps="$3"
  : > "$outdeps"
  collect_deploy_refs "$ns" | awk -F '\t' -v n="$name" 'BEGIN{IGNORECASE=1} index($3,n)>0 {print $2}' | sort -u > "$outdeps"
}

# Track prompts so we don't nag twice
PROMPTED_FILE="$(mktempf)"
cleanup_prompted() { rm -f "$PROMPTED_FILE"; }
trap cleanup_prompted EXIT INT TERM

already_prompted() {
  kind="$1"; ns="$2"; name="$3"
  grep -F -q "$kind:$ns/$name" "$PROMPTED_FILE" 2>/dev/null
}
mark_prompted() {
  kind="$1"; ns="$2"; name="$3"
  echo "$kind:$ns/$name" >> "$PROMPTED_FILE"
}
prompt_delete() {
  kind="$1"; ns="$2"; name="$3"; short="$4" # short: deploy|pod|job
  if already_prompted "$kind" "$ns" "$name"; then return 0; fi
  mark_prompted "$kind" "$ns" "$name"
  if [ -r /dev/tty ]; then
    printf "Delete %s '%s' in namespace '%s' so it can pick up new image? [y/N] " "$kind" "$name" "$ns" > /dev/tty
    ans="$(dd if=/dev/tty bs=1 count=1 2>/dev/null || true)"
    echo ""
    case "$ans" in
      y|Y)
        echo "Deleting $kind $name in $ns..."
        $K -n "$ns" delete "$short" "$name" --ignore-not-found=true || true
        ;;
      *) echo "Skipping delete for $kind $name." ;;
    esac
  else
    echo "No TTY; skipping interactive delete for $kind '$name' in '$ns'."
  fi
}

# SHA presence helpers using pre-dumped lines
sha_in_pods() {
  pods_lines="$1"; sha="$2"; outpods="$3"
  grep -F "$sha" "$pods_lines" 2>/dev/null | awk -F '\t' '$1=="pod"{print $2}' | sort -u > "$outpods" || : 
}

sha_in_jobs() {
  jobs_lines="$1"; sha="$2"; outjobs="$3"
  grep -F "$sha" "$jobs_lines" 2>/dev/null | awk -F '\t' '$1=="job"{print $2}' | sort -u > "$outjobs" || :
}

# Core SHA check against one namespace
check_shas_against_dump() {
  ns="$1"; sha_block="$2"; deploy_yaml="$3"; pods_lines="$4"; jobs_lines="$5"
  missing=0; total=0

  tmp_targets="$(mktempf)"
  echo "$sha_block" | to_name_sha_lines > "$tmp_targets"
  total="$(awk -F '\t' '{print $NF}' "$tmp_targets" | sort -u | wc -l | tr -d ' ')"

  while IFS="$(printf '\t')" read -r name sha; do
    [ -n "${name:-}" ] || name="<unknown>"
    printf 'Checking: %s @ %s\n' "$name" "$sha"

    if grep -Fq "$sha" "$deploy_yaml"; then
      echo "  => FOUND in Deployments"
      echo
      continue
    fi

    # Not in Deployments: check Pods/Jobs for SHA
    pods_out="$(mktempf)"; jobs_out="$(mktempf)"
    sha_in_pods "$pods_lines" "$sha" "$pods_out"
    sha_in_jobs "$jobs_lines" "$sha" "$jobs_out"
    pods_cnt="$(wc -l < "$pods_out" | tr -d ' ')"
    jobs_cnt="$(wc -l < "$jobs_out" | tr -d ' ')"

    if [ "$pods_cnt" -gt 0 ] || [ "$jobs_cnt" -gt 0 ]; then
      [ "$pods_cnt" -gt 0 ] && {
        echo "  => FOUND in Pods ($pods_cnt):"
        head -n 5 "$pods_out" | sed 's/^/      - /'
        [ "$pods_cnt" -gt 5 ] && echo "      ... ($((pods_cnt-5)) more)"
      }
      [ "$jobs_cnt" -gt 0 ] && {
        echo "  => FOUND in Jobs ($jobs_cnt):"
        head -n 5 "$jobs_out" | sed 's/^/      - /'
        [ "$jobs_cnt" -gt 5 ] && echo "      ... ($((jobs_cnt-5)) more)"
      }
      echo
      rm -f "$pods_out" "$jobs_out"
      continue
    fi
    rm -f "$pods_out" "$jobs_out"

    # Still not found anywhere -> fallback: search by IMAGE NAME in Deployments/Pods/Jobs
    echo "  => NOT FOUND by SHA; searching by image name '$name'..."
    deps_out="$(mktempf)"; pods_byname="$(mktempf)"; jobs_byname="$(mktempf)"
    search_name_in_deploys "$ns" "$name" "$deps_out"
    search_name_in_pods_jobs "$ns" "$name" "$pods_byname" "$jobs_byname"

    deps_cnt="$(wc -l < "$deps_out" | tr -d ' ')"
    pods_cnt="$(wc -l < "$pods_byname" | tr -d ' ')"
    jobs_cnt="$(wc -l < "$jobs_byname" | tr -d ' ')"

    echo "    Deployments with image name: $deps_cnt"
    [ "$deps_cnt" -gt 0 ] && { head -n 5 "$deps_out" | sed 's/^/      - /'; [ "$deps_cnt" -gt 5 ] && echo "      ... ($((deps_cnt-5)) more)"; }
    echo "    Pods with image name       : $pods_cnt"
    [ "$pods_cnt" -gt 0 ] && { head -n 5 "$pods_byname" | sed 's/^/      - /'; [ "$pods_cnt" -gt 5 ] && echo "      ... ($((pods_cnt-5)) more)"; }
    echo "    Jobs with image name       : $jobs_cnt"
    [ "$jobs_cnt" -gt 0 ] && { head -n 5 "$jobs_byname" | sed 's/^/      - /'; [ "$jobs_cnt" -gt 5 ] && echo "      ... ($((jobs_cnt-5)) more)"; }
    echo

    # Offer deletions so new image can be pulled
    if [ "$deps_cnt" -gt 0 ] || [ "$pods_cnt" -gt 0 ] || [ "$jobs_cnt" -gt 0 ]; then
      for d in $(cat "$deps_out"); do prompt_delete "Deployment" "$ns" "$d" "deploy"; done
      for p in $(cat "$pods_byname"); do prompt_delete "Pod" "$ns" "$p" "pod"; done
      for j in $(cat "$jobs_byname"); do prompt_delete "Job" "$ns" "$j" "job"; done
    fi

    rm -f "$deps_out" "$pods_byname" "$jobs_byname"
    missing=$((missing+1))
    echo
  done < "$tmp_targets"

  rm -f "$tmp_targets"
  echo "Summary (namespace: $ns): ${total} SHAs checked, ${missing} missing"
  [ "$missing" -eq 0 ]
}

print_pod_issues() {
  ns="$1"
  $K -n "$ns" get pods -o \
    jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.containerStatuses[*]}{.ready}{" "}{end}{"\t"}{range .status.initContainerStatuses[*]}{.state.waiting.reason}{" "}{end}{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{end}{"\n"}{end}' \
  | awk -F '\t' '
      {
        pod=$1; phase=$2; readyfld=$3; reasons=$4
        if (reasons ~ /(CrashLoopBackOff|ImagePullBackOff)/) {
          n=split(reasons, arr, /[[:space:]]+/)
          for (i=1;i<=n;i++) if (arr[i] ~ /(CrashLoopBackOff|ImagePullBackOff)/) {
            printf "fail\t%s\treason=%s\n", pod, arr[i]; break
          }
        }
        split(readyfld, rs, /[[:space:]]+/); total=0; ready=0
        for (i in rs) if (rs[i]!="") { total++; if (rs[i]=="true") ready++ }
        if (phase=="Running" && total>0 && ready<total) {
          printf "not_ready\t%s\tready=%d/%d\n", pod, ready, total
        }
      }'
}

wo_any_completed() {
  ns="$1"
  statuses="$($K -n "$ns" get wo -o jsonpath='{range .items[*]}{.status.watsonxOrchestrateStatus}{"\n"}{end}' 2>/dev/null || true)"
  [ -n "$statuses" ] || { echo "no_wo"; return 1; }
  echo "$statuses" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -d ' ' \
  | awk '/^completed$/ {found=1} END{ if(found) print "completed"; else print "not_completed" }'
}

# ---------------- Autodetect namespaces ----------------
OPERATORS_NS="$(detect_operators_ns 2>/dev/null || true)"
OPERAND_NS_LIST="$(detect_operand_namespaces 2>/dev/null || true)"

hr
echo "Autodetected namespaces"
echo "  Operators: ${OPERATORS_NS:-<none>}"
if [ -n "${OPERAND_NS_LIST:-}" ]; then
  echo "  Operands :"
  echo "$OPERAND_NS_LIST" | sed 's/^/    - /'
else
  echo "  Operands : <none>"
fi

overall=0

# ---------------- Check A: Operator SHAs ----------------
hr
echo "Check A: Operator SHAs (Deployments, Pods, Jobs)"
if [ -z "${OPERATORS_NS:-}" ]; then
  echo "  Could not find operator CSV (ibm-watsonx-orchestrate-operator.*)."
  overall=1
else
  tmp_dep_yaml="$(mktempf)"
  tmp_pod_lines="$(mktempf)"
  tmp_job_lines="$(mktempf)"
  while : ; do
    if dump_deploy_yaml_once "$OPERATORS_NS" "$tmp_dep_yaml"; then :; else echo "  Cannot get deployments YAML in $OPERATORS_NS — retrying..."; fi
    dump_pod_lines_once "$OPERATORS_NS" "$tmp_pod_lines"
    dump_job_lines_once "$OPERATORS_NS" "$tmp_job_lines"

    if check_shas_against_dump "$OPERATORS_NS" "$OPERATOR_TARGETS" "$tmp_dep_yaml" "$tmp_pod_lines" "$tmp_job_lines"; then
      break # passed
    fi
    if press_c_or_wait; then
      overall=1
      break
    fi
  done
  rm -f "$tmp_dep_yaml" "$tmp_pod_lines" "$tmp_job_lines"
fi

# ---------------- Check B: Operand SHAs per WO namespace ----------------
for ns in $OPERAND_NS_LIST; do
  hr
  echo "Check B: Operand SHAs (namespace: $ns) (Deployments, Pods, Jobs)"
  tmp_dep_yaml="$(mktempf)"
  tmp_pod_lines="$(mktempf)"
  tmp_job_lines="$(mktempf)"
  while : ; do
    if dump_deploy_yaml_once "$ns" "$tmp_dep_yaml"; then :; else echo "  Cannot get deployments YAML in $ns — retrying..."; fi
    dump_pod_lines_once "$ns" "$tmp_pod_lines"
    dump_job_lines_once "$ns" "$tmp_job_lines"
    if check_shas_against_dump "$ns" "$OPERAND_TARGETS" "$tmp_dep_yaml" "$tmp_pod_lines" "$tmp_job_lines"; then
      break
    fi
    if press_c_or_wait; then
      overall=1
      break  # user pressed 'c'
    fi
  done
  rm -f "$tmp_dep_yaml" "$tmp_pod_lines" "$tmp_job_lines"
done

# ---------------- Check C: WO readiness & pod health ----------------
for ns in $OPERAND_NS_LIST; do
  hr
  echo "Check C: WO readiness & pod health (namespace: $ns)"
  if ! $K -n "$ns" get wo >/dev/null 2>&1; then
    echo "  wo resource not found in $ns"
    overall=1
    continue
  fi
  while : ; do
    $K -n "$ns" get wo || true
    echo
    issues="$(print_pod_issues "$ns" || true)"
    issue_count=$(printf '%s\n' "$issues" | awk 'NF{n++} END{print n+0}')
    if [ "$issue_count" -gt 0 ]; then
      echo "Pods not ready or failing: $issue_count"
      printf '  %-10s | %-52s | %s\n' "TYPE" "POD" "DETAILS"
      printf '  %s\n' "----------------------------------------------------------------------------"
      printf '%s\n' "$issues" | awk -F '\t' '{ printf "  %-10s | %-52s | %s\n", toupper($1), $2, $3 }'
      echo
    else
      echo "Pods not ready or failing: 0"
      echo
    fi
    sw="$(wo_any_completed "$ns" || true)"
    if [ "$sw" = "completed" ] && [ "$issue_count" -eq 0 ]; then
      echo "watsonx Orchestrate is in Completed status and pods are healthy in $ns."
      break  # passed
    fi
    if press_c_or_wait; then
      overall=1
      break  # user pressed 'c'
    fi
  done
done

exit "$overall"
