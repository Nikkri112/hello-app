#!/bin/bash
# Проверка здоровья стека:  bash verify.sh
# Печатает статус каждого компонента; код возврата 0 = всё работает.
set -uo pipefail

FAIL=0

ok()   { echo "  OK   : $1"; }
bad()  { echo "  FAIL : $1"; FAIL=1; }

echo "── Нода ─────────────────────────────────────────────"
NODE_STATUS=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
[ "$NODE_STATUS" = "True" ] && ok "нода Ready" || bad "нода не Ready ($NODE_STATUS)"

echo "── Поды (все namespace'ы) ───────────────────────────"
NOT_RUNNING=$(kubectl get pods -A 2>/dev/null | awk '$4!="Running" && $4!="Completed" && NR>1 {print $1"/"$2": "$4}')
if [ -z "$NOT_RUNNING" ]; then
  ok "все поды Running/Completed"
else
  bad "есть проблемные поды:"
  echo "$NOT_RUNNING" | sed 's/^/         /'
fi

echo "── Gateway API ──────────────────────────────────────"
PROGRAMMED=$(kubectl -n hello-app get gateway hello-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
[ "$PROGRAMMED" = "True" ] && ok "Gateway Programmed=True" || bad "Gateway Programmed=$PROGRAMMED"

LB_IP=$(kubectl -n envoy-gateway-system get svc -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ -n "$LB_IP" ]; then
  ok "External-IP балансировщика: $LB_IP"
else
  bad "External-IP не выдан (MetalLB?)"
fi

echo "── Приложение (реальный HTTP-запрос) ────────────────"
NODE_IP=$(hostname -I | awk '{print $1}')
NODEPORT=$(kubectl -n envoy-gateway-system get svc -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].spec.ports[0].nodePort}' 2>/dev/null)
if [ -n "$NODEPORT" ]; then
  RESP=$(curl -s -m 10 "http://${NODE_IP}:${NODEPORT}" 2>/dev/null)
  if echo "$RESP" | grep -q "Hello"; then
    ok "curl http://${NODE_IP}:${NODEPORT} -> Hello World!"
  else
    bad "запрос не вернул Hello World"
  fi
else
  bad "NodePort не найден"
fi

echo "── Prometheus (метрика up) ──────────────────────────"
UP=$(kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=up' 2>/dev/null | \
  python3 -c '
import json,sys
try:
    d=json.load(sys.stdin); res=d["data"]["result"]
    up=[r for r in res if r["value"][1]=="1"]
    print(f"{len(up)}/{len(res)}")
except Exception: print("?")' 2>/dev/null)
if [ "$UP" != "?" ] && [ -n "$UP" ]; then
  if [ "$UP" = "0/0" ]; then
    bad "Prometheus не отвечает или не имеет целей"
  else
    ok "scrape-целей живых: $UP"
  fi
else
  bad "Prometheus API недоступен"
fi

echo "── Логи (Filebeat) ──────────────────────────────────"
FB_STATUS=$(kubectl -n logging get ds filebeat -o jsonpath='{.status.numberReady}' 2>/dev/null)
FB_DESIRED=$(kubectl -n logging get ds filebeat -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
if [ -n "$FB_STATUS" ] && [ -n "$FB_DESIRED" ] && [ "$FB_STATUS" = "$FB_DESIRED" ]; then
  ok "Filebeat готов ($FB_STATUS/$FB_DESIRED)"
else
  bad "Filebeat не готов ($FB_STATUS/$FB_DESIRED)"
fi

echo
if [ "$FAIL" = "0" ]; then
  echo "=== ВСЁ РАБОТАЕТ ==="
else
  echo "=== ЕСТЬ ПРОБЛЕМЫ - смотри FAIL выше ==="
fi
exit $FAIL
