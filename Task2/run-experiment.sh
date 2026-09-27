#!/usr/bin/env bash
# Usage from repository root: bash Task2/run-experiment.sh memory|rps URL USERS RATE
set -euo pipefail
mode=${1:?memory or rps}
app_url=${2:?Application URL}
users=${3:?Users}
spawn_rate=${4:?Spawn rate}
case "$mode" in memory|rps) ;; *) exit 2 ;; esac
prefix="Task2/evidence/${mode}"
# Overwrite only this experiment's named results when deliberately rerun.
kubectl --context=insuretech-task2 apply -f "Task2/hpa-${mode}.yaml"
kubectl --context=insuretech-task2 -n task2 rollout status deployment/scaletestapp --timeout=180s
bash Task2/capture.sh "$mode" 32 > "${prefix}-scaling.log" 2>&1 &
capture_pid=$!
trap 'kill "$capture_pid" 2>/dev/null || true' EXIT
# Record a one-minute baseline before starting user requests.
sleep 60
date -u '+load_start=%Y-%m-%dT%H:%M:%SZ' > "${prefix}-timing.txt"
set +e
.venv/bin/locust -f Task2/locustfile.py --headless --host "$app_url" \
  -u "$users" -r "$spawn_rate" -t 4m --only-summary \
  --csv "$prefix" --csv-full-history > "${prefix}-locust.log" 2>&1
load_status=$?
set -e
date -u '+load_end=%Y-%m-%dT%H:%M:%SZ' >> "${prefix}-timing.txt"
printf 'locust_exit_code=%s\n' "$load_status" >> "${prefix}-timing.txt"
wait "$capture_pid"
kubectl --context=insuretech-task2 -n task2 describe hpa scaletestapp > "${prefix}-hpa.txt"
kubectl --context=insuretech-task2 -n task2 get deployment scaletestapp -o yaml > "${prefix}-deployment.yaml"
kubectl --context=insuretech-task2 -n task2 get events --sort-by=.lastTimestamp > "${prefix}-events.txt"
exit "$load_status"
