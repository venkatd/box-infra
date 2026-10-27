# Box infra (Nix + home-manager)

Everything installed for user `box` through Nix is defined here, in one flake:

- `flake.nix` – pins nixpkgs (unstable) and home-manager (master); exposes `homeConfigurations.box`.
- `flake.lock` – the exact versions in use. Committing it = reproducible.
- `home.nix` – the actual config: package list, direnv, etc.

Nix is installed **single-user** (no daemon, no systemd needed); `/nix` is owned by `box`.
System tools in `/usr/bin`, `/usr/local/bin` are untouched. Nix tools come first on `PATH`
in shells that source the Nix profile (so e.g. `gh`/`git` resolve to the Nix versions there).

## Add (or remove) a package

1. Find the name: `nix search nixpkgs <name>`
2. Add it to `home.packages` in `home.nix`.
3. Apply (below), then commit: `git commit -am "add <name>"`.

Try something without installing it: `nix shell nixpkgs#<name>` or `nix run nixpkgs#<name>`.

## Apply

```sh
home-manager switch -b backup --flake /home/box/infra#box
```

If `home-manager` isn't on PATH (fresh machine / broken profile):

```sh
nix run home-manager/master -- switch -b backup --flake /home/box/infra#box
```

`-b backup` renames any existing file home-manager wants to take over to `<file>.backup`
instead of failing. Note: flakes only see files tracked by git, so `git add` new files first.

## Roll back

```sh
home-manager generations          # lists generations, newest first, with store paths
/nix/store/<hash>-home-manager-generation/activate   # activate an older one
```

Or roll back the config itself with git (`git revert` / `git checkout <rev> -- home.nix`) and switch again.

## Update everything

```sh
cd /home/box/infra
nix flake update                  # bumps nixpkgs + home-manager in flake.lock
home-manager switch -b backup --flake .#box
git commit -am "flake update"
```

If an update breaks something: `git checkout HEAD~1 -- flake.lock` and switch again.

## Garbage-collect (free disk)

```sh
home-manager expire-generations "-30 days"   # drop old home-manager generations
nix-collect-garbage -d                       # delete old profile generations + unused store paths
du -sh /nix                                  # check
```

After `-d` you can no longer roll back to the deleted generations.

## Shell integration

Not managed by home-manager on purpose (`programs.bash.enable = false`, shared machine).
- `~/.profile`: one line added by the Nix installer that sources `~/.nix-profile/etc/profile.d/nix.sh`.
- `~/.bashrc`: a marked block `# >>> nix / home-manager >>>` that sources nix.sh (if not already on PATH),
  `hm-session-vars.sh`, and the direnv hook for interactive shells.
Pre-Nix copies: `~/.profile.pre-nix`, `~/.bashrc.pre-nix`.

## direnv

In a project: `echo "use flake" > .envrc && direnv allow` (nix-direnv caches the dev shell).


## Tailscale (userspace, no systemd)

Declared in [`modules/tailscale-userspace.nix`](modules/tailscale-userspace.nix)
(imported from `home.nix`), not as ad-hoc startup lines in the flake.

This box has no systemd (PID 1 is `tini`). Tailscale runs in userspace mode:

- `ensure-tailscale` — idempotent start of `tailscaled --tun=userspace-networking`
  with a **localhost-only** SOCKS5/HTTP proxy on `127.0.0.1:1055`
- `ts-run <cmd…>` — one command with `ALL_PROXY=socks5h://127.0.0.1:1055`
  (never export proxies globally). Prefer MagicDNS **FQDNs**
  (`host.tail….ts.net`); short names break Serve TLS, and this box’s
  system DNS maps `*.ts.net` to a fake `198.18.0.1`.
- `t3 [path] [curl args…]` — curl Venkat-MBP Tailscale Serve → local T3
  (default `T3_SERVE_URL=https://venkat-mbp.taila781d4.ts.net`)
- State: `~/.local/state/tailscale/`
- Shell hook: interactive `~/.bashrc` (nix / home-manager marked block) runs
  `ensure-tailscale ensure` in the background only

```sh
ensure-tailscale status
ensure-tailscale up                    # login URL, or --auth-key=tskey-...
t3                                     # GET Serve /  (expect 200 HTML from T3)
t3 / -o /dev/null -w '%{http_code}\n'
ts-run curl -skS https://venkat-mbp.taila781d4.ts.net/
```

Tailnet ACL must allow `pepe-box` (`100.116.189.18`) → `venkat-mbp` `tcp:443`
(MagicDNS names are not valid ACL selectors unless listed under `hosts`).

Joining the tailnet is a separate auth step. After a box recreate, re-run
`home-manager switch` from this flake and authenticate again.


## Notes

- No systemd on this box: home-manager prints "User systemd daemon not running. Skipping reload." — harmless.
  Don't enable `systemd.user.services` here; they won't run.
- `nix fmt` formats the `.nix` files (nixfmt).
