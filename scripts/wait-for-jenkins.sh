#!/usr/bin/env bash
# Polls the Jenkins controller pod and prints what is happening until it is
# Ready or the timeout expires. Output goes to the terminal AND to a log file.
#
#   usage: wait-for-jenkins.sh <kubeconfig> <namespace> <timeout-seconds> <logfile>
set -u
KUBECONFIG_PATH=${1:?kubeconfig}; NS=${2:-jenkins}; TIMEOUT=${3:-1800}; LOG=${4:-jenkins-startup.log}
export KUBECONFIG="$KUBECONFIG_PATH"
POD=jenkins-0
start=$(date +%s)
: > "$LOG"
say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }

say "waiting for pod $NS/$POD (timeout ${TIMEOUT}s); log: $LOG"
while :; do
  now=$(date +%s); elapsed=$((now-start))

  if ! kubectl -n "$NS" get pod "$POD" >/dev/null 2>&1; then
    say "[${elapsed}s] pod not created yet (StatefulSet/PVC?)"
    kubectl -n "$NS" get sts,pvc 2>/dev/null | tee -a "$LOG"
    kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>/dev/null | tail -5 | tee -a "$LOG"
  else
    phase=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}')
    ready=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{range .status.containerStatuses[?(@.name=="jenkins")]}{.ready}{end}')
    say "[${elapsed}s] phase=$phase jenkins-ready=${ready:-n/a}"

    # init / sidecar containers state
    kubectl -n "$NS" get pod "$POD" -o json 2>/dev/null | python3 -c '
import json,sys
p=json.load(sys.stdin); st=p.get("status",{})
for kind in ("initContainerStatuses","containerStatuses"):
    for c in st.get(kind,[]):
        s=c.get("state",{}); k=list(s.keys())[0] if s else "?"
        d=s.get(k,{}); extra=d.get("reason") or d.get("message") or ""
        name=c.get("name"); rc=c.get("restartCount",0)
        print("    %-4s %-14s %-10s restarts=%s %s" % (kind[:4], name, k, rc, extra))
' | tee -a "$LOG"

    if [ "$ready" = "true" ]; then
      say "Jenkins is Ready after ${elapsed}s"
      exit 0
    fi

    # Show the newest events + the tail of whichever container is doing work.
    kubectl -n "$NS" get events --field-selector involvedObject.name="$POD" \
      --sort-by=.lastTimestamp 2>/dev/null | tail -4 | sed 's/^/    ev: /' | tee -a "$LOG"
    # Init container crash-looping? Show its last run's output, that's the cause.
    if kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.initContainerStatuses[?(@.name=="init")].lastState.terminated.reason}' 2>/dev/null | grep -q .; then
      say "    !! plugin-download init container failed on its last run; last output:"
      kubectl -n "$NS" logs "$POD" -c init --previous --tail=15 2>/dev/null | sed 's/^/    [init prev] /' | tee -a "$LOG"
    fi
    for c in init jenkins; do
      lines=$(kubectl -n "$NS" logs "$POD" -c "$c" --tail=3 2>/dev/null)
      [ -n "$lines" ] && printf '%s\n' "$lines" | sed "s/^/    [$c] /" | tee -a "$LOG"
    done
  fi

  if [ "$elapsed" -ge "$TIMEOUT" ]; then
    say "TIMEOUT after ${elapsed}s -- full dump follows"
    { kubectl -n "$NS" describe pod "$POD"; echo; echo "===== init logs";
      kubectl -n "$NS" logs "$POD" -c init --tail=200; echo "===== jenkins logs";
      kubectl -n "$NS" logs "$POD" -c jenkins --tail=200; echo "===== istio-proxy logs";
      kubectl -n "$NS" logs "$POD" -c istio-proxy --tail=50; } >> "$LOG" 2>&1
    echo "see $LOG"
    exit 1
  fi
  sleep 15
done
