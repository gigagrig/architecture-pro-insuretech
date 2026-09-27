#!/usr/bin/env bash
# Run from the repository root. Keep raw observations, including transient errors.
set -eu
mode=${1:?Usage: bash Task2/capture.sh memory-or-rps [samples]}
samples=${2:-30}
case "$mode" in memory|rps) ;; *) exit 2 ;; esac
for ((i=0; i<samples; i++)); do
  date -u '+%Y-%m-%dT%H:%M:%SZ'
  kubectl --context=insuretech-task2 -n task2 get hpa scaletestapp
  kubectl --context=insuretech-task2 -n task2 get deployment scaletestapp
  kubectl --context=insuretech-task2 -n task2 top pods -l app=scaletestapp || true
  kubectl --context=insuretech-task2 -n task2 get pods -l app=scaletestapp
  sleep 15
done
kubectl --context=insuretech-task2 -n task2 describe hpa scaletestapp
