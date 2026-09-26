# Diagnosis — production issues E1–E8 (v1.3.0) and fixes in v1.4.0

All proofs below come from the lab (never from the production node). Commands are run on the
test node `node1` unless stated otherwise. Severity: **P0** — protection wrong or missing,
**P1** — wrong/misleading behaviour with security or reliability impact, **P2** — cosmetic.

## 0. Lab

Built on the work machine with LXD (the only infrastructure available: no provider API or
SSH keys to other servers; the machine has `/dev/kvm`, nested virtualization works):

| Machine | What | Why |
|---|---|---|
| `node1` | **KVM VM** Ubuntu 24.04, stock kernel `6.8.0-139-generic`, 1 vCPU / 1 GiB, Docker 29, UFW with the ports from E3 (`22 80 443 6443 7441 7443 8443 9999/tcp`, `2222/tcp` only from the panel, `8388` tcp+udp), remnanode `latest` (official compose: host network, `NODE_PORT=2222`, `ulimits nofile 1048576`) | real kernel, sysctl, boot order, reboots, GRUB |
| `panel` | LXD container, Remnawave panel (official `docker-compose-prod.yml`, backend 3.x) | real panel ↔ node link; inbounds are configured through the panel API |
| `client` | LXD container, Xray-core 26.3 client | real traffic: VLESS+REALITY (TCP 443, `xtls-rprx-vision`), Shadowsocks TCP+UDP (8388); UDP forwards for DNS (1.1.1.1/8.8.8.8) and QUIC (cloudflare-quic.com, www.google.com via static curl with HTTP/3); iperf3 |

Inbounds (panel profile `lab-profile`): `VLESS_REALITY` TCP 443, `SS_UDP` TCP+UDP 8388.
Reproducible: `tests/e2e/lab/lab.sh node-create` rebuilds a production-like node from scratch
(`tests/e2e/lab/provision-node.sh`); snapshots on a btrfs pool: `clean-remnanode` (no stack),
`prod-v1.3.0` (v1.3.0 installed through its own installer from
`/opt/vpn-node-stack-releases/vpn-node-stack-1.3.0.tar.gz`, built from `f045bc0` = GitHub `main`).

Lab limits (stated honestly): one physical vCPU shared by host, VM and containers — absolute
throughput numbers are CPU-bound and only comparisons *in the same lab* are meaningful; no real
provider RA/DHCPv6 on the lab bridge.

---

## P0-1 — UDP port detection captures ephemeral sockets (E1, E2) · **P0**

**Symptom.** apply logged ~35 random UDP ports as protected; minutes later health reported a
*different* set of "unprotected" UDP listeners; health never settles.

**Root cause.** `shield_detect_vpn_listen udp` takes **every** `UNCONN` UDP socket owned by
`xray|rw-core|…` (`ss -ulnp`). Xray's `freedom` outbound opens an *unconnected, wildcard-bound*
UDP socket per client UDP flow (DNS, QUIC, …) on an ephemeral port. In `ss` these are
indistinguishable from a real inbound (`*:8388`). node widens `ip_local_port_range` to
`10240 65535`, so they spread over almost the whole port space.

**Proof.** After one burst of client DNS + QUIC through the node (v1.3.0):
```
$ ss -ulnpH | grep rw-core | awk '{print $4}'
*:8388 *:10509 *:11960 *:12178 … *:64268        # count: 90 — one real inbound, 89 ephemeral
$ ss -uapnH | grep rw-core | grep -vc UNCONN
0                                                # all of them look like "listeners"
$ grep 'limits: resolved' /var/log/shieldnode.log          # re-apply under traffic
… udp=[8388 10509 12178 12710 13768 13954 … ]              # ~70 ephemeral ports protected
$ bash install.sh status                                    # 2 minutes later
[WARN] xray/remnanode слушает 12457/udp снаружи, но порта нет в protected_udp … (×30, other ports)
health: FAIL=0 WARN=34 PASS=16
```

**Consequences, checked with counters (hypothesis partly wrong).** The hypothesis that replies
to the node's own outbound traffic get rate-limited or banned is **not confirmed**:
`ct state established,related accept` is rule #4 of `prerouting`, before every limit
(rule #33 is the UDP per-source limit), so replies never reach the limits. After 20 rounds of
QUIC to Cloudflare/Google + DNS through the node: `c_drops_udp_abusers_v4 = 0`,
`udp_abusers = {}`. The real damage is: polluted `protected_udp`, permanently flapping health,
and — separately — node's `ip_local_reserved_ports` (v1.1.7) reserving whatever ephemeral
ports happened to be listening at apply time.

**Source of truth found.** remnanode runs Xray's gRPC API on an abstract unix socket in the
host network namespace (`@xtls-api-<random>`), and `rw-core` ships `api lsi`:
```
$ docker exec remnanode rw-core api lsi --server=unix:@xtls-api-wfMKmxWKF7
VLESS_REALITY  portList 443   listen 0.0.0.0
SS_UDP         portList 8388  listen 0.0.0.0  network [TCP, UDP]
REMNAWAVE_API_INBOUND  listen @xtls-api-…   (internal, ignored)
```
(The output contains users; the detector parses tag/port/listen/network in memory and
discards the rest — nothing of it is logged.)

**Decision (v1.4.0).**
1. Inbound ports come from the **running Xray config via its API** (`rw-core api lsi` in the
   container that owns the `@xtls-api-*` socket). Transport per inbound: `network` list of the
   proxy (shadowsocks/dokodemo), stream protocol (`kcp/quic/hysteria` → UDP), protocol type
   (`hysteria/wireguard` → UDP), otherwise TCP. Loopback/unix listeners are ignored.
2. If the API is not available (not remnanode, API disabled): multi-signal fallback — TCP
   listeners of the core are taken as is; a UDP socket counts only if it is wildcard-bound,
   seen in two samples 3 s apart **and** (has a TCP listener of the core on the same port **or**
   is outside `ip_local_port_range` **or** is in `ip_local_reserved_ports` **or** is configured
   manually).
3. The remnanode API port is read from the `rw-node` listener, else `NODE_PORT`/`APP_PORT` of
   the remnanode container/.env.
4. node reserves the **real** inbound ports + node API port in
   `net.ipv4.ip_local_reserved_ports` (no more "whatever listened at apply time"); recomputed on
   every change (P0-2 sync).
5. Health compares sets with the same detector — ephemeral sockets are never "unprotected
   listeners".

## P0-2 — exposure windows: "node runs without firewall" (E3, E8) · **P0**

**What E8 turned out to be.** The table *is* loaded at boot (proof below); "unprotected" is the
sum of: ports detected only at apply time (E3/E1), blocklists silently empty after every apply
(P1-3 custom), an empty CrowdSec set (P1-3), and the remnanode API port open to the world.

**E3 — UFW-open ports missing from `protected_*`.** In the lab, v1.3.0 imports UFW ports
correctly *if UFW is enabled and the rules exist at apply time*:
`tcp=[22 80 443 2222 6443 7441 7443 8388 8443 9999] udp=[8388]`. Production's apply log
(`tcp=[22 443]`) means UFW had no matching rules / was not enabled at that moment; health later
read the rules that exist now. **Root cause: detection runs only when someone runs apply**; there
is no re-detection when UFW, remnanode or the panel's inbounds change.

**Boot order (v1.3.0), monotonic seconds, `journalctl -b -o short-monotonic`:**
```
17.0  Starting ufw.service      18.5 Finished ufw.service          (UFW default-deny active)
22.8  Reached target network-pre.target
22.9  enp5s0: Configuring … / Gained carrier
26.5  Starting shieldnode.service   27.7 Finished shieldnode.service
29.7  Starting ssh.service      ~45–57 docker, remnanode container (StartedAt 14:35:06Z)
```
The interface is up ~4.7 s before the shieldnode table is loaded (`After=network-pre.target`
only). Practical exposure in that window is nil — UFW already denies by default and no service
listens yet — but the ordering is wrong: shieldnode must be loaded **before** the network.
`nftables.service` is disabled on Ubuntu, but its `/etc/nftables.conf` starts with
`flush ruleset`; if an operator ever enables it and it runs after shieldnode, the table is gone.

**Security model.** shieldnode has **no default-drop**: it limits/blocks traffic to protected
ports and drops blocklisted sources; *which ports are reachable at all* is UFW's job
(default deny). This was undocumented.

**Node API port.** `2222` is served by `rw-node`; v1.3.0 does not recognise the process at all
(regex `xray|rw-core|remnanode|…`), it is protected only through the UFW import, and never
restricted to the panel by shieldnode.

**Decision (v1.4.0).**
1. `shieldnode-ports.timer` (every 20 s, from 30 s after boot) runs `ports-sync`: recompute
   SSH + inbounds (API) + UFW + manual ports; if they differ from the live sets → update the
   sets atomically (`nft -f` transaction), patch the persisted ruleset, update node's reserved
   ports. A new inbound is protected within ~20–40 s without anyone pressing apply. If the core
   is not running, the last known ports are kept.
2. `shieldnode.service`: `DefaultDependencies=no`, `After=local-fs.target systemd-modules-load.service nftables.service`,
   `Before=network-pre.target docker.service`, `Wants=network-pre.target` → table loaded before
   any interface is configured and never wiped by a later `nftables.service`.
3. Node API port restricted to the panel: dropped for every source except `TRUSTED_IPS` and
   sources the operator allowed for that port in UFW (`ufw allow from X to any port 2222`).
   If none are known, it stays open and health/guard **warn loudly** with the exact fix.
4. UFW-open ports without any listener are reported (health WARN with the `ufw delete` command);
   health FAILs if UFW is inactive while public ports are open.
5. Liveness check `shieldnode verify` (used by the installer post-check, health and guard):
   table present, both hooks attached, rule counts, required sets, IPv6 fail-safe present,
   whitelist contains the current SSH client.

## P1-3 — health, guard and blocklists (E4, E5) · **P1**

**Custom list empty after every apply.** apply rebuilds the table with *empty* blocklist sets;
the updater's hash guard (`.applied-custom.sha256`: "same content → do not touch nft") then
skips the unchanged list. Proof (v1.3.0, re-apply at 14:28):
```
custom_blocklist_v4 0          # snapshot last-good-custom.txt holds 1845 entries
cins_blocklist_v4   11624      # cins has no hash guard → reloaded
log: last "custom: updated …" at 14:22 (before the re-apply), nothing after it
```
→ the operator's own list is **not enforced** after any apply until the upstream file changes.
Fix: apply invalidates the hash markers, and the guard additionally requires the live set to be
non-empty.

**CrowdSec "set empty / no successful updates".** Two causes:
* A newly registered machine receives **0** community entries on its first CAPI pull
  (`capi/community-blocklist : received 0 new entries (expected if you just installed crowdsec)`);
  the next pull is ~2 h later. After a daemon restart the pull returned
  `added 15000 entries`. 
* The updater reads `cscli decisions list … -o json` → `null` (4 bytes, rc 0) as a *successful*
  download with no addresses and reports `нет ни одного источника` ("no source at all"),
  bumps the failure counter and raises an alert.

Fix: `null`/empty from the local database is a valid empty list (set emptied, no failure, honest
status "waiting for the first community list"); if the machine is registered, has 0 community
decisions and the daemon has been up > 10 min, the updater restarts `crowdsec` once per hour
(at most 3 times) to trigger the pull. The apply log prints both intervals (all lists 360 min,
CrowdSec 30 min); README matches.

**guard says "no problems" while health has WARN=34 (E5).** guard had its own, much smaller
list of checks. Fix: one source of truth — guard shows the result of `shield_health`
(FAIL/WARN items) and says "no problems" only when both counts are 0.

## P1-4 — IPv6 not reliably disabled (E6) · **P1**

**Proof.** After a reboot with node v1.3.0 (`HARDEN_IPV6=1`):
```
all=1 default=1 lo=1 enp5s0=0        # net.ipv6.conf.*.disable_ipv6
inet6 fe80::216:3eff:feff:5498/64 scope link   # on enp5s0
/run/systemd/network/10-netplan-enp5s0.network: LinkLocalAddressing=ipv6
systemd-networkd: enp5s0: Gained IPv6LL
```
systemd-networkd re-enables IPv6 per link when it configures the interface (netplan's default
`LinkLocalAddressing=ipv6`); with a provider router advertisement the uplink would also get a
global address. At the same time shieldnode generates **no IPv6 rules at all** once node has
disabled IPv6 (`limits: node disabled IPv6 … v6 rules skipped`, E6) — IPv6, if it comes back,
is unfiltered by shieldnode.

**Options evaluated.**
| Method | Covers interfaces created later / networkd | Reboot | Risk |
|---|---|---|---|
| sysctl `all/default/lo` (v1.3.0) | **no** — networkd flips per-link `disable_ipv6` back | no | proven insufficient |
| sysctl + per-interface + netplan `link-local: []`/`accept-ra: false` | mostly; cloud-init may regenerate netplan | no | fragile, touches provider networking |
| kernel `ipv6.disable=1` | **yes** — no IPv6 stack at all, nothing can re-enable it | **yes** | apps that insist on AF_INET6 fail; verified below that sshd, Docker, remnanode (Node.js, Go) run fine |

**Decision (v1.4.0).** Kernel parameter `ipv6.disable=1` via
`/etc/default/grub.d/99-vpn-node-ipv6.cfg` (appended to `GRUB_CMDLINE_LINUX`, survives cloud
image drop-ins) **plus** the immediate sysctl disable on every existing interface (no reboot
needed to be protected now) **plus** a v6 drop-all fail-safe that shieldnode *always* installs
(prerouting, forward, output; counter `c_drops_ipv6_failsafe`). Docker: `"ipv6": false` merged
into `/etc/docker/daemon.json` (takes effect at the next Docker start — dockerd is never
restarted by the stack). Health FAILs on any global IPv6 address, any interface with IPv6
enabled, or a missing fail-safe. rollback never re-enables IPv6. The menu's "IPv6 on" toggle
and `HARDEN_IPV6=0` are removed (rule: IPv6 must stay disabled).

## P1-5 — optimization stack audit (E7) · **P1** (details in section "node audit" below)

**E7 — "XanMod promised, box still on 6.8".** Root cause is a bug, not a missing prompt:
the v1.1.6 "foreign XanMod source" check
```
foreign="$( { grep -rlsE '…deb\.xanmod\.org' … || true; } | grep -vxF "$XANMOD_REPO_LIST" | awk 'NR == 1')"
```
exits 1 under `pipefail` when *no* XanMod source exists (the second `grep` gets empty input)
→ `set -e` ends the step → `apply завершён с ошибками в 1 модуле(ях): xanmod_install` and the
installer prints `ОШИБКА: node завершился с ошибкой 1`. On every fresh node XanMod was never
installed. Proof (`bash -x`): the trace stops right after `foreign=`.
Decision: fix the bug; **XanMod becomes opt-in** (`ENABLE_XANMOD=0`): replacing the kernel of a
cloud VM is a boot risk (driver set, `/boot` space, GRUB of the provider image) and BBR+fq work
on the stock 6.8 kernel (proved in the audit section). When enabled, the install summary asks for
the reboot explicitly and the stock kernel stays installed as the GRUB fallback.

Why the old test did not catch E7: `test-xanmod-default.sh` called the step as
`inst … || rc=$?`, and bash disables `errexit` inside the left side of `||` — the pipefail abort
never fired in the test. The rewritten test runs every install in a separate `bash` process
(errexit active as in the real apply); with the old pipeline it fails 4 checks (negative control).

### node audit (stock 6.8.0-139, 1 vCPU / 1 GiB, tier T1)

| Area | Value / finding | Decision |
|---|---|---|
| BBR + fq on stock 6.8 | `tcp_congestion_control=bbr`, `default_qdisc=fq`, fq on every NIC queue after apply | proven — XanMod not needed for BBR |
| fq tuning | **bug found on the lab**: virtio-net multiqueue has root `mq` with the default handle `0:`; its fq children (`parent :1`) cannot be addressed — `tc qdisc change/replace` fail ("Failed to find specified qdisc"), apply warned `fq tune не применён` | fixed: re-create root `mq` with `handle 1:` (children re-created by the kernel with `default_qdisc=fq`), then tune `parent 1:N`; verified on the lab kernel |
| `ip_local_port_range` | `10240 65535` | kept; inbound ports inside the range are reserved from the shieldnode contract (P0-1) |
| conntrack | max 262144 (≤1.2 GB RAM, capped at 25 % RAM), established 4 h, time_wait 30 s, generic 300 s, UDP timeouts = kernel defaults | kept |
| socket buffers | `rmem/wmem_max` 8 MiB (Hysteria2 asks for 7 MiB), `udp_mem` T1 ceiling ≈ 349 MB | kept; memory under the 60-min traffic run is recorded in the acceptance evidence |
| perf-tier (`tcp_tw_reuse`, `fin_timeout`, `retries2`, keepalive) | opt-in only (`ENABLE_PERFORMANCE_SYSCTL=1`) | kept opt-in |
| `rp_filter`, `ip_forward` | not touched (`ip_forward=1` only when a TUN is detected; Docker sets it itself) | kept |
| FD limits | remnanode container: `nofile 1048576` from compose; node's systemd drop-ins **wrongly matched `shieldnode-ports.service`** (its Description mentions Xray) | fixed: match `ExecStart` only, stack units excluded, stale drop-ins removed |
| services | hardening list does not include time sync (systemd-timesyncd stays active) | kept |

### XanMod benchmark and XanMod-path safety (2026-09-26)

Requested by the operator: benchmark XanMod against the stock kernel and make it the default if
faster. Method: same VM, same stack, kernels alternated with `grub-reboot` (stock, XanMod, stock,
XanMod), 3 min settle after each boot, emulated user link (25 ms RTT, 0.5 % loss to the user).
Rule fixed in advance: faster = download medians ≥ +5 % and no path worse than −5 %.

| Mbit/s (mean of 2 boots) | stock 6.8.0-139 (BBR v1) | XanMod 6.18.54-x64v3 (BBRv3) |
|---|---|---|
| VLESS+REALITY, to the user | 298 (294 / 303) | 292 (259 / 325) — −2 % |
| Shadowsocks, to the user | 687 (787 / 587) | 625 (666 / 585) — −9 % |
| VLESS+REALITY, from the user | 454 | 508 — +12 % |
| Shadowsocks, from the user | 857 | 930 — +9 % |
| DNS / QUIC success | 0.99–1.00 | 0.99–1.00 |

Verdict: **no measurable advantage in the user direction** (within the ±15 % noise of this
one-CPU lab) → XanMod stays opt-in. Real multi-core hosts with real NICs may differ; the
benchmark script is `tests/e2e/lab/kernel-bench.sh`.

Installing XanMod for real on the lab (the E7 fix made the install path reachable) exposed two
bugs present since v1.1.6 but masked by E7:

| Finding | Root cause | Fix |
|---|---|---|
| node never came back after the first reboot into XanMod; serial console: `error: bad shim signature` | UEFI **Secure Boot** (LXD default, also common on cloud VMs): XanMod kernels are not signed by a trusted key; after install XanMod was the default GRUB entry → permanently unbootable without the provider console | install refused when Secure Boot is on (efivar), `/boot` free-space check (≥ 200 MB), and a **trial boot**: `GRUB_DEFAULT=saved` (grub.d), saved entry = current stock kernel, `grub-reboot` XanMod once; `node-kernel-confirm.service` makes XanMod the default only after it reached multi-user; a failed trial falls back to stock and is recorded |
| first XanMod boot: `systemd-sysctl.service` failed (`netdev_budget_usecs` 4000: Invalid argument) | the value was computed for the running kernel's HZ (1000); XanMod has HZ=250 (1 jiffy = 4000 µs < minimum 2 jiffies) | value computed for the lowest HZ among all bootable kernels (`/boot/config-*`, and HZ=250 when XanMod is requested) |

Verified on the lab VM (real GRUB/UEFI): (A) Secure Boot on → install refused, nothing changed;
(B) Secure Boot off → trial set (saved = stock, next = XanMod), XanMod booted with BBRv3,
`node-kernel-confirm` promoted it, 0 failed units; (C) trial re-armed and made to fail for real
(Secure Boot on → XanMod cannot load, machine stuck in GRUB) → a hard reset brought the node back
on the stock kernel, the failure was recorded (`/var/lib/node/xanmod-trial-failed`, shown by
`node status`), 0 failed units.

## Findings during the v1.4.0 lab deployment

Found by installing the rebuilt release on the lab node (upgrade from `prod-v1.3.0`), each fixed,
rebuilt and re-installed:

| Finding | Root cause | Fix |
|---|---|---|
| installer post-check failed: `✘ prerouting не подключена к хуку` | `shield_verify` used `nft list chains inet shieldnode`; nft 1.0.9 accepts only a family there (syntax error → empty) | read hooks from `nft -t list table`; `test-ports-sync` gets real-nft verify checks — its `vfy; vrc=$?` under `set -e` had hidden the failure |
| after reboot all six blocklists empty 2–5 min + 6 WARN | the persisted boot ruleset carries no set elements; the updater timer fires after `OnBootSec` | `shieldnode-blocklist-restore.service` (right after `shieldnode.service`) and apply fill empty sets from local last-good snapshots |
| ports watcher ~100 s CPU in 27 min | full pass every 120 s (3.8 s CPU: sshd port detection forked `tr|grep` for every process, twice) | pgrep-based sshd detection (pass ≈ 1.7 s CPU); full pass only on fingerprint change, safety pass every 30 min |
| `shieldnode-ports.service` got a node `LimitNOFILE` drop-in | see node audit | fixed |
| after apply (no reboot) the NIC stayed on `fq_codel` although the summary said "BBR + fq" | `net.core.default_qdisc=fq` only affects qdiscs created later; fq-tune only tuned qdiscs that were already fq | fq-tune switches physical NICs to fq (`mq 0:` → `mq 1:`, non-fq children → fq, single-queue root → fq); lab: `mq 1:` + `fq … limit 100000p` right after apply |
| upgrade from v1.3.0: `node-fq-tune.service` stayed `failed` (`systemctl --failed`) although fq was correct | the v1.3.0 script failed at every boot on `mq 0:` (virtio multiqueue — production nodes on such NICs are affected too); apply ran the new script directly, the unit kept the boot failure | apply runs fq tuning through the unit (`reset-failed` + `restart`); lab: `failed` → `active`, 0 failed units |
| CrowdSec list not refreshed for 3 h after an apply (health WARN «последнее успешное обновление 3ч назад»); `list-timers`: NEXT `-` | timers had only `OnBootSec` + `OnUnitActiveSec`; after apply/rollback restarted a timer both reference points were in the past and systemd does not fire monotonic timers retroactively — dead until reboot (production: after every `vpn-node apply` for the CrowdSec and cleanup timers). `enable --now` does not restart an already running timer | `OnActiveSec` on all three timers + apply does `enable` + `restart`; lab: all timers scheduled right after apply |
| apply → rollback → apply gave `netdev_budget` 600 → 1200 (e2e criterion 7, upgrade run) | AUTO_SOFTNET_TUNE doubled the budget on 32 squeezes out of 4558 packets processed since boot — a decision taken on noise, so the value flapped between applies shortly after boot | the squeeze rule needs ≥ 100 000 processed packets |
| final upgrade run, criterion 4: a new inbound was listening but not protected within 2 min | two faults together: (1) the blocklist updater held the **main** lock for its whole run, including network fetches and `cscli decisions list`, which hung for 120 s twice right after the upgrade (CrowdSec LAPI slow on 1 GB); (2) `ports-watch` skipped its pass on a busy lock but still remembered the new fingerprint, so the change was "consumed" until the 30-min safety pass | the updater takes the main lock only around nft writes; `shield_ports_sync` returns 3 on a busy lock and the watcher retries on the next tick; negative controls fail on the old code |
| after node rollback the NIC kept node's tuned fq | rollback did not touch qdiscs | rollback deletes the root qdisc of NICs carrying node's fq → kernel default (`mq 0:` + `fq_codel`) returns; verified on the lab |

Throughput methodology (criterion 6): the lab host has **one physical CPU** shared by the host,
the panel (with Postgres), the client, the iperf3 server and the node VM, so VLESS+REALITY
throughput is CPU-bound and two measurements taken at different times differ by up to ±15 %.
An A/B on the same node within minutes showed no cost of the stack: stack on 381–382 / SS
717–748 Mbit/s; CrowdSec stopped 388 / 725; shieldnode table removed 346 / 735; node rolled back
273–321 / 573–678. The first smoke run's 161 Mbit/s was measured ~2 min after a reboot while
CrowdSec and the blocklist restore were starting.

The one real difference between "stack on" and "stack off" is node's BBR + fq (off = kernel
cubic + fq_codel). Firewall held on, only CC/qdisc toggled, 3 interleaved rounds, medians, Mbit/s:

| Path | bare lab bridge (RTT < 1 ms) BBR / cubic | emulated user link (25 ms RTT, 0.5 % loss to the user) BBR / cubic |
|---|---|---|
| VLESS+REALITY, to the user | 474 / 410 (+16 %) | **567 / 61 (×9)** |
| Shadowsocks, to the user | 839 / 921 (−9 %) | **792 / 30 (×26)** |
| VLESS+REALITY, from the user | 470 / 395 (+19 %) | 491 / 414 (+19 %) |
| Shadowsocks, from the user | 894 / 953 (−6 %) | 967 / 1040 (−7 %) |

On a sub-millisecond path BBR pacing only costs CPU (visible for the light SS cipher on one
shared CPU); on a lossy client path it is the difference between a usable and an unusable
download. "From the user" measures the node sending to the lab iperf server over the bare bridge
(no loss), which is why SS loses a few percent there. Decision: keep BBR + fq. Criterion 6 is
therefore measured on the emulated user link, interleaved ON/OFF, separately for (a) the firewall
alone (BBR constant) and (b) the whole stack; the bare-bridge numbers are kept for reference.

**Cost of the firewall rules, measured in isolation** (`tests/e2e/lab/nft-cost-bench.sh`): the
end-to-end A/B through the proxy could not resolve a 5 % difference on this one-CPU host (the same
configuration varied by up to ±40 % between rounds). The real generated shieldnode ruleset was
therefore measured in two network namespaces on the host (veth, no VM, no crypto, no panel), with
the lab instances stopped, 12 alternating rounds, medians:

| Mode | TCP bulk | UDP 64-byte packets |
|---|---|---|
| no table | 23 795 Mbit/s | 37.5 kpps |
| conntrack only (what UFW/Docker already cost on every node) | −5.3 % | −0.4 % |
| shieldnode v1.4.0 rule order | −1.7 % vs conntrack only | −0.5 % vs conntrack only |
| shieldnode v1.3.0 rule order | −0.9 % vs conntrack only | +0.1 % vs conntrack only |

shieldnode's own rules cost ≤ 2 % on top of connection tracking — within noise, far under 5 %.
The v1.4.0 reordering of the hot path (IPv6 check, then established, `iif lo`, no empty `input`
hook) is **not measurably faster** than the v1.3.0 order; it is kept only because it removes a
hook that did nothing. Criterion 6 therefore has two parts: (a) this isolated rule cost on the
release's own ruleset (≤ 5 % over conntrack only), (b) the whole stack ON/OFF on the emulated
user link, judged on the download direction plus DNS/QUIC. The "from the user" direction in the
lab is the node sending to the iperf server over the bare bridge, not a user path, and is reported
for reference.

Lab-harness notes (not stack bugs): a Shadowsocks connection that stays silent from the start is
closed by Xray's handshake timeout (the SS client sends its header with the first payload) — the
idle-TCP check sends first and then idles (VLESS is not affected); remnanode restarts Xray only
when the config hash of inbounds *with users* changes, so a test inbound must be added to the
internal squad; the panel re-creates inbound records on every profile PATCH
and may disable the node ("No active inbounds found … disabling") — `panel-inbound.py` re-assigns
inbounds, enables and restarts the node; remnanode's Xray does not dial private destinations, so
iperf3/echo servers bind to the host's public address (host UFW default-deny keeps them closed
from the internet). A dead-man switch left armed during debugging fired as designed and removed
the table; SSH stayed up through UFW and the table was re-applied.

Observation (not changed): `c_drops_icmp` counts ICMP echo-requests over the per-source rate
limit (7306 on the lab during the v1.3.0 runs). The sender was not identified; no effect on
client traffic was observed (replies are accepted before any limit).

## P2-6 — cleanup

Misleading messages (apply interval line, guard "no problems", CrowdSec "no source"), dead code
(`_h_listen`, the IPv6 toggle), README/CHANGELOG — see CHANGELOG.md.

## Verification

Every fix above was verified on the lab node by installing the rebuilt release through the
installer (`VPN_STACK_TARBALL_URL=file://…`) and running `tests/e2e/run-acceptance.sh`
(criteria 1–10) for a clean install and for an upgrade from v1.3.0. Reports with per-criterion
evidence: `tests/e2e/reports/acceptance-*.md` (raw outputs in `evidence-*/`, not published).
