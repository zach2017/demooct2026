#!/usr/bin/env bash
# Dependencies for 00-cluster: host tooling and Docker only (nothing upstream).
source "$(dirname "$0")/../../scripts/lib/check.sh"
check_header 00-cluster
check_cli terraform "https://developer.hashicorp.com/terraform/install"
check_cli kind      "brew install kind"
check_cli kubectl   "brew install kubectl"
check_cli docker    "install Docker Desktop"
check_cli python3   "used by the guard/check scripts"
check_docker
# Memory sanity: kind + Istio + Jenkins want ~5 GB
#if docker info >/dev/null 2>&1; then
#  mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null); gb=$(( ${mem:-0} / 1073741824 ))
#  if [ "$gb" -ge 6 ]; then _ok "docker memory" "${gb} GB"; else _bad "docker memory" "${gb} GB; raise to >= 6 GB in Docker Desktop > Resources"; fi
#fi
# Host ports the ingress gateway will be mapped to
for p in 8080 8443; do
  if (command -v lsof >/dev/null && lsof -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1); then _bad "host port $p" "already in use: $(lsof -iTCP:$p -sTCP:LISTEN -Fc | sed -n 's/^c//p' | head -1)"; else _ok "host port $p" "free"; fi
done
check_summary
