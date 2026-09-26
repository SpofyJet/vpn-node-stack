# vpn-node-stack — architecture

This document describes **v1.4.0** (installer 1.4.0, node 1.2.0, shieldnode 1.2.0). Where the
behaviour differs from v1.3.0 (the production version whose issues are analysed in
`docs/DIAGNOSIS.md`) it is marked *v1.3.0:*.

## 1. Components

| Path | Role |
|---|---|
| `vpn-node-setup.sh` | Entry point / installer. Downloads a release tarball, validates it, unpacks it into `/opt/vpn-node-stack`, runs **shieldnode first, then node**, then a liveness post-check. Menu when run without arguments on a TTY; shortcut `/usr/local/sbin/vpn-node`; `diag` builds a redacted diagnostics archive. |
| `shieldnode/` | nftables firewall: table `inet shieldnode` — anti-abuse limits, blocklists, SSH protection, node-API restriction, IPv6 fail-safe, emergency mode, port watcher, dashboard `guard`. |
| `node/` | OS / network tuning: sysctl profiles, conntrack, BBR+fq, limits, NIC/IRQ, services hardening, the IPv6-off invariant, optional XanMod kernel. |
| `*/tests/` | Unit/integration suites (bash; some need root and use `unshare -mn` + real nft). |
| `tests/e2e/` | Lab (LXD: test node VM, Remnawave panel, client) and the acceptance runner (criteria 1–10). |
| `tools/build-release.sh` | Reproducible release archive (codeload layout) + `SHA256SUMS` + `latest`. |

Both stacks are driven by `main.sh` (`install.sh` is a thin wrapper) and share helpers
(`scrub log die warn ok require_root acquire_lock backup …`) that must stay byte-identical
(`test-shared-helpers.sh`).

## 2. Installer: download → validate → unpack → apply → verify

1. `VPN_STACK_TARBALL_URL` (default `https://codeload.github.com/SpofyJet/vpn-node-stack/tar.gz/refs/heads/main`,
   `…/tar.gz/<VPN_STACK_REF>` with `VPN_STACK_REF`, or `file:///path/vpn-node-stack-X.tar.gz`) is fetched with
   `curl -fsSL` into `$WORK_DIR/.dl.XXXX/` (same filesystem → atomic `mv`).
2. `tar -tzf` listing into a file (a truncated archive fails here); absolute paths or `..` → abort.
3. Extract with `--strip-components=1` into a temp dir; require `node/install.sh` and
   `shieldnode/install.sh`; restore exec bits; `chmod -R go-w`, `chown -R 0:0`.
4. **apply only**: `rm -rf $WORK_DIR/{node,shieldnode}` and `mv` the new trees in (no stale files);
   copy `vpn-node-setup.sh` next to them. Read-only commands use the installed copy, no network.
5. `shieldnode/install.sh apply`; if it fails on a node that had no firewall, roll it back and
   **do not run node**. Then `node/install.sh apply`.
6. Post-check: `shieldnode/main.sh verify` must pass (hooks attached, ≥10 prerouting rules,
   IPv6 fail-safe, established rule, all sets present, `protected_tcp` non-empty, the SSH
   session IP whitelisted). *v1.3.0: only "table exists".*
7. Summary: protected ports, CrowdSec, BBR/qdisc, IPv6 state, reboot prompt (XanMod or IPv6 cmdline).

Release store: `/opt/vpn-node-stack-releases/vpn-node-stack-<ver>.tar.gz` + `SHA256SUMS` + `latest`
(built by `tools/build-release.sh <git-ref>` via `git archive`: one top-level directory
`vpn-node-stack-<ver>/` with `node/ shieldnode/ vpn-node-setup.sh README.md CHANGELOG.md docs/`).
The operator's GitHub convention (`/opt/{node,shieldnode}.tar.gz`, `/opt/vpn-node-setup.sh`,
`/opt/deploy-to-github.sh`) is fed from the same commit.

## 3. shieldnode apply flow

`main.sh apply` → `shield_apply` (`firewall.sh`):

1. `shield_detect` — read-only snapshot to `/var/lib/shieldnode/diagnostics/`.
2. `shield_limits_resolve` (`limits.sh`) — config (`/etc/shieldnode/config.conf`, first-match over
   defaults, never sourced) → `SH_R_*` numbers and `SH_F_*` flags: SSH ports, protected ports
   (§4), node API port + allow-list, whitelist (SSH session IP + `TRUSTED_IPS` + `exclude.conf`).
   `SH_F_IPV6=0` always (v6 is never allowed — §6).
3. `shield_nft_build_ruleset` (`lib/nft.sh`) renders the table; `nft -c` validates it.
4. Backup of the live table (0600, rotated), carry-over of live bans, one atomic `nft -f`.
5. Self-test: sshd reachable on 127.0.0.1:<port>, table present; failure → restore backup, exit ≠0.
6. Persist: `/etc/nftables.d/shieldnode.conf` + `shieldnode.service`, `shieldnode-ports.service`,
   blocklist updater + timers + `shieldnode-blocklist-restore.service`, cleanup timer, `guard`
   symlink, contract `/etc/node-profile.d/stack.conf [shieldnode]` (incl. `ssh_ports`,
   `inbound_tcp`, `inbound_udp`, `node_api_port`).
7. Blocklist markers `.applied-*.sha256` are removed (the table was rebuilt with empty sets).
8. `shield_blocklist_kick` after the main lock is released: `--restore-last-good` (synchronous,
   local snapshots), then the network update in the background.

## 4. Port detection

`protected_tcp` / `protected_udp` = union of:

| Source | TCP | UDP |
|---|---|---|
| SSH ports | yes | — |
| **Xray inbounds** from the running core's config (`rw-core api lsi` over the abstract socket `@xtls-api-*`, via `docker exec` when the core runs in the remnanode container); ports and ranges as configured; loopback/unix listeners skipped; UDP when the inbound's network includes UDP or the transport is UDP-based (mkcp/quic/hysteria/wireguard) | yes | yes |
| Fallback without the API: TCP listeners of VPN processes; a UDP socket only if stable over two samples **and** (has a TCP twin **or** lies outside `ip_local_port_range` **or** is in `ip_local_reserved_ports`) | yes | yes |
| Node API port (`rw-node` listener, else `NODE_PORT`/`APP_PORT` of the remnanode container or `/opt/remnanode/.env`) | yes | — |
| UFW `allow`/`limit` input rules | yes | yes |
| `PROTECTED_TCP_EXTRA` / `PROTECTED_UDP_EXTRA` | yes | yes |
| keep-last-good (`protected-ports*.v2.txt`) only when no VPN core is running | yes | yes |

*v1.3.0: every unconnected UDP socket of the core was taken — the ephemeral sockets of client
UDP flows (DNS, QUIC) polluted `protected_udp` (DIAGNOSIS P0-1); detection ran only at apply.*

**Port watcher** `shieldnode-ports.service` (`main.sh ports-watch`): every 15 s a cheap
fingerprint (VPN core PIDs, non-loopback TCP listeners, mtimes of UFW files and `config.conf`);
on change — or every 30 min as a safety net — a full pass (`shield_ports_sync`): the same
resolver as apply, compare with the live sets, and if different: one nft transaction
(allow-list before port), patch the persisted ruleset (checked with `nft -c`), rewrite the
contract, `node reserve-ports`. Skipped in emergency mode or while apply holds the lock.

**Node API restriction**: `tcp dport @node_api_port ip saddr != @node_api_allow_v4 drop`, where
the allow-list = `TRUSTED_IPS` (v4) + IPv4 sources of UFW rules for that port. Empty allow-list →
the port set stays empty (panel not cut off) and health warns.

node's `ip_local_reserved_ports` = inbound ports from the contract that fall into
`ip_local_port_range` (+ `TCP_RESERVED_PORTS`), fallback: TCP listeners. *v1.3.0: all sockets
listening in [10240, 32767] at apply time, including ephemeral UDP.*

## 5. nft layout (`table inet shieldnode`)

| Chain | Hook / priority | Policy | Purpose |
|---|---|---|---|
| `prerouting` | `filter hook prerouting priority mangle` | accept | everything below |
| `v6_output` | `filter hook output priority mangle` | accept | IPv4 accept, `oif lo accept`, then **drop all IPv6** |
| `v6_forward` | `filter hook forward priority mangle` | accept | drop all IPv6 |

Order inside `prerouting` (first match wins):

1. `meta nfproto ipv6 drop` (counter `c_drops_ipv6_failsafe`).
2. `ct state established,related accept` — replies to the node's own traffic are never limited.
3. `iif "lo" accept`.
4. Node API: `tcp dport @node_api_port ip saddr != @node_api_allow_v4 drop` (`c_drops_nodeapi`).
5. Whitelist → accept.
6. Blocklists (`scanner threat spamhaus cins crowdsec custom tor`) → drop.
7. Anti-spoof (opt-in), amplification guard, `ct state invalid` drop.
8. SSH: per-source new-connection rate + connection limit → `ssh_abusers`.
9. `tcp dport @protected_tcp`: SYN rate, new-conn rate, conn limit → `tcp_abusers`; global SYN ceiling.
10. `udp dport @protected_udp`: per-source pps → `udp_abusers`; global ceiling.

**Security model: shieldnode has no default-drop.** It rate-limits and blocklists traffic to
protected ports, drops known-bad sources, all IPv6 and non-allowed access to the node API;
whether any other port is reachable is decided by **UFW** (default deny).

Emergency mode replaces the table with: loopback, IPv6 drop, established, whitelist, SSH only.

## 6. IPv6 (invariant, never rolled back)

| Layer | Owner | Mechanism |
|---|---|---|
| kernel | node `lib/ipv6.sh` | `ipv6.disable=1` via `/etc/default/grub.d/99-vpn-node-ipv6.cfg` + `update-grub` (active after reboot) |
| sysctl | node | `/etc/sysctl.d/99-zz-vpn-ipv6-off.conf`: all/default/lo + every interface; runtime write to every `disable_ipv6` |
| networkd | node | drop-in `90-vpn-node-ipv6-off.conf` (`LinkLocalAddressing=no`, `IPv6AcceptRA=no`) for each `.network` (networkd re-enabled IPv6 on the uplink after reboot — DIAGNOSIS E6) |
| Docker | node | `/etc/docker/daemon.json` `"ipv6": false` (JSON merge, no restart) |
| firewall | shieldnode | IPv6 drop in prerouting/output/forward and in emergency mode |
| health | shieldnode | FAIL on a global v6 address or a v6-enabled interface; WARN until the cmdline is active |

These files are not in node's manifest; `disable_ipv6` keys are excluded from the rollback
registry. `HARDEN_IPV6=0` is ignored with a warning.

## 7. node apply flow

`apply.sh` steps (each isolated by `node_step_run`, errexit preserved): sysctl plan by RAM tier
(`99-z0..z4-node-*.conf`), conntrack, `sysctl -p` of node files only, restore of keys dropped
from the plan, the IPv6 invariant, services hardening, storage, FD limits (drop-ins only for
units whose `ExecStart` runs xray/remnanode), NIC/IRQ (opt-in parts), CPU governor, MSS clamp
(opt-in), fq tuning (re-handles a default `mq 0:` root so the fq children are addressable),
XanMod (**opt-in**, `ENABLE_XANMOD=0`), logrotate, `node-rt-tweaks.service`, contract.
Every change is recorded (sysctl-orig.tsv, runtime-tweaks.tsv, services-state.tsv, manifest)
so `rollback` restores the pre-node state — except the IPv6 invariant.

## 8. systemd units and boot order

| Unit | Ordering | Runs |
|---|---|---|
| `shieldnode.service` | `DefaultDependencies=no`, `After=local-fs.target systemd-modules-load.service nftables.service`, `Before=network-pre.target docker.service shutdown.target`, `Wants=network-pre.target` | `nft -f /etc/nftables.d/shieldnode.conf` |
| `shieldnode-blocklist-restore.service` | `After=shieldnode.service`, wanted by it | fill empty blocklist sets from last-good snapshots (no network) |
| `shieldnode-ports.service` | `After=shieldnode.service docker.service`, `Restart=always` | port watcher (§4) |
| `shieldnode-blocklist.timer` | `OnBootSec=3min`, every 360 min | updater (all feeds) |
| `shieldnode-blocklist-crowdsec.timer` | `OnBootSec=5min`, every 30 min (agent mode) | updater `crowdsec` |
| `shieldnode-blocklist-custom.path` | change of `/etc/shieldnode/lists/custom.txt` | updater `custom` |
| `shieldnode-cleanup.timer` | every 15 min | abuse journal cleanup |
| `node-fq-tune.service`, `node-rt-tweaks.service` | network-pre / network-online | fq params, runtime tweaks |
| `docker.service` | after network-online | remnanode (`restart: always`) |
| `ufw.service` | `Before=network-pre.target` | UFW rules |

Measured on the lab (DIAGNOSIS P0-2): shieldnode active at 18.9 s, UFW 19.5 s, networkd 23.6 s,
sshd 29 s, Docker later. *v1.3.0: shieldnode 26.5–27.7 s, after the NIC was up.*

## 9. Health, verify, guard

* `shield_health` (`status.sh`) — PASS/WARN/FAIL: rule order, IPv6 fail-safe and host IPv6 state,
  node API restriction, SSH rules and listener, SSH session IP whitelisted, conntrack fill,
  inbounds vs `protected_*` (same detector as apply), UFW ports, blocklists (presence, fill,
  freshness, alerts, CrowdSec "waiting"), timers/services.
* `shield_verify` (`lib/ports.sh`) — structural liveness (used by the installer post-check).
* `guard` — Russian dashboard; its "problems" section is exactly health's FAIL/WARN + verify's ✘.

## 10. Files and state

| Path | Content |
|---|---|
| `/etc/shieldnode/config.conf`, `exclude.conf`, `lists/custom.txt` | operator config (kept on uninstall) |
| `/etc/node/node.conf` | operator config |
| `/var/lib/shieldnode/` | backups (0700), blocklist state (`last-good-*`, `status-*`, `cs-restarts`), abuse journal, `protected-ports*.v2.txt` |
| `/var/lib/node/` | sysctl-orig.tsv, owner-keys, runtime-tweaks, services-state, manifests |
| `/etc/node-profile.d/stack.conf` | contract between the stacks |
| `/etc/sysctl.d/99-zz-vpn-ipv6-off.conf`, `/etc/default/grub.d/99-vpn-node-ipv6.cfg` | IPv6 invariant |
| `/var/log/{shieldnode,node,vpn-node-setup}.log` | logs (0640, secrets scrubbed) |
