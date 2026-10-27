{ pkgs, ... }:

# Userspace Tailscale for the Grok Bot box (no systemd / no /dev/net/tun).
# - ensure-tailscale: idempotent daemon start (SOCKS5 + HTTP proxy on 127.0.0.1:1055)
# - ts-run: run ONE command with ALL_PROXY/HTTP(S)_PROXY set (never export globally)
# Join the tailnet separately: ensure-tailscale up  (login URL or --auth-key=...)
let
  socksAddr = "127.0.0.1:1055";
  socksUrl = "socks5h://${socksAddr}";
  httpProxyUrl = "http://${socksAddr}";

  ensure-tailscale = pkgs.writeShellApplication {
    name = "ensure-tailscale";
    runtimeInputs = with pkgs; [
      tailscale
      coreutils
      util-linux # flock
      procps # pgrep
    ];
    text = ''
      set -euo pipefail

      STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/tailscale"
      SOCKET="$STATE_DIR/tailscaled.sock"
      STATE="$STATE_DIR/tailscaled.state"
      LOG="$STATE_DIR/tailscaled.log"
      LOCK="$STATE_DIR/ensure.lock"
      SOCKS="${socksAddr}"
      mkdir -p "$STATE_DIR"

      start_daemon() {
        if pgrep -f "tailscaled --socket=$SOCKET" >/dev/null 2>&1; then
          return 0
        fi
        nohup tailscaled \
          --tun=userspace-networking \
          --state="$STATE" \
          --socket="$SOCKET" \
          --port=0 \
          --socks5-server="$SOCKS" \
          --outbound-http-proxy-listen="$SOCKS" \
          >>"$LOG" 2>&1 &
        for _ in $(seq 1 50); do
          if [[ -S "$SOCKET" ]]; then
            break
          fi
          sleep 0.1
        done
      }

      # Pass-through CLI: ensure-tailscale status|up|ping|...
      if [[ "''${1:-}" != "" && "''${1:-}" != "ensure" ]]; then
        if [[ ! -S "$SOCKET" ]] || ! tailscale --socket="$SOCKET" status >/dev/null 2>&1; then
          "$0" ensure
        fi
        exec tailscale --socket="$SOCKET" "$@"
      fi

      # Fast path: daemon up and SOCKS listening.
      if [[ -S "$SOCKET" ]] && tailscale --socket="$SOCKET" status >/dev/null 2>&1; then
        if (echo >/dev/tcp/127.0.0.1/1055) >/dev/null 2>&1; then
          exit 0
        fi
        # Status ok but SOCKS missing (old daemon): restart with SOCKS flags.
        pkill -f "tailscaled --socket=$SOCKET" >/dev/null 2>&1 || true
        sleep 0.3
      fi

      exec 9>"$LOCK"
      if ! flock -n 9; then
        for _ in $(seq 1 50); do
          if [[ -S "$SOCKET" ]] && tailscale --socket="$SOCKET" status >/dev/null 2>&1; then
            exit 0
          fi
          sleep 0.1
        done
        exit 0
      fi

      start_daemon
    '';
  };

  # Per-command proxy only — do not put these in sessionVariables / bashrc.
  ts-run = pkgs.writeShellApplication {
    name = "ts-run";
    runtimeInputs = [
      ensure-tailscale
      pkgs.coreutils
    ];
    text = ''
      set -euo pipefail
      if [[ "$#" -lt 1 ]]; then
        echo "usage: ts-run <command> [args...]" >&2
        echo "Runs a command with Tailscale userspace SOCKS/HTTP proxies set." >&2
        exit 2
      fi
      ensure-tailscale ensure
      # SOCKS5 only. Do not set HTTP(S)_PROXY: curl prefers those and uses
      # HTTP CONNECT, which hangs against Tailscale's userspace HTTP proxy.
      export ALL_PROXY="${socksUrl}"
      unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy || true
      export NO_PROXY="localhost,127.0.0.1,::1"
      export no_proxy="$NO_PROXY"
      exec "$@"
    '';
  };
in
{
  home.packages = [
    pkgs.tailscale
    ensure-tailscale
    ts-run
  ];
}
