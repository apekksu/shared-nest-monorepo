#!/bin/bash
set -Eeuo pipefail

export AWS_PAGER=""
umask 027

export HOME=/home/ubuntu

decode_argument() {
  local value="$1"

  if [[ "$value" == base64:* ]]; then
    printf '%s' "${value#base64:}" | base64 -d
  else
    printf '%s' "$value"
  fi
}

APPLICATION_NAME="$1"
APPLICATION_PORT="$2"
S3_BUCKET_NAME="$3"
SECRETS_JSON="$(decode_argument "$4")"
HEALTHCHECK_PATH="${5:-/}"
HEALTHCHECK_ENABLED="${6:-false}"
CANARY_COMMAND="$(decode_argument "${7:-}")"

PROCESS_NAME="${APPLICATION_NAME}-${APPLICATION_PORT}"
APP_DIR="/home/ubuntu/${APPLICATION_NAME}"
RELEASE_ID="$(date -u +%Y%m%d%H%M%S)-$$"
RELEASE_DIR="/home/ubuntu/${APPLICATION_NAME}.release-${RELEASE_ID}"
BACKUP_DIR="/home/ubuntu/${APPLICATION_NAME}.previous"
LOCK_FILE="/tmp/deploy-${APPLICATION_NAME}-${APPLICATION_PORT}.lock"
CANARY_PORT=$((APPLICATION_PORT + 1000))
CANARY_LOG="/tmp/${APPLICATION_NAME}-${RELEASE_ID}-canary.log"
CANARY_PID=""

kill_pid_or_group() {
  local pid="$1"
  local pgid

  pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ -n "$pgid" && "$pgid" != "1" ]]; then
    kill -- "-$pgid" >/dev/null 2>&1 || true
  else
    kill "$pid" >/dev/null 2>&1 || true
  fi
}

kill_canary() {
  if [[ -z "${CANARY_PID:-}" ]]; then
    return 0
  fi

  if kill -0 "$CANARY_PID" >/dev/null 2>&1; then
    kill_pid_or_group "$CANARY_PID"
    for _ in {1..20}; do
      kill -0 "$CANARY_PID" >/dev/null 2>&1 || break
      sleep 0.5
    done
    if kill -0 "$CANARY_PID" >/dev/null 2>&1; then
      local pgid
      pgid="$(ps -o pgid= -p "$CANARY_PID" 2>/dev/null | tr -d ' ' || true)"
      if [[ -n "$pgid" && "$pgid" != "1" ]]; then
        kill -KILL -- "-$pgid" >/dev/null 2>&1 || true
      else
        kill -KILL "$CANARY_PID" >/dev/null 2>&1 || true
      fi
    fi
    wait "$CANARY_PID" >/dev/null 2>&1 || true
  fi

  CANARY_PID=""
}

kill_port_listeners() {
  local port="$1"
  local pids=()

  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(
    sudo ss -H -lntp 2>/dev/null \
      | awk -v port=":$port" '$4 ~ port "$" {print $0}' \
      | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' \
      | sort -u
  )

  for pid in "${pids[@]}"; do
    echo "Stopping stale listener on canary port $port: pid $pid ($(ps -p "$pid" -o comm= 2>/dev/null || true))"
    kill_pid_or_group "$pid"
  done
}

trim_logs() {
  local log_dir="/home/ubuntu/.pm2/logs"

  if [[ -d "$log_dir" ]]; then
    find "$log_dir" -maxdepth 1 -type f -name "${PROCESS_NAME}-*.log" -size +200M -print \
      -exec sh -c 'echo "Truncating oversized PM2 log: $1"; : > "$1"' _ {} \; || true
  fi

  find /tmp -maxdepth 1 -type f -name "${APPLICATION_NAME}-*-canary.log" -mtime +1 -print -delete || true
}

cleanup() {
  local rc=$?
  kill_canary
  if [[ -d "$RELEASE_DIR" ]]; then
    rm -rf "$RELEASE_DIR" || true
  fi
  echo "[deploy] finished with exit code $rc"
  exit "$rc"
}
trap cleanup EXIT

normalize_health_path() {
  local path="$1"
  [[ "$path" == /* ]] || path="/$path"
  printf '%s' "$path"
}

health_url() {
  local port="$1"
  printf 'http://127.0.0.1:%s%s' "$port" "$(normalize_health_path "$HEALTHCHECK_PATH")"
}

wait_for_http() {
  local port="$1"
  local label="$2"
  local url
  url="$(health_url "$port")"

  for i in {1..40}; do
    local code
    code="$(curl -sS -o /dev/null -w "%{http_code}" "$url" || true)"
    echo "$label health attempt $i: $url -> $code"
    case "$code" in
      2*|3*) return 0 ;;
    esac
    sleep 3
  done

  return 1
}

stop_pm2() {
  if sudo -u ubuntu pm2 describe "$PROCESS_NAME" >/dev/null 2>&1; then
    echo "Stopping and deleting PM2 process: $PROCESS_NAME"
    sudo -u ubuntu pm2 stop "$PROCESS_NAME" || true
    sudo -u ubuntu pm2 delete "$PROCESS_NAME" || true
  fi
}

start_pm2() {
  local cwd="$1"
  sudo -u ubuntu bash -lc \
    "export PORT='$APPLICATION_PORT' APPLICATION_PORT='$APPLICATION_PORT' NODE_ENV=production; \
     pm2 delete '$PROCESS_NAME' >/dev/null 2>&1 || true; \
     pm2 start npm --name '$PROCESS_NAME' --cwd '$cwd' -- start --update-env; \
     pm2 save"
}

rollback_previous_release() {
  echo "Rolling back to previous release..."
  stop_pm2

  if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "No previous release exists at $BACKUP_DIR; rollback is not possible."
    return 1
  fi

  rm -rf "$APP_DIR"
  mv "$BACKUP_DIR" "$APP_DIR"
  chown -R ubuntu:ubuntu "$APP_DIR"

  start_pm2 "$APP_DIR"
  if [[ "$HEALTHCHECK_ENABLED" == "true" ]]; then
    wait_for_http "$APPLICATION_PORT" "Rollback" || true
  fi
}


if [[ -z "${NO_TEE:-}" ]]; then
  exec > >(tee -a /home/ubuntu/deploy_script.log) 2>&1
else
  exec >> /home/ubuntu/deploy_script.log 2>&1
fi

echo "Starting deployment script for $APPLICATION_NAME..."
cd /home/ubuntu

if ! [[ "$APPLICATION_PORT" =~ ^[0-9]+$ ]]; then
  echo "ERROR: application port must be numeric, got: $APPLICATION_PORT"
  exit 2
fi

exec 9>"$LOCK_FILE"
echo "Waiting for deployment lock: $LOCK_FILE"
if ! flock -w 1200 9; then
  echo "ERROR: timed out waiting for another deployment to finish."
  exit 75
fi
echo "Deployment lock acquired."

trim_logs
if [[ "$HEALTHCHECK_ENABLED" == "true" ]]; then
  kill_port_listeners "$CANARY_PORT"
fi

rm -rf "$RELEASE_DIR"
mkdir "$RELEASE_DIR"
cd "$RELEASE_DIR"

echo "Downloading application package from S3 bucket: $S3_BUCKET_NAME"

if ! aws s3 cp --no-progress --only-show-errors \
  "s3://${S3_BUCKET_NAME}/${APPLICATION_NAME}/${APPLICATION_NAME}.zip" .; then
  echo "Failed to download application package from S3"
  exit 1
fi
echo "Application package downloaded successfully."

echo "Unzipping application package..."
if ! unzip -o "${APPLICATION_NAME}.zip" > /dev/null; then
  echo "Failed to unzip application package"
  exit 1
fi
echo "Application package unzipped successfully."
rm -f "${APPLICATION_NAME}.zip" || true

chown -R ubuntu:ubuntu "$RELEASE_DIR"

echo "Fetching secrets from AWS Secrets Manager"
set +x
echo "$SECRETS_JSON" | jq -c '.[]' | while read -r item; do
  secret=$(echo "$item" | jq -r '.secret')
  envpath=$(echo "$item" | jq -r '.path')
  echo "Fetching secret '$secret' for path '$envpath'"
  mkdir -p "$envpath"
  aws secretsmanager get-secret-value \
    --secret-id "$secret" \
    --query SecretString \
    --output text \
    | jq -r 'to_entries | .[] | "\(.key)=\(.value)"' > "$envpath/.env"
  chmod 600 "$envpath/.env"
  chown ubuntu:ubuntu "$envpath/.env"
done

if [[ ! -f "package.json" ]]; then
  echo "ERROR: package.json not found. Cannot use npm start."
  exit 2
fi
echo "Found package.json - will use npm start"

if [[ ! -d "node_modules" ]]; then
  echo "node_modules not found - installing production dependencies with npm ci --omit=dev"
  sudo -u ubuntu bash -lc "cd '$RELEASE_DIR' && npm ci --omit=dev"
else
  echo "node_modules already present - skipping npm install"
fi

sudo -u ubuntu bash -lc 'pm2 ping >/dev/null 2>&1 || true; pm2 startup systemd -u ubuntu --hp /home/ubuntu >/dev/null 2>&1 || true'

unset NODE_OPTIONS

if [[ "$HEALTHCHECK_ENABLED" == "true" ]]; then
  echo "Starting canary boot on localhost port $CANARY_PORT before replacing the live process..."
  if [[ -z "$CANARY_COMMAND" ]]; then
    CANARY_COMMAND="npm start"
  fi
  echo "Canary command: $CANARY_COMMAND"

  setsid sudo -u ubuntu bash -lc \
    "cd '$RELEASE_DIR' && export PORT='$CANARY_PORT' APPLICATION_PORT='$CANARY_PORT' NODE_ENV=production; $CANARY_COMMAND" \
    > "$CANARY_LOG" 2>&1 &
  CANARY_PID=$!

  if ! wait_for_http "$CANARY_PORT" "Canary"; then
    if ! kill -0 "$CANARY_PID" >/dev/null 2>&1; then
      echo "ERROR: canary process exited before becoming healthy."
    else
      echo "ERROR: canary did not become healthy."
    fi
    tail -n 200 "$CANARY_LOG" || true
    exit 1
  fi

  echo "Canary boot is healthy."
  kill_canary
fi

echo "Switching release into place."
stop_pm2
rm -rf "$BACKUP_DIR"
if [[ -d "$APP_DIR" ]]; then
  mv "$APP_DIR" "$BACKUP_DIR"
fi
mv "$RELEASE_DIR" "$APP_DIR"
chown -R ubuntu:ubuntu "$APP_DIR"

echo "Starting application via PM2 (npm start) with APPLICATION_PORT=$APPLICATION_PORT"
if ! start_pm2 "$APP_DIR"; then
  echo "ERROR: PM2 start failed."
  rollback_previous_release || true
  exit 1
fi

if [[ "$HEALTHCHECK_ENABLED" == "true" ]]; then
  if ! wait_for_http "$APPLICATION_PORT" "Live"; then
    echo "ERROR: live process did not become healthy after switch."
    sudo -u ubuntu pm2 logs "$PROCESS_NAME" --lines 200 --nostream || true
    rollback_previous_release || true
    exit 1
  fi
fi

rm -rf "$BACKUP_DIR"

echo "Deployment completed successfully!"
