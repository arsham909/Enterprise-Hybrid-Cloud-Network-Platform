# Lesson: Linux and Proxmox networking, explained through Step 4

What was built on the Proxmox host on 2026-10-08, why, and what every line means. Written so the same setup can be repeated on another host.

---

## 1. Concepts first

### Interface types on this host

| Type | Example here | What it is | Cisco equivalent |
|---|---|---|---|
| Physical NIC | `nic0` | The real Ethernet port | A physical port |
| Wireless NIC | `wlo1` | The Wi-Fi card, a client of the home access point | — |
| Bridge | `vmbr0`, `vmbr1` | A software switch inside the kernel | A switch |
| VLAN sub-interface | `vmbr1.10` | A layer 3 interface that sends and receives one VLAN tag | An SVI (`interface Vlan10`) |
| Tap | `tap100i0` (appears when a VM starts) | The host end of a VM's virtual cable | A switch port with a device plugged in |
| Loopback | `lo` | The host talking to itself | `Loopback0` |

### Bridge = switch

A Linux bridge learns MAC addresses and forwards frames between its ports, exactly like a switch. Its ports are physical NICs and VM taps. A physical NIC that becomes a bridge port stops being a layer 3 interface: **the IP address goes on the bridge (or a sub-interface of it), never on the port.**

### VLAN-aware bridge

A plain bridge ignores VLAN tags. A VLAN-aware bridge (`bridge-vlan-aware yes`) keeps a VLAN table per port, like a real switch:

| Proxmox setting | Meaning | Cisco equivalent |
|---|---|---|
| `bridge-vids 10 20 30` | VLANs allowed on the uplink port | `switchport trunk allowed vlan 10,20,30` |
| VM NIC with **VLAN tag 20** | Frames from the VM are tagged 20 inside the bridge; the VM sees untagged frames | `switchport mode access` + `switchport access vlan 20` |
| VM NIC with **no tag** | The VM receives tagged frames and must handle VLANs itself | `switchport mode trunk` |
| PVID | The VLAN given to untagged frames arriving on a port | Native VLAN |

This is why OPNsense's LAN NIC has no tag (it is a trunk, OPNsense makes the VLAN interfaces) and svc-01 will have tag 20 (it is an access port).

### Bridged or routed

- **Bridged (layer 2):** frames pass through unchanged. The host makes no decision and needs no address. `nic0` ↔ `vmbr1` ↔ OPNsense.
- **Routed (layer 3):** the host receives the packet, looks in its routing table, and sends it out another interface. Needs `ip_forward = 1`, and here also NAT. `vmbr0` ↔ host ↔ `wlo1`.

Wi-Fi forces the routed design. An access point accepts frames only from the MAC that authenticated, so a VM's MAC behind a Wi-Fi client is dropped. A Wi-Fi client interface cannot be a bridge port.

### The routing table

The kernel picks the **most specific** matching route (longest prefix). Three kinds of route appear here:

- **Connected:** created automatically when an interface gets an address.
- **Static:** added by hand or by a `post-up` line.
- **Default:** `0.0.0.0/0`, used when nothing more specific matches.

A host should have **one** default route. Two give unpredictable paths; this is why the `gateway` line had to leave `vmbr0`.

---

## 2. Before and after

**Before (installer default):**

```text
home router ── cable ── nic0 ── vmbr0 192.168.100.2/24, gateway 192.168.100.1
                                  └─ VMs would sit directly on the home network
```

**After:**

```text
home router ┄ Wi-Fi ┄ wlo1 10.0.0.67 (DHCP, the only default route)
                        │   host routes + NATs (Step 5)
                      vmbr0 192.168.250.1/30   no physical port
                        │
                   OPNsense WAN .2
                   OPNsense LAN (trunk)
                        │
                      vmbr1  VLAN-aware, tags 10/20/30
                        ├─ vmbr1.10  10.10.10.5/24   host management
                        └─ nic0 ── cable ── switch Gi1/0/1 (trunk)
```

What moved:

| Thing | Before | After | Why |
|---|---|---|---|
| `nic0` | Port of `vmbr0` | Port of `vmbr1` | It is the trunk to the switch now |
| `vmbr0` | Home LAN, had the gateway | Private link to OPNsense WAN, no port | VMs must not sit on the home LAN |
| Host IP | 192.168.100.2 on `vmbr0` | 10.10.10.5 on `vmbr1.10` | Management lives in VLAN 10 |
| Default route | Via cable | Via Wi-Fi | Cable no longer leads to the internet |

---

## 3. The config, line by line

File: `/etc/network/interfaces`. Read by ifupdown2 at boot and on `ifreload -a`.

Syntax in one look:

- `auto X`: bring X up at boot and on reload. Without it the stanza exists but is not started.
- `iface X inet METHOD`: configure IPv4 on X. Methods: `static` (address given here), `dhcp` (ask a server), `manual` (up, but no address), `loopback`.
- Indented lines: options for that interface.

```text
auto lo
iface lo inet loopback
```
The loopback interface, 127.0.0.1. Many local services depend on it. Never remove it.

```text
auto wlo1
iface wlo1 inet dhcp
    post-up iw dev wlo1 set power_save off || true
```
- `inet dhcp`: runs a DHCP client. The lease gives the address **and** the default route.
- No Wi-Fi password here. Authentication is done by the `wpa_supplicant@wlo1` service; see `LESSON-TROUBLESHOOTING.md` for why.
- `post-up CMD`: run CMD after the interface is up. Related hooks: `pre-up`, `up`, `down`, `post-down`.
- `iw ... set power_save off`: stops the card sleeping between packets, which causes lag and drops on a server.
- `|| true`: if the command fails, report success anyway, so a failed tweak cannot stop the interface coming up.

```text
auto nic0
iface nic0 inet manual
```
- `manual`: bring the link up, assign nothing. Correct for a bridge port, because the port only carries frames.

```text
auto vmbr0
iface vmbr0 inet static
    address 192.168.250.1/30
    bridge-ports none
    bridge-stp off
    bridge-fd 0
```
- `address .../30`: a /30 has exactly two usable addresses, .1 (host) and .2 (OPNsense WAN). The smallest subnet for a point-to-point link.
- `bridge-ports none`: a bridge with no physical port. Only the host and VM taps can attach. An internal-only network.
- `bridge-stp off`: no Spanning Tree. STP prevents loops between switches; one bridge with no redundant path cannot loop, and STP would add delay and send BPDUs.
- `bridge-fd 0`: forwarding delay zero. With the default, a new port waits several seconds before forwarding, so a starting VM would have no network at first.
- No `gateway`: the host does not reach the internet through this bridge.

```text
auto vmbr1
iface vmbr1 inet manual
    bridge-ports nic0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 10 20 30
```
- `inet manual`: the bridge itself has no address. The host does not live in the untagged network.
- `bridge-ports nic0`: the physical uplink.
- `bridge-vlan-aware yes`: per-port VLAN table, as above.
- `bridge-vids 10 20 30`: only these tags may cross `nic0`. Proxmox's default is `2-4094` (everything). Listing only what is needed mirrors the switch's allowed list.

```text
auto vmbr1.10
iface vmbr1.10 inet static
    address 10.10.10.5/24
    post-up ip route add 10.10.0.0/16 via 10.10.10.1 dev vmbr1.10 || true
```
- The name `vmbr1.10` means "VLAN 10 on vmbr1". The kernel creates an 802.1Q sub-interface: frames leave tagged 10, and only tag 10 is received.
- `address 10.10.10.5/24`: the host's management address.
- No `gateway`: this is not the way to the internet.
- `post-up ip route add 10.10.0.0/16 via 10.10.10.1`: a static route. Everything in the lab's /16 goes to OPNsense. Without it, a reply to 10.10.20.11 would match only the default route and leave through Wi-Fi, where it is lost. `|| true` because the route may already exist on a reload.

```text
source /etc/network/interfaces.d/*
```
Includes extra files. Proxmox's SDN feature writes there. Keep the line.

---

## 4. The commands used

| Command | What it does |
|---|---|
| `cp interfaces interfaces.wifi-ok` | Known-good copy to roll back to |
| `systemd-run --on-active=5min --unit=net-rollback sh -c '...'` | Creates a temporary timer and service. In 5 minutes it runs the command once. A dead-man's switch |
| `systemctl list-timers` | Shows the timer and when it fires |
| `systemctl stop net-rollback.timer` | Cancels it |
| `grep -n gateway /etc/network/interfaces` | Proves no stray default route is configured |
| `ifreload -a` | Compares the file with the running state and applies the difference to all `auto` interfaces. No reboot, VMs stay connected |
| `ip route add default via 10.0.0.1 dev wlo1` | Adds a default route by hand. Lives in memory only; gone at reboot, when DHCP adds it properly |
| `hostname --ip-address` | Resolves the hostname through `/etc/hosts`. Proxmox needs this to be a real local address |

Useful variants:

```bash
ifreload -a -s          # syntax check only
ifquery -a --check      # does the running state match the file? pass/fail per line
ifquery vmbr1           # show what the file says about one interface
ifup X / ifdown X       # one interface
```

---

## 5. Reading the result

```text
nic0             UP
wlo1             UP             10.0.0.67/24 ...
vmbr0            UNKNOWN        192.168.250.1/30 ...
vmbr1            UP             fe80::.../64
vmbr1.10@vmbr1   UP             10.10.10.5/24 ...
```

- `nic0 UP`, no address: correct for a bridge port.
- `vmbr0 UNKNOWN`: a bridge with no ports has no link to report. Normal. It becomes `UP` when the OPNsense VM starts and its tap joins.
- `vmbr1` shows only `fe80::`: an automatic IPv6 link-local address. No IPv4, as intended.
- `vmbr1.10@vmbr1`: the `@` names the parent. This is a sub-interface riding on `vmbr1`.
- `vmbr1` and `nic0` share a MAC: a bridge takes its MAC from its first port.

```text
default via 10.0.0.1 dev wlo1
10.0.0.0/24 dev wlo1 proto kernel scope link src 10.0.0.67
10.10.0.0/16 via 10.10.10.1 dev vmbr1.10
10.10.10.0/24 dev vmbr1.10 proto kernel scope link src 10.10.10.5
192.168.250.0/30 dev vmbr0 proto kernel scope link src 192.168.250.1
```

- `proto kernel scope link`: a connected route, made by the kernel when the address was added. `scope link` means "directly reachable, no router".
- `src`: the source address the host uses when it starts a connection on that route.
- `via X`: next hop is a router at X.
- `10.10.0.0/16 via 10.10.10.1`: the static route from `post-up`. 10.10.10.1 does not exist until OPNsense is built, so lab addresses outside VLAN 10 time out for now.

Longest prefix in action:

| Destination | Matching routes | Winner | Leaves via |
|---|---|---|---|
| 10.10.10.2 (switch) | /24, /16, default | /24 | `vmbr1.10`, direct |
| 10.10.20.11 (svc-01) | /16, default | /16 | `vmbr1.10`, to OPNsense |
| 10.0.0.72 (laptop on Wi-Fi) | /24, default | /24 | `wlo1`, direct |
| 1.1.1.1 | default | default | `wlo1`, to home router |

Ask the kernel directly instead of guessing: `ip route get 10.10.20.11`.

---

## 6. Tips and tricks

### Proxmox specific

- **Never `systemctl restart networking` on a Proxmox host with running VMs.** It tears bridges down and the VM taps are not re-attached; VMs lose network until restarted. Use `ifreload -a`.
- **The GUI writes `/etc/network/interfaces.new`** and applies it on "Apply Configuration". If that file is left over from an abandoned GUI edit, it replaces your hand-edited file at the next reboot. Check for it: `ls /etc/network/interfaces.new`.
- **Editing by hand and in the GUI both work**, but the GUI rewrites the file and can drop comments. Pick one habit per host.
- **Pinned NIC names** (`nic0`) survive kernel and hardware changes. On hosts with `enp3s0`-style names, a new card or kernel can rename the port and the bridge comes up with no uplink. PVE 9: `pve-network-interface-pinning generate`.
- **`/etc/hosts` must map the hostname to a real local address.** If it points at an address the host no longer has, `pve-cluster` and the GUI fail after reboot.
- **VM NIC firewall checkbox** inserts an extra firewall bridge per NIC. Leave it off unless the Proxmox firewall is in use.
- **Bridge names:** `vmbrN` always works. Hyphens are rejected.

### Linux bridges and VLANs

```bash
bridge link                  # ports of every bridge and their state
bridge vlan show             # VLAN table per port, with PVID and tagged/untagged
bridge fdb show br vmbr1     # MAC address table (like show mac address-table)
ip -d link show vmbr1.10     # -d shows details: VLAN id, bridge options
ip neigh                     # ARP table
tcpdump -e -nn -i nic0 vlan  # -e prints the Ethernet header, so tags are visible
tcpdump -e -nn -i nic0 vlan 30 and icmp
```

- `bridge vlan show` lists VLAN 1 as `PVID Egress Untagged` on every port by default. Untagged frames from the bridge leave `nic0` untagged and land in the switch's native VLAN 99, which carries nothing. Harmless here, and the reason the native VLAN is an unused one.
- Capture on `nic0` to see tags. On `vmbr1.10` the tag has already been removed.
- A VLAN sub-interface on a VLAN-aware bridge needs that VLAN on the bridge's own "self" port. ifupdown2 adds it; if it is missing: `bridge vlan add dev vmbr1 vid 10 self`.

### Routing

- `ip route get <dst>` shows the route **and** source address the kernel will use. First command for any "why does this go the wrong way" question.
- `ip route` changes are in memory only. To persist a route, put it in the interfaces file (`post-up`) or the config of whatever manages the interface.
- Two interfaces in the same subnet on one host cause ARP confusion (either may answer). Avoid it, or expect odd results.
- Replies follow the routing table, not the path the request came in on. A request can arrive on one interface and the reply leave on another: asymmetric routing. Strict `rp_filter` and stateful firewalls drop that.
- Forwarding between interfaces is off by default: `sysctl net.ipv4.ip_forward`. A Linux box is a host until that is 1.

### Safe change habits

1. Out-of-band path confirmed and not part of the change.
2. Backup of the file.
3. `ifreload -a -s` for syntax.
4. Rollback timer armed, and its mechanism tested once with a no-op.
5. Apply, verify from a second session, cancel the timer.
6. Reboot test before calling it done: plenty of setups work until the first reboot.

---

## 7. Checklist for the next Proxmox host

1. `ip -br link`: find real NIC names. Pin them if not already pinned.
2. Decide the layout on paper: which bridge is the uplink, where the host's management IP lives, where the single default route points.
3. Uplink to a switch trunk: one VLAN-aware bridge, `bridge-vids` matching the switch's allowed list, host IP on `vmbrX.<mgmt vlan>`.
4. Uplink to an access port instead: plain bridge, host IP directly on the bridge.
5. Internal-only network between VMs: bridge with `bridge-ports none`.
6. Wi-Fi uplink: routed plus NAT, authentication in a `wpa_supplicant@` service, never bridged.
7. Two NICs for redundancy: `bond0` (LACP or active-backup) as the bridge port.
8. Exactly one `gateway` line, or none when DHCP supplies it.
9. `/etc/hosts` matches the management address.
10. Apply with a rollback, verify, reboot, verify again.

Common alternatives to know by name:

- **One bridge per VLAN** (`nic0.20` as the port of `vmbr20`): older style, simple, more bridges to manage.
- **SDN** (Datacenter → SDN): zones and VNets managed in the GUI, useful with clusters.
- **Open vSwitch:** another switch implementation, needed only for features Linux bridges lack.
