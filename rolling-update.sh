
#!/bin/bash

set -euo pipefail  # Enable strict mode
CONFIG_FILE="./conf/web.yml"
BLUE_SERVICE="web-blue"
GREEN_SERVICE="web-green"
SERVICE_PORT=3000

TIMEOUT=60  # Timeout in seconds
SLEEP_INTERVAL=5  # Time to sleep between retries in seconds
MAX_RETRIES=$((TIMEOUT / SLEEP_INTERVAL))

TRAEFIK_NETWORK="zero-downtime_webgateway"
TRAEFIK_API_URL="http://localhost:8080/api/http/services"
COMPOSE_NAME="docker-compose.yml"

# Find which service is currently active
if docker ps --format "{{.Names}}" | grep -q "$BLUE_SERVICE"; then
  ACTIVE_SERVICE=$BLUE_SERVICE
  INACTIVE_SERVICE=$GREEN_SERVICE
elif docker ps --format "{{.Names}}" | grep -q "$GREEN_SERVICE"; then
  ACTIVE_SERVICE=$GREEN_SERVICE
  INACTIVE_SERVICE=$BLUE_SERVICE
else
  ACTIVE_SERVICE=""
  INACTIVE_SERVICE=$BLUE_SERVICE
fi
# 获取老容器的IP
OLD_CONTAINER_IP=$(docker inspect --format='{{range $key, $value := .NetworkSettings.Networks}}{{if eq $key "'"$TRAEFIK_NETWORK"'"}}{{$value.IPAddress}}{{end}}{{end}}' "$ACTIVE_SERVICE" || true)

# Start the new environment
echo "启动新版本容器 $INACTIVE_SERVICE"
docker-compose -f $COMPOSE_NAME up --build  --detach $INACTIVE_SERVICE

# Wait for the new environment to become healthy
echo "等待新服务容器 $INACTIVE_SERVICE 启动完成..."
for ((i=1; i<=$MAX_RETRIES; i++)); do
  CONTAINER_IP=$(docker inspect --format='{{range $key, $value := .NetworkSettings.Networks}}{{if eq $key "'"$TRAEFIK_NETWORK"'"}}{{$value.IPAddress}}{{end}}{{end}}' "$INACTIVE_SERVICE" || true)
  if [[ -z "$CONTAINER_IP" ]]; then
    # The docker inspect command failed, so sleep for a bit and retry
    sleep "$SLEEP_INTERVAL"
    continue
  fi

  HEALTH_CHECK_URL="http://$CONTAINER_IP:$SERVICE_PORT/health"
  # N.B.: We use docker to execute curl because on macOS we are unable to directly access the docker-managed Traefik network.
  if docker run --net $TRAEFIK_NETWORK --rm curlimages/curl:8.00.1 --fail --silent "$HEALTH_CHECK_URL" >/dev/null; then
    echo "$INACTIVE_SERVICE 启动完成"
    # 将新服务加入负载均衡
    sed -i "/# service URL start/a\          - url: \"http://$CONTAINER_IP:$SERVICE_PORT\""  $CONFIG_FILE
    break
  fi

  sleep "$SLEEP_INTERVAL"
done

# If the new environment is not healthy within the timeout, stop it and exit with an error
if ! docker run --net $TRAEFIK_NETWORK --rm curlimages/curl:8.00.1 --fail --silent "$HEALTH_CHECK_URL" >/dev/null; then
  echo "$INACTIVE_SERVICE 在 $TIMEOUT 秒内启动失败"
  docker compose stop --timeout=30 $INACTIVE_SERVICE
  exit 1
fi

# Check that Traefik recognizes the new container
echo "检查 Traefik 是否发现新服务容器： $INACTIVE_SERVICE..."
for ((i=1; i<=$MAX_RETRIES; i++)); do
  # N.B.: Because Traefik's port is mapped, we don't need to use the same trick as above for this to work on macOS.
  TRAEFIK_SERVER_STATUS=$(curl --fail --silent "$TRAEFIK_API_URL" | jq --arg container_ip "http://$CONTAINER_IP:$SERVICE_PORT" '.[] | select(.type == "loadbalancer") | select(.serverStatus[$container_ip] == "UP") | .serverStatus[$container_ip]')
  if [[ -n "$TRAEFIK_SERVER_STATUS" ]]; then
    echo "Traefik 发现 $INACTIVE_SERVICE 容器"
     # 将老服务从负载均衡删除
    sed -i "/$OLD_CONTAINER_IP:$SERVICE_PORT/d" $CONFIG_FILE
    break
  fi

  sleep "$SLEEP_INTERVAL"
done

# If Traefik does not recognize the new container within the timeout, stop it and exit with an error
if [[ -z "$TRAEFIK_SERVER_STATUS" ]]; then
  echo "Traefik 在 $TIMEOUT 秒内，未发现 $INACTIVE_SERVICE 容器"
  docker compose stop --timeout=30 $INACTIVE_SERVICE
  exit 1
fi

echo "将流量切换到新服务"
for ((i=1; i<=$MAX_RETRIES; i++)); do
  # N.B.: Because Traefik's port is mapped, we don't need to use the same trick as above for this to work on macOS.
  OLD_SERVER_STATUS=$(curl --fail --silent "$TRAEFIK_API_URL" | jq --arg container_ip "http://$OLD_CONTAINER_IP:$SERVICE_PORT" '.[] | select(.type == "loadbalancer") | select(.serverStatus[$container_ip] == "UP") | .serverStatus[$container_ip]')
  echo "流量切换中..."
  if [[ -z "$OLD_SERVER_STATUS" ]]; then
    echo "流量切换完成"
    break
  fi

  sleep "$SLEEP_INTERVAL"
done

sleep "$SLEEP_INTERVAL"
# Set Traefik priority label to 0 on the old service and stop the old environment if it was previously running
if [[ -n "$ACTIVE_SERVICE" ]]; then
  echo "关闭旧 $ACTIVE_SERVICE 容器"
  docker-compose -f $COMPOSE_NAME stop --timeout=10 $ACTIVE_SERVICE
fi
