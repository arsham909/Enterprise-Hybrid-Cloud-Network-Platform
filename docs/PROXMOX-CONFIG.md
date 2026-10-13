# Proxmox Config — Forge Hybrid

**Device:** Dell OptiPlex Micro i5-8500 · 32 GB · 512 GB · 1 Ethernet NIC + Wi-Fi
**Role:** hypervisor; Ethernet is the tagged trunk to switch Gi1/0/1, Wi-Fi is the uplink and the out-of-band recovery path
**Status (2026-10-09):** Minimum path complete and reboot-tested. Wi-Fi uplink 10.0.0.67, bridges, NAT, forward policy drop; laptop on Gi1/0/6 reaches 10.10.10.5 with frames tagged `vlan 10` on the trunk. Open: P6 (needs OPNsense) and the deferred items. Next: `OPNSENSE-CONFIG.md`.
**Source plan:** `FORGE-HYBRID-PLAN.md` §3, §3.4, §4 · switch side: `SWITCH-CONFIG.md` · firewall: `OPNSENSE-CONFIG.md` · learning recap: `PROXMOX-NOTES.md`

Task IDs (`P2.3`) are there so a single task can be asked about by name.

---

## Minimum path (MVP)

The shortest route to a working, safe host. Do these in order; everything else in this file can wait.

| Step | Tasks | Result |
|---|---|---|
| 1 | P0.1, P0.2, P0.3 | Current state recorded, `interfaces` backed up |
| 2 | P1.3 (only the `ls /dev/kvm` check) | VMs can run |
| 3 | P2.1 → P2.6, P2.8 | Wi-Fi uplink and recovery path proven, survives a reboot |
| 4 | P3.1 → P3.7 | Target bridges live, cable moved to the switch |
| 5 | P4.1 → P4.6 | NAT for OPNsense, forward-drop so nothing routes around it |
| 6 | P5.1, P5.2, P5.5, P5.6, P5.7, P5.8, P5.10 | Gate: host reachable through the switch on VLAN 10, one default route, survives a reboot |

**Deferred, add later:** P1.2 (already satisfied if `apt update` runs clean), P1.4–P1.9, P2.7 (the `post-up` line already covers it), P4.7, P5.3, P5.4, P5.9, P7, all of the optional extras.

**Why this is secure enough for now:** the forward chain drops everything except OPNsense's own NAT traffic, the transit bridge cannot reach the Proxmox GUI, and the home LAN cannot reach lab addresses on the host. What stays open is the GUI and SSH on the home Wi-Fi behind the root password; P1.7 and P1.8 tighten that later.

---

## Starting point after a fresh install

Expected, confirm in P0: the installer made one bridge, `vmbr0`, with the Ethernet NIC as its port, a static address and a `gateway` line. Wi-Fi is not configured. The host got its updates over that cable, so it is plugged into the home router, not the switch.

That layout is the opposite of the target. In the target, `vmbr0` has no physical port, the Ethernet NIC belongs to `vmbr1`, and the only default route is Wi-Fi. Plugging the host into switch Gi1/0/1 as it is now gives no connectivity: the trunk carries only tagged VLANs 10, 20 and 30, and untagged frames land in native VLAN 99, which is not allowed on the trunk.

Order matters. Wi-Fi goes in first, while the cable still gives internet. The bridges change second, with Wi-Fi as the way back in.

## Design diagram

```text
Internet
   │
Home router (Rogers)          home LAN 10.0.0.0/24, router 10.0.0.1
   ┆ Wi-Fi
┌──┴───────────────── Proxmox host ──────────────────────┐
│ wlo1  (Wi-Fi, DHCP from home router)                 │
│    │  host ROUTES + NATs here, forward policy drop     │
│ vmbr0   192.168.250.1/30   virtual switch, no cable    │
│    │                                                   │
│  ┌─┴──────── OPNsense VM ─────────┐                    │
│  │ WAN  vtnet0  192.168.250.2/30  │                    │
│  │ LAN  vtnet1  (trunk)           │                    │
│  │   VLAN10 MGMT    10.10.10.1    │                    │
│  │   VLAN20 SERVERS 10.10.20.1    │                    │
│  │   VLAN30 USERS   10.10.30.1    │                    │
│  └─┬──────────────────────────────┘                    │
│ vmbr1   VLAN-aware virtual switch (BRIDGES, layer 2)   │
│    │        └─ vmbr1.10 = host mgmt 10.10.10.5         │
│  nic0   (Ethernet, tagged 10/20/30)                    │
└────┼───────────────────────────────────────────────────┘
     │ one cable = trunk
Cisco 3750X Gi1/0/1
     ├─ Gi1/0/6    VLAN 10  admin laptop
     ├─ Gi1/0/2–3  VLAN 20  servers
     └─ Gi1/0/4–5  VLAN 30  users
```

| | OPNsense WAN | OPNsense LAN |
|---|---|---|
| VM NIC | `net0` / `vtnet0` | `net1` / `vtnet1` |
| Proxmox bridge | `vmbr0` | `vmbr1` |
| Physical port | none, lives inside the host | `nic0` → switch Gi1/0/1 |
| Address | 192.168.250.2/30 | 10.10.10.1, 10.10.20.1, 10.10.30.1 |
| Gateway | 192.168.250.1 (the host) | none; it is the gateway |
| Carries | Everything going to the internet | Three VLANs, tagged, on one link |

**Wi-Fi side is routed, not bridged.** A Wi-Fi client link cannot be bridged into a VM: the access point accepts only the one MAC that logged in. So the host keeps the Wi-Fi address for itself, and `vmbr0` is a separate two-address network between the host and OPNsense. The host routes between `vmbr0` and Wi-Fi and NATs on the way out.

**Ethernet side is bridged.** `nic0` and the OPNsense trunk NIC are both ports of `vmbr1`. Frames pass through with their VLAN tags untouched; the host makes no routing decision there.

**Packet path, laptop on VLAN 30 opening a website:**

1. Laptop (10.10.30.x) sends to its gateway 10.10.30.1.
2. The switch tags the frame VLAN 30 and sends it up trunk Gi1/0/1.
3. `nic0` → `vmbr1` → OPNsense `vtnet1`, VLAN 30 interface.
4. OPNsense checks its rules and does NAT 1: source becomes 192.168.250.2. Out the WAN.
5. `vmbr0` → host. nftables does NAT 2: source becomes the host's Wi-Fi address. Out `wlo1`.
6. The home router does NAT 3: source becomes the Rogers public address.
7. Replies walk back the same way.

Three NATs are acceptable because home only starts connections and never receives them.

**Router-on-a-stick:** traffic between VLANs uses the one cable twice. It goes up the trunk tagged with the source VLAN, OPNsense routes it, and it comes back down the same trunk tagged with the destination VLAN. The switch only tags.

## Target design

| Interface | Purpose | Address | Notes |
|---|---|---|---|
| `wlo1` (Wi-Fi) | Uplink + out-of-band recovery | DHCP from home router (reserve it) | The host's only default route |
| `nic0` | Trunk to switch Gi1/0/1 | none | Member of `vmbr1` |
| `vmbr0` | Host ↔ OPNsense WAN transit | 192.168.250.1/30 | No physical port; NAT out the Wi-Fi |
| `vmbr1` | VLAN-aware trunk bridge | none | VLANs 10, 20, 30 only |
| `vmbr1.10` | Host management | 10.10.10.5/24 | No gateway line; static route to 10.10.0.0/16 via 10.10.10.1 |

Real names on this host, confirmed 2026-10-08: Ethernet `nic0` (already pinned by the installer), Wi-Fi `wlo1`. The installer also left a stray `iface nic1 inet manual` stanza for a NIC that does not exist; delete it in P3.2.

**Deviation from the plan:** the plan names the WAN bridge `vmbr-wan`. Proxmox bridge names must be alphanumeric (older releases only accept `vmbrN`), so a hyphen is rejected and the bridge would not show up for VM NICs. Use `vmbr0`.

---

## Reference config

### `/etc/network/interfaces`

```text
auto lo
iface lo inet loopback

# Wi-Fi: uplink + out-of-band recovery
auto wlo1
iface wlo1 inet dhcp
    post-up iw dev wlo1 set power_save off || true

# Physical NIC: trunk to switch Gi1/0/1
auto nic0
iface nic0 inet manual

# WAN transit: host <-> OPNsense WAN. No physical port.
auto vmbr0
iface vmbr0 inet static
    address 192.168.250.1/30
    bridge-ports none
    bridge-stp off
    bridge-fd 0

# Trunk bridge: tagged VLANs only
auto vmbr1
iface vmbr1 inet manual
    bridge-ports nic0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 10 20 30

# Host management on VLAN 10
auto vmbr1.10
iface vmbr1.10 inet static
    address 10.10.10.5/24
    post-up ip route add 10.10.0.0/16 via 10.10.10.1 dev vmbr1.10 || true

source /etc/network/interfaces.d/*
```

- No `wpa-ssid` / `wpa-psk` lines in this file. The Wi-Fi login is done by the `wpa_supplicant@wlo1` service below.
- No `gateway` line on any bridge. The default route comes from Wi-Fi only; the installer's `gateway` line must go, or there are two default routes.
- The static route is needed for replies to other VLANs (for example svc-01 scraping port 9100). Without it those replies leave through Wi-Fi.
- Keep the `source` line if the installer wrote one.

**Wi-Fi login runs as its own service (required, found 2026-10-08).** Inline `wpa-ssid` / `wpa-psk` lines work at boot but are not safe with `ifreload -a`: on every reload ifupdown2 runs the wpa hook again, the second wpa_supplicant collides with the running one, and both exit. Wi-Fi drops and stays down until a reboot. That locked out the first P3 attempt, and the rollback hit the same bug. With the service below, a reload leaves the Wi-Fi login alone. Add an ordering drop-in so it starts before the network is configured: `/etc/systemd/system/wpa_supplicant@wlo1.service.d/order.conf` containing `[Unit]` and `Before=networking.service`.

```text
# /etc/wpa_supplicant/wpa_supplicant-wlo1.conf   (chmod 600)
ctrl_interface=/run/wpa_supplicant
country=CA
network={
    ssid="HOME-SSID"
    psk=<hash from wpa_passphrase>
}
```

```text
systemctl enable --now wpa_supplicant@wlo1

# /etc/network/interfaces
auto wlo1
iface wlo1 inet dhcp
    post-up iw dev wlo1 set power_save off || true
```

### `/etc/sysctl.d/99-forge.conf`

```text
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 0
```

### `/etc/nftables.conf`

```text
#!/usr/sbin/nft -f
# No "flush ruleset": that would also wipe rules Proxmox manages.

define WAN_IF  = "wlo1"
define TRANSIT = 192.168.250.0/30

table inet forge
delete table inet forge

table inet forge {
    chain input {
        type filter hook input priority filter; policy accept;
        # OPNsense WAN side may only ping the host (gateway monitoring)
        iifname "vmbr0" ct state established,related accept
        iifname "vmbr0" icmp type echo-request accept
        iifname "vmbr0" counter drop
        # Home LAN must not reach lab addresses on this host
        iifname $WAN_IF ip daddr 10.10.0.0/16 counter drop
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        ct state established,related accept
        iifname "vmbr0" oifname $WAN_IF ip saddr $TRANSIT accept
        limit rate 5/minute log prefix "forge-fwd-drop "
        counter
    }

    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname $WAN_IF ip saddr $TRANSIT masquerade
    }
}
```

- The `forward` chain is what stops the host routing home LAN ↔ lab around OPNsense.
- The `input` rules on `vmbr0` close a hole the plan does not mention: without them, any VLAN that OPNsense lets out to "the internet" could reach the Proxmox GUI on 192.168.250.1:8006.
- The GUI and SSH stay open on Wi-Fi on purpose. That is the recovery path.

---

## P0: Record the fresh state

- [x] **P0.0** Reinstall Proxmox, upgrade, update.
- [x] **P0.1** Record: `pveversion -v | head -3`, `ip -br link`, `ip -br a`, `ip route`, `cat /etc/network/interfaces`, `pvesm status`, `lsblk`.
- [x] **P0.2** Write down the real NIC names (Ethernet and Wi-Fi) and the address the GUI answers on today.
- [x] **P0.3** Back up: `cp /etc/network/interfaces /etc/network/interfaces.bak-$(date +%F)`.
- [ ] **P0.4** Leave the cable in the home router until P2 is finished. It is the only internet the host has.

## P1: Base system

- [x] **P1.1** `apt update && apt full-upgrade`, reboot into the new kernel.
- [ ] **P1.2** Repositories (node → Updates → Repositories): both enterprise repos (pve and ceph) disabled, `pve-no-subscription` enabled. Verify: `apt update` prints no `401 Unauthorized`.
- [ ] **P1.3** BIOS (needs monitor and keyboard, so do it before the box becomes the router): virtualization on, **AC Recovery = Power On**. Verify: `ls /dev/kvm`, `lscpu | grep -i virtualization`.
- [ ] **P1.4** CPU microcode: add the `non-free-firmware` component to the Debian sources, `apt install intel-microcode`, reboot. Verify: `journalctl -k | grep -i microcode`.
- [ ] **P1.5** Time: `timedatectl set-timezone America/Toronto`. Verify: `timedatectl` shows `System clock synchronized: yes`; `chronyc tracking`.
- [ ] **P1.6** Storage: `pvesm status` shows `local` (ISOs, backups) and `local-lvm` (VM disks) active. `df -h /var/lib/vz` has room for an ISO and backups. `smartctl -H /dev/nvme0n1` (or `/dev/sda`) passes.
- [ ] **P1.7** SSH key for root: `ssh-copy-id root@<host>` from the laptop, test it, then set `PermitRootLogin prohibit-password` in `/etc/ssh/sshd_config.d/10-forge.conf`. `sshd -t`, `systemctl reload ssh`. Open a second session before closing the first.
- [ ] **P1.8** Two-factor on `root@pam` (Datacenter → Permissions → Two Factor): add TOTP and a set of recovery keys, keep the recovery keys offline. The GUI stays reachable from the home Wi-Fi by design, so a password alone is thin. Console login is not affected.
- [ ] **P1.9** Proxmox firewall stays off (Datacenter → Firewall → Options → Firewall: No). The design uses its own nftables table; see P4.6.

## P2: Wi-Fi uplink and recovery path

Do this while the cable still gives internet. Every later step relies on Wi-Fi for recovery.

- [x] **P2.1** Install: `apt install wpasupplicant iw tcpdump`. Do **not** install Debian's `firmware-iwlwifi`; `pve-firmware` already ships the Wi-Fi firmware and the two conflict.
- [x] **P2.2** Card is seen: `iw dev` lists the interface, `rfkill list` shows no block, `dmesg | grep -iE 'iwlwifi|ath10k|firmware'` shows no load error. Set the region: `iw reg set CA`.
- [x] **P2.3** PSK hash: run `wpa_passphrase "HOME-SSID"` and type the passphrase at the prompt, so it stays out of shell history. Keep only the `psk=` hex value.
- [x] **P2.4** Add the Wi-Fi stanza from the reference, then `ifup wlo1`. If it does not associate, use the fallback under the reference.
- [x] **P2.5** Verify: `iw dev wlo1 link` shows the SSID, `ip -br a show wlo1` has an address, `ping -I wlo1 -c3 1.1.1.1` works. If `inet dhcp` gets no lease, check that `dhclient` exists.
  - While the installer's wired `gateway` line exists, the Wi-Fi default route may be missing or there may be two. Both are fine here; P3 removes the wired one.
  - With cable and Wi-Fi in the same home subnet, a working GUI on the Wi-Fi IP does not yet prove Wi-Fi carries it. P3.5 is the real proof.
- [ ] **P2.6** *(skipped: no access to the home router admin panel)* Reserve the host's Wi-Fi address in the home router's DHCP. Without it the address (10.0.0.67 on 2026-10-08) usually survives renewals but can change after a long outage. If the GUI stops answering there, read the new one with `ip -br a show wlo1` at the monitor, or from the MGMT side at 10.10.10.5.
- [ ] **P2.7** Power saving off: `iw dev wlo1 get power_save` reports `off` (the `post-up` line makes it persistent).
- [x] **P2.8** Reboot. Wi-Fi comes back with no help. Open `https://<wifi-ip>:8006` from the laptop over Wi-Fi and keep that tab open for the rest of the work. Then save this known-good state: `cp /etc/network/interfaces /etc/network/interfaces.wifi-ok`.

- [x] **P2.9** Move the Wi-Fi login out of `interfaces` into the `wpa_supplicant@wlo1` service (see the reference). Reboot, then prove a reload is safe: run `ifreload -a` with no config change and confirm the SSH session on the Wi-Fi address survives. Refresh the backup afterwards: `cp /etc/network/interfaces /etc/network/interfaces.wifi-ok`.

## P3: Bridges and management address

- [x] **P3.1** Arm the rollback before applying: `systemd-run --on-active=5min --unit=net-rollback sh -c 'cp /etc/network/interfaces.wifi-ok /etc/network/interfaces && ifreload -a'`. It restores the wired setup with Wi-Fi, not the installer file without it.
- [x] **P3.2** Rewrite `/etc/network/interfaces` to the reference, with the real interface names. The installer's `vmbr0` loses its port, its address and its gateway; the Ethernet NIC moves to `vmbr1`.
- [x] **P3.3** Check that no `gateway` line is left anywhere in the file.
- [x] **P3.4** Apply with `ifreload -a`. Read the output for errors.
- [x] **P3.5** Confirm the Wi-Fi GUI tab still works and `ip route` shows a default route through Wi-Fi, then cancel the rollback: `systemctl stop net-rollback.timer`.
  - No default route: the DHCP client could not add it while the wired gateway existed. Bounce Wi-Fi with the timer still armed: `nohup sh -c 'ifdown wlo1; sleep 2; ifup wlo1' >/tmp/wifi-bounce.log 2>&1 &`. `nohup` keeps it running if the session drops halfway.
- [x] **P3.6** Move the cable from the home router to switch Gi1/0/1.
- [x] **P3.7** Update `/etc/hosts`: the hostname must resolve to 10.10.10.5, not the installer address. Proxmox services fail after a reboot if it points at an address that no longer exists. Verify: `hostname --ip-address`.

## P4: NAT and forward-drop

- [x] **P4.1** Write `/etc/sysctl.d/99-forge.conf`, apply with `sysctl --system`.
- [x] **P4.2** Arm a rollback: `systemd-run --on-active=3min --unit=nft-rollback nft delete table inet forge`.
- [x] **P4.3** Write `/etc/nftables.conf` from the reference, check it with `nft -c -f /etc/nftables.conf`, load it with `nft -f /etc/nftables.conf`.
- [x] **P4.4** Confirm the Wi-Fi GUI still works, cancel the rollback: `systemctl stop nft-rollback.timer`.
- [x] **P4.5** Make it persistent: `systemctl enable nftables`.
- [x] **P4.6** `sysctl net.bridge.bridge-nf-call-iptables` is 0. If it is 1, bridged VM traffic passes through the forward chain and the drop policy cuts VMs off from OPNsense. Leave the Proxmox firewall off on VM NICs.
- [ ] **P4.7** *(optional hardening)* Lab traffic that OPNsense lets out to "the internet" can also reach home LAN devices, because the home LAN sits between the host and the internet. OPNsense blocks this with its RFC1918 rules (`OPNSENSE-CONFIG.md` O7). For a second layer on the host, add this line to the `forward` chain above the `accept`, with the real home subnet: `iifname "vmbr0" oifname $WAN_IF ip daddr 10.0.0.0/24 counter drop`.

## P5: Verify — gate before the OPNsense install

Needs the switch and the laptop, not OPNsense.

- [x] **P5.1** `ip -br a show vmbr0` has 192.168.250.1/30. Its state can read `UNKNOWN` or `DOWN` while no VM is attached; the address is what matters.
- [x] **P5.2** `bridge vlan show`: `nic0` lists 10, 20, 30; `vmbr1` lists 10. If `vmbr1` lacks 10: `bridge vlan add dev vmbr1 vid 10 self`.
- [x] **P5.3** `tcpdump -e -nn -i nic0 -c 20 vlan`: frames carry `vlan 10`.
- [ ] **P5.4** On the switch: `show interfaces trunk` lists 10,20,30 as forwarding on Gi1/0/1.
- [x] **P5.5** On the switch: `show mac address-table interface Gi1/0/1` shows the host MAC in VLAN 10, and `ping 10.10.10.5` succeeds from the SVI (10.10.10.2).
- [x] **P5.6** Laptop on Gi1/0/6 with static 10.10.10.50/24: ping 10.10.10.5 and open `https://10.10.10.5:8006`.
- [x] **P5.7** `ip route`: exactly one default route, via Wi-Fi.
- [x] **P5.8** `nft list table inet forge`: forward chain shows `policy drop` (plan acceptance).
- [ ] **P5.9** A home-LAN device cannot ping 10.10.10.5 (plan acceptance). Test it with a static route on that device pointing 10.10.10.0/24 at the host's Wi-Fi IP; without the route the test proves nothing.
- [x] **P5.10** Reboot the host. Wi-Fi, bridges, nftables and the GUI on both addresses all come back.

## P6: Wait for OPNsense

- [x] **P6.1** From the OPNsense shell: `ping 192.168.250.1`, then `ping 1.1.1.1`. This proves the NAT path.
- [ ] **P6.2** From OPNsense, `https://192.168.250.1:8006` does not answer (input drop on `vmbr0`).
- [x] **P6.3** A VM on VLAN 20 reaches its gateway 10.10.20.1, with the forward-drop policy loaded.
- [x] **P6.4** Gateway 10.10.10.1 answers from the host, so the static route is live.

## P7: Save and document

- [ ] **P7.1** Copy `/etc/network/interfaces` and `/etc/nftables.conf` into `forge-infra/network/proxmox/`. Remove the SSID and PSK first; never commit them.
- [ ] **P7.2** Journal entry: the reinstall, the Wi-Fi-first order and why.
- [ ] **P7.3** Add the `vmbr-wan` → `vmbr0` rename to the decision log.
- [ ] **P7.4** Update `docs/runbooks/lockout-recovery`: Wi-Fi GUI first, monitor and keyboard second.

---

## VM wiring rules

- OPNsense `net0` → `vmbr0`, `net1` → `vmbr1` with no VLAN tag (it is the trunk). Details in `OPNSENSE-CONFIG.md`.
- Every other VM: `vmbr1` with a VLAN tag (svc-01 and ci-01 use tag 20). Never attach a workload VM to `vmbr0`.
- Firewall checkbox unticked on every VM NIC.

---

## Optional extras

None of these block OPNsense. Third-party items change or patch the host; read them before running them as root.

**Worth doing**

| ID | Extra | What it gives | How |
|---|---|---|---|
| X1 | Dark theme | Easier on the eyes | Built in: user menu (top right) → Color Theme |
| X2 | `lldpd` | The switch shows the host in `show lldp neighbors` | `apt install lldpd`; `lldp run` on the switch; `lldpcli show neighbors` |
| X3 | Backup job | Nightly copy of the OPNsense VM | Datacenter → Backup → Add: storage `local`, mode snapshot, keep-last 3. Same disk, so copy one off-box now and then. Backups hold `config.xml` secrets: never in git |
| X4 | Notifications | Mail or Discord when a backup fails | Datacenter → Notifications: SMTP or webhook target plus a matcher |
| X5 | VM tags and notes | IP, VLAN and role visible in the tree | VM → Summary → Notes (markdown); tags such as `fw`, `vlan20`; Datacenter → Options → Tag Style |
| X6 | Temperatures | CPU and NVMe temperature | `apt install lm-sensors`, `sensors-detect`, `sensors` |
| X7 | Disable HA services | Fewer SSD writes on a single node | `systemctl disable --now pve-ha-lrm pve-ha-crm`. Re-enable before ever clustering |
| X8 | Power-save governor | Lower idle power on an always-on box | `echo powersave \| tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`; persist with a small systemd unit |
| X9 | fail2ban for GUI and SSH | Slows password guessing from the home LAN | Proxmox wiki "Fail2ban"; whitelist the laptop |
| X10 | Pin NIC names | A kernel update cannot rename the NIC and break the bridges | PVE 9: `pve-network-interface-pinning generate`. Do it before P3 or after P5, never in the middle |

**Later in the plan**

| ID | Extra | When | Note |
|---|---|---|---|
| X11 | Ubuntu 24.04 cloud-init template | Day 2, right after OPNsense | Base for svc-01 and ci-01 |
| X12 | `prometheus-node-exporter` | Monitoring (Day 6 / Week 3) | Bind it to 10.10.10.5:9100 only, so the Wi-Fi side stays closed |
| X13 | `prometheus-pve-exporter` + Grafana dashboard | Week 3 | Per-VM metrics; needs a read-only API token |
| X14 | API token for Terraform | Week 2 | Dedicated user and role, privilege-separated token; token never in git |
| X15 | Proxmox Backup Server | Week 5–6 | Deduplicated, verified backups; needs a second disk or machine |

**Third-party, your call**

| ID | Extra | Note |
|---|---|---|
| X16 | Community helper scripts (`community-scripts.github.io/ProxmoxVE`), "PVE Post Install" | Sets repos, removes the subscription popup, disables HA. It is a script piped into a root shell: read it first. The popup patch is undone by GUI package updates. Skip its OPNsense VM script; building that by hand is the point |
| X17 | Pulse | Separate live dashboard for nodes, VMs and backups. Runs as a container, uses an API token |
| X18 | GUI sensor mod (temperatures in the node summary) | Patches GUI files; breaks on updates and must be re-applied |
| X19 | Proxmox mobile app | Works only while the phone is on the home Wi-Fi |

---

## Everyday tasks

| Task | How |
|---|---|
| Safe network change | Back up `interfaces`, arm `systemd-run --on-active=5min` rollback, `ifreload -a`, verify over Wi-Fi, stop the timer |
| Safe firewall change | `nft -c -f` to check, arm the `nft delete table` rollback, load, verify, stop the timer |
| See what the forward chain blocks | `nft list table inet forge` (counters), `journalctl -k -g forge-fwd-drop` |
| Check VLAN membership | `bridge vlan show` |
| See tagged traffic on the trunk | `tcpdump -e -nn -i nic0 vlan <id>` |
| Check the Wi-Fi uplink | `iw dev wlo1 link`, `ip route`, `ping 1.1.1.1` |
| Reach the host with a direct cable | Laptop needs a tagged sub-interface: `nmcli con add type vlan dev <eth> id 10 ipv4.method manual ipv4.addresses 10.10.10.50/24` |
| Locked out over Ethernet | GUI on the Wi-Fi IP, or monitor and keyboard |
| Reach the OPNsense GUI through the host | `ssh -L 8443:10.10.10.1:443 root@<wifi-ip>`, then `https://127.0.0.1:8443` |
| Snapshot before a VM change | `qm snapshot <id> <name>`; roll back with `qm rollback <id> <name>` |
| VM console without network | GUI noVNC, or `qm terminal <id>` |
| List VMs and their NICs | `qm list`, `qm config <id> \| grep net` |
| Put a VM on a VLAN | NIC on `vmbr1` with VLAN tag N |
| Add a new VLAN end to end | Switch VLAN and trunk `allowed vlan add N`, then `bridge-vids` here and `ifreload -a`, then the OPNsense VLAN interface |
| Back up a VM | `vzdump <id> --mode snapshot` |
| Update the host | Snapshot or back up the OPNsense VM, `apt update && apt full-upgrade`, reboot if the kernel changed, re-run P5.10 |
| Host health | `pveversion`, `pvesm status`, `free -h`, `journalctl -p err -b` |

## Lock-out rules

- Never touch `/etc/network/interfaces` or nftables without a rollback timer armed and the Wi-Fi GUI tab open.
- Never change the Wi-Fi stanza and the Ethernet stanzas in the same apply. One path must stay known-good.
- Verify from a second session before stopping a rollback timer.
- Keep the two-factor recovery keys somewhere that is not this host.
