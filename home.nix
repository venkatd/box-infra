{ pkgs, ... }:

{
  imports = [ ./modules/tailscale-userspace.nix ];

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
