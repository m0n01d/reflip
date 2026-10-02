#!/bin/sh
# Keeps the brain on as a launchd agent. launchd starts it at login and
# starts it again if it exits. The agent runs its own clone of the repo,
# at origin/main, so archiving a worktree or switching the branch of the
# main checkout never touches it.
#
#   scripts/prod.sh deploy    clone or update, build, start, check, tailscale serve
#   scripts/prod.sh status    launchd state, health, deployed commit, tailnet URL
#   scripts/prod.sh logs      follow the agent's logs
#   scripts/prod.sh restart   restart the agent without a rebuild
#   scripts/prod.sh stop      stop the agent and remove it, until the next deploy
#
# Settings, each from the environment:
#   REFLIP_HOME      default ~/.reflip. It holds app/, data/ and logs/.
#   REFLIP_DATA_DIR  default $REFLIP_HOME/data. The brain gets it as DATA_DIR.
#   REFLIP_BRANCH    default main.
#   REFLIP_NODE      default: the node that asdf picks from app/.tool-versions.
#   PORT             default 8787.
set -eu

LABEL=com.m0n01d.reflip
REFLIP_HOME=${REFLIP_HOME:-$HOME/.reflip}
APP=$REFLIP_HOME/app
DATA=${REFLIP_DATA_DIR:-$REFLIP_HOME/data}
LOGS=$REFLIP_HOME/logs
BRANCH=${REFLIP_BRANCH:-main}
PORT=${PORT:-8787}
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
DOMAIN=gui/$(id -u)
TARGET=$DOMAIN/$LABEL

tailscale_cli() {
  command -v tailscale || echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
}

health() {
  curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null
}

checkout() {
  if [ -d "$APP/.git" ]; then
    if [ -n "$(git -C "$APP" status --porcelain)" ]; then
      echo "$APP has local changes. The prod clone must stay clean." >&2
      git -C "$APP" status --short >&2
      exit 1
    fi
    git -C "$APP" fetch -q origin "$BRANCH"
    git -C "$APP" checkout -q --detach "origin/$BRANCH"
  else
    mkdir -p "$REFLIP_HOME"
    git clone -q --branch "$BRANCH" "$(git -C "$(dirname "$0")" remote get-url origin)" "$APP"
  fi
  echo "app: $(git -C "$APP" log -1 --format='%h %s')"
}

resolve_node() {
  NODE=${REFLIP_NODE:-$(cd "$APP" && node -p process.execPath)}
  if ! "$NODE" -e 'require("node:sqlite")' 2>/dev/null; then
    echo "Node $("$NODE" --version) at $NODE has no node:sqlite. See .tool-versions." >&2
    exit 1
  fi
  echo "node: $("$NODE" --version) at $NODE"
}

# npm ci only when the lockfile or the node changed, so a plain deploy
# does not pull node_modules out from under the running brain.
build() {
  sum="$(shasum "$APP/package-lock.json" | cut -d' ' -f1) $NODE"
  stamp=$APP/node_modules/.reflip-deps
  (
    cd "$APP"
    PATH="$(dirname "$NODE"):$PATH"
    export PATH
    if [ "$(cat "$stamp" 2>/dev/null)" != "$sum" ]; then
      npm ci --no-audit --no-fund
      echo "$sum" >"$stamp"
    fi
    npm run build
  )
}

# The env file comes last in precedence: Node's --env-file never overrides
# a variable that is already set, so PORT and DATA_DIR here win.
write_plist() {
  mkdir -p "$DATA" "$LOGS" "$(dirname "$PLIST")"
  cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>--env-file-if-exists=$HOME/.config/reflip/env</string>
    <string>src/Main.res.mjs</string>
  </array>
  <key>WorkingDirectory</key><string>$APP</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key><string>$HOME</string>
    <key>PATH</key><string>$(dirname "$NODE"):/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>PORT</key><string>$PORT</string>
    <key>DATA_DIR</key><string>$DATA</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOGS/out.log</string>
  <key>StandardErrorPath</key><string>$LOGS/err.log</string>
</dict>
</plist>
EOF
  plutil -lint -s "$PLIST"
}

stop_agent() {
  launchctl bootout "$TARGET" 2>/dev/null || true
  i=0
  while launchctl print "$TARGET" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ $i -gt 50 ]; then
      echo "launchd did not unload $LABEL." >&2
      exit 1
    fi
    sleep 0.2
  done
}

wait_healthy() {
  i=0
  until health; do
    i=$((i + 1))
    if [ $i -gt 40 ]; then
      echo "The brain did not answer on port $PORT. The last lines of $LOGS/err.log:" >&2
      tail -n 20 "$LOGS/err.log" >&2
      exit 1
    fi
    sleep 0.5
  done
  echo "brain: up on 127.0.0.1:$PORT"
}

start_agent() {
  stop_agent
  pid=$(lsof -tnP -iTCP:"$PORT" -sTCP:LISTEN || true)
  if [ -n "$pid" ]; then
    echo "Port $PORT is taken by pid $pid: $(ps -o command= -p "$pid")" >&2
    echo "Stop that process (an npm start in a terminal?), then deploy again." >&2
    exit 1
  fi
  launchctl bootstrap "$DOMAIN" "$PLIST"
  wait_healthy
}

# tailscale serve keeps its config across restarts, so this only matters
# the first time. It is tailnet only. Never Funnel.
ensure_tailnet() {
  ts=$(tailscale_cli)
  if "$ts" serve --bg --yes "$PORT" >/dev/null 2>&1; then
    echo "tailnet: $("$ts" serve status | head -n 1)"
  else
    echo "tailnet: tailscale serve failed. Is Tailscale running?" >&2
  fi
}

status() {
  # One tab deep: the agent's own keys, not those of its nested sections.
  launchctl print "$TARGET" 2>/dev/null |
    grep -E "^$(printf '\t')(state|pid|runs|last exit code) =" || echo "agent: not loaded"
  if health; then echo "health: ok on 127.0.0.1:$PORT"; else echo "health: no answer on port $PORT"; fi
  git -C "$APP" log -1 --format='app: %h %s (%cr)' 2>/dev/null || echo "app: no clone at $APP"
  "$(tailscale_cli)" serve status
}

case "${1:-}" in
  deploy)
    checkout
    resolve_node
    build
    write_plist
    start_agent
    ensure_tailnet
    ;;
  status) status ;;
  logs) tail -n 50 -f "$LOGS/out.log" "$LOGS/err.log" ;;
  restart)
    launchctl kickstart -k "$TARGET"
    wait_healthy
    ;;
  stop)
    stop_agent
    rm -f "$PLIST"
    echo "Stopped. $LABEL stays off until the next deploy."
    ;;
  *)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
