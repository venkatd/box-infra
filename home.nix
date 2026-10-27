{ pkgs, ... }:

let
  ensure-tailscale = pkgs.writeShellApplication {
    name = "ensure-tailscale";
    runtimeInputs = with pkgs; [
      tailscale
      coreutils
      util-linux # flock
      procps # pgrep
    ];
    text = ''
      # Idempotent: start userspace tailscaled if it isn't already up.
      # No systemd on this box (PID 1 is tini); join the tailnet separately
      # with: ensure-tailscale up --auth-key=tskey-...
      set -euo pipefail

      STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/tailscale"
      SOCKET="$STATE_DIR/tailscaled.sock"
      STATE="$STATE_DIR/tailscaled.state"
      LOG="$STATE_DIR/tailscaled.log"
      LOCK="$STATE_DIR/ensure.lock"
      mkdir -p "$STATE_DIR"

      # Pass-through: `ensure-tailscale up ...` / `status` / etc.
      if [[ "''${1:-}" != "" && "''${1:-}" != "ensure" ]]; then
        # Make sure the daemon is up first for CLI subcommands.
        if [[ ! -S "$SOCKET" ]] || ! tailscale --socket="$SOCKET" status >/dev/null 2>&1; then
          "$0" ensure
        fi
        exec tailscale --socket="$SOCKET" "$@"
      fi

      # Fast path: already healthy.
      if [[ -S "$SOCKET" ]] && tailscale --socket="$SOCKET" status >/dev/null 2>&1; then
        exit 0
      fi

      exec 9>"$LOCK"
      if ! flock -n 9; then
        # Another ensure is starting the daemon.
        for _ in $(seq 1 50); do
          if [[ -S "$SOCKET" ]] && tailscale --socket="$SOCKET" status >/dev/null 2>&1; then
            exit 0
          fi
          sleep 0.1
        done
        exit 0
      fi

      if ! pgrep -f "tailscaled --socket=$SOCKET" >/dev/null 2>&1; then
        nohup tailscaled \
          --tun=userspace-networking \
          --state="$STATE" \
          --socket="$SOCKET" \
          --port=0 \
          >>"$LOG" 2>&1 &
      fi

      for _ in $(seq 1 50); do
        if [[ -S "$SOCKET" ]]; then
          break
        fi
        sleep 0.1
      done
    '';
  };
in
{
  home.username = "box";
  home.homeDirectory = "/home/box";

  # Don't change this after first activation; it's not the nixpkgs version.
  home.stateVersion = "25.05";

  # Non-NixOS Linux: sets XDG_DATA_DIRS etc. for nix-installed apps.
  targets.genericLinux.enable = true;
  # No GPU use on this box; skips the mesa/driver setup check.
  targets.genericLinux.gpu.enable = false;

  # Add or remove tools here, then run `home-manager switch --flake ~/infra#box`.
  home.packages = with pkgs; [
    git
    gh
    ripgrep
    fd
    jq
    yq-go
    htop
    tmux
    nixfmt
    tailscale
    ensure-tailscale
  ];

  # direnv + nix-direnv (writes ~/.config/direnv/direnvrc).
  # The bash hook is added by hand in ~/.bashrc, because we deliberately
  # don't let home-manager own ~/.bashrc / ~/.profile (shared machine).
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Keep the shell rc files hand-managed.
  programs.bash.enable = false;

  # Let home-manager install and manage itself.
  programs.home-manager.enable = true;
}
