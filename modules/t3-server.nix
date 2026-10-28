{ pkgs, ... }:

# Real T3 Code on the box, as the *linking side* of Linked environments
# (pepe-box → Venkat MBP, pepe-box → agent-forge over Tailscale).
#
# - The `t3` CLI itself is NOT a nix package: it is T3's self-updating release
#   build in ~/.t3/runtime/versions/<v>, symlinked at ~/.local/bin/t3
#   (installed by ensure-t3 via https://t3.codes/install.sh, nightly channel).
# - ensure-t3: idempotent, flock'd, no systemd (PID1 is tini). Starts
#   `t3 serve` on 127.0.0.1:3773 with outbound traffic through the userspace
#   Tailscale proxy, so linked-environment dials to *.ts.net work.
#   The t3 binary is a Node SEA: it ignores ALL_PROXY/SOCKS, and only honours
#   HTTP(S)_PROXY when NODE_USE_ENV_PROXY=1. So we set NODE_USE_ENV_PROXY=1 +
#   HTTP(S)_PROXY -> tailscaled's --outbound-http-proxy-listen (CONNECT), and
#   ALL_PROXY=socks5h for child tools (curl, git) that prefer SOCKS.
#   Non-tailnet destinations pass straight through tailscaled to the internet.
# - t3-tailnet: run any `t3 ...` CLI command with that same proxy env (needed
#   for `t3 environment link|list`, which dial peers from the CLI process).
# - Also forces Labs `linkedEnvironmentsEnabled: true` in ~/.t3/userdata/settings.json.
#
# Usage: ensure-t3 [ensure|restart|stop|status|log]
let
  proxyAddr = "127.0.0.1:1055"; # from tailscale-userspace.nix
  port = "3773";

  ensure-t3 = pkgs.writeShellApplication {
    name = "ensure-t3";
    runtimeInputs = with pkgs; [
      coreutils
      util-linux # flock
      procps # pgrep/pkill
      curl
      jq
      gnugrep
      gnused
    ];
    text = ''
      set -euo pipefail

      T3_HOME="''${T3CODE_HOME:-$HOME/.t3}"
      BIN="$HOME/.local/bin/t3"
      STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/t3"
      LOG="$STATE_DIR/serve.log"
      LOCK="$STATE_DIR/ensure.lock"
      PORT="''${T3_PORT:-${port}}"
      SETTINGS="$T3_HOME/userdata/settings.json"
      mkdir -p "$STATE_DIR" "$T3_HOME/userdata"

      healthy() {
        curl -fsS -m 3 -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null
      }

      server_pids() {
        pgrep -u "$(id -u)" -f "t3 serve --host 127.0.0.1 --port $PORT" || true
      }

      install_t3() {
        [[ -x "$BIN" ]] && return 0
        # GitHub's anonymous API is often rate-limited from the box; resolve the
        # newest nightly from the releases Atom feed and pin it explicitly.
        ver="''${T3CODE_VERSION:-}"
        if [[ -z "$ver" ]]; then
          ver="$(curl -fsSL https://github.com/pingdotgg/t3code/releases.atom \
            | grep -o '[0-9][0-9.]*-nightly\.[0-9]*\.[0-9]*' | head -n1 || true)"
        fi
        if [[ -n "$ver" ]]; then
          curl -fsSL https://t3.codes/install.sh | T3CODE_VERSION="$ver" sh
        else
          curl -fsSL https://t3.codes/install.sh | T3CODE_CHANNEL=nightly sh
        fi
      }

      ensure_settings() {
        if [[ -s "$SETTINGS" ]] && jq -e '.linkedEnvironmentsEnabled == true' "$SETTINGS" >/dev/null 2>&1; then
          return 0
        fi
        tmp="$(mktemp "$SETTINGS.XXXX")"
        if [[ -s "$SETTINGS" ]] && jq . "$SETTINGS" >/dev/null 2>&1; then
          jq '.linkedEnvironmentsEnabled = true' "$SETTINGS" >"$tmp"
        else
          echo '{"linkedEnvironmentsEnabled": true}' | jq . >"$tmp"
        fi
        mv "$tmp" "$SETTINGS"
      }

      start_server() {
        ensure-tailscale ensure || true
        (
          cd "$HOME"
          export NODE_USE_ENV_PROXY=1
          export HTTPS_PROXY="http://${proxyAddr}" HTTP_PROXY="http://${proxyAddr}"
          export https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY"
          export ALL_PROXY="socks5h://${proxyAddr}"
          export NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1"
          export PATH="$HOME/.local/bin:$PATH"
          nohup "$BIN" serve --host 127.0.0.1 --port "$PORT" --no-browser \
            >>"$LOG" 2>&1 </dev/null 9>&- &
        )
        for _ in $(seq 1 100); do
          healthy && return 0
          sleep 0.2
        done
        echo "ensure-t3: server did not come up; see $LOG" >&2
        return 1
      }

      stop_server() {
        pids="$(server_pids)"
        [[ -z "$pids" ]] && return 0
        # shellcheck disable=SC2086
        kill $pids 2>/dev/null || true
        for _ in $(seq 1 50); do
          [[ -z "$(server_pids)" ]] && return 0
          sleep 0.1
        done
        # shellcheck disable=SC2086
        kill -9 $pids 2>/dev/null || true
      }

      cmd="''${1:-ensure}"
      case "$cmd" in
        status)
          if healthy; then echo "t3 serve: up on 127.0.0.1:$PORT (pids: $(server_pids | tr '\n' ' '))"; else echo "t3 serve: down"; exit 1; fi
          exit 0 ;;
        log) exec tail -n "''${2:-80}" "$LOG" ;;
        stop) exec 9>"$LOCK"; flock 9; stop_server; exit 0 ;;
        restart) exec 9>"$LOCK"; flock 9; stop_server; install_t3; ensure_settings; start_server; exit $? ;;
        ensure) ;;
        *) echo "usage: ensure-t3 [ensure|restart|stop|status|log [n]]" >&2; exit 2 ;;
      esac

      # Fast path.
      if healthy && [[ -s "$SETTINGS" ]] && [[ -x "$BIN" ]]; then
        exit 0
      fi

      exec 9>"$LOCK"
      if ! flock -n 9; then
        exit 0 # another ensure is starting it
      fi
      install_t3
      ensure_settings
      healthy || start_server
    '';
  };

  t3-tailnet = pkgs.writeShellApplication {
    name = "t3-tailnet";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail
      ensure-tailscale ensure || true
      export NODE_USE_ENV_PROXY=1
      export HTTPS_PROXY="http://${proxyAddr}" HTTP_PROXY="http://${proxyAddr}"
      export https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY"
      export ALL_PROXY="socks5h://${proxyAddr}"
      export NO_PROXY="localhost,127.0.0.1,::1" no_proxy="localhost,127.0.0.1,::1"
      exec "$HOME/.local/bin/t3" "$@"
    '';
  };
in
{
  home.packages = [
    ensure-t3
    t3-tailnet
  ];

  # Real `t3` (~/.local/bin) on PATH ahead of the nix profile.
  home.sessionPath = [ "$HOME/.local/bin" ];
}
