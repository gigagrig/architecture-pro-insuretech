#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
chart_dir=$(mktemp -d)
helm pull prometheus-adapter \
  --repo https://prometheus-community.github.io/helm-charts \
  --version 5.3.0 --destination "$chart_dir"
helm template task2-adapter "$chart_dir/prometheus-adapter-5.3.0.tgz" \
  --namespace task2 --kube-version 1.35.1 \
  --api-versions apiregistration.k8s.io/v1 \
  -f Task2/adapter-values.yaml > "$chart_dir/adapter.yaml"
kubectl --context=insuretech-task2 apply -f "$chart_dir/adapter.yaml"
kubectl --context=insuretech-task2 -n task2 rollout status \
  deployment/task2-adapter-prometheus-adapter --timeout=180s
