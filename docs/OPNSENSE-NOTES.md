# OPNsense Notes — what I learned building the firewall

Recap of the OPNsense side of Forge Hybrid, 2026-10-09 to 2026-10-11. Tasks live in `OPNSENSE-CONFIG.md`, the one-pass procedure in `OPNSENSE-MVP-RUNSHEET.md`. This file is for understanding and revision.

Related: `PROXMOX-NOTES.md` · `SWITCH-NOTES.md` · `LESSON-NFTABLES-NAT.md` (same firewall ideas on Linux)

---

## 1. What the firewall is, in this design

A virtual machine that is the only router between the lab's networks, and the only way from the lab to the internet.

```text
                       internet
                          ▲
            Proxmox host 192.168.250.1  (routes + NATs out the Wi-Fi)
                          ▲
            WAN  vtnet0  192.168.250.2/30
          ┌───────────────────────────────┐
          │           OPNsense            │   rules, NAT, DHCP, DNS
          └───────────────────────────────┘
            LAN  vtnet1  (trunk, no address)
              ├─ VLAN 10  MGMT     10.10.10.1/24   DHCP .100–.119
              ├─ VLAN 20  SERVERS  10.10.20.1/24   static hosts
              └─ VLAN 30  USERS    10.10.30.1/24   DHCP .100–.199
                          ▼
            one cable to switch Gi1/0/1  →  access ports per VLAN
```

| Fact | Value |
|---|---|
| Version | OPNsense 26.7.6_3 (FreeBSD 15 based) |
| VM | 100 `fw-01`, q35, OVMF, 2 cores `host`, 4 GB, 24 GB on ZFS |
| `net0` → `vtnet0` | MAC `BC:24:11:xx:xx:xx`, bridge `vmbr0`, WAN |
| `net1` → `vtnet1` | MAC `BC:24:11:xx:xx:xx`, bridge `vmbr1`, trunk |
| Name | `fw-01.lab` |
| GUI | `https://10.10.10.1`, from MGMT only |
| Snapshots | `opn-bootstrap`; `opn-baseline` after the proof |

**WAN and LAN here.** WAN is whatever leads towards the internet: a private link to the Proxmox host, not the home network. LAN is one virtual NIC carrying three tagged networks.

**Router-on-a-stick.** Traffic between two VLANs goes up the one cable tagged with the source VLAN, is routed by OPNsense, and comes back down the same cable tagged with the destination VLAN. The switch only tags.

---

## 2. Need to know

### Stateful firewall

The firewall remembers every connection it allowed, in a state table. A rule decides who may **start** a connection; replies are matched against the table and need no rule.

```text
1. laptop → 1.1.1.1:443        new connection, rules are checked, USERS rule says pass
2. state written:  10.10.30.105:51000 ⇄ 1.1.1.1:443  ESTABLISHED
3. reply 1.1.1.1 → laptop      found in the table, passed, no rule checked
```

- This is why WAN has no rules and the internet still works.
- A stateless filter (a Cisco extended ACL) judges every packet alone, so return traffic needs its own entries.
- See the table: Firewall → Diagnostics → States, or `pfctl -ss`.

### How rules are evaluated

| Idea | Meaning |
|---|---|
| Where a rule lives | On the interface where traffic **enters** the firewall. The USERS tab controls what USERS clients may start |
| Order | Top to bottom, first match wins |
| Quick | Stop at the first match. Always ticked |
| Direction in | Evaluate as the packet arrives. The normal choice |
| Default deny | No match means dropped. A new interface passes nothing until it has rules |
| Evaluation sequence | Automatic rules (DHCP, anti-lockout) → floating → interface groups → the interface's own rules → default deny |
| Save versus Apply | Save stores the rule. **Apply changes** loads it into the running firewall |
| Block versus Reject | Block drops silently and the client waits. Reject answers "no" and the client fails fast. Block gives away less |
| Log | Per rule. Only logged rules and the default deny appear in Live View |
| Description | Becomes the label in the log. Write one on every rule |

Built-in names used in rules:

- **This Firewall:** every address the firewall owns, on all interfaces (10.10.10.1, 10.10.20.1, 10.10.30.1, 192.168.250.2). Blocking it stops the GUI being reached through *any* of them.
- **`USERS net`, `SERVERS net`, `MGMT net`:** the subnet configured on that interface.
- **Anti-lockout rule:** automatic pass for the GUI and SSH on LAN (MGMT). Never disable it.

### RFC 1918

RFC means Request for Comments, the numbered documents that define internet standards. RFC 1918 reserved three ranges for private use:

| Range | CIDR | Addresses |
|---|---|---|
| 10.0.0.0 – 10.255.255.255 | `10.0.0.0/8` | 16 million |
| 172.16.0.0 – 172.31.255.255 | `172.16.0.0/12` | 1 million |
| 192.168.0.0 – 192.168.255.255 | `192.168.0.0/16` | 65 thousand |

Anyone may use them, they are never routed on the internet, and they need NAT to get out. Every network in this project is inside them: the lab (10.10.x.x), the home LAN (10.0.0.x), the transit link (192.168.250.x), AWS later (10.50.x.x).

So "block `RFC1918`, then pass any" means "internet only, nothing internal", including networks added in the future.

### Aliases

A named list that rules refer to. Edit the list once and every rule follows.

| Type | Holds |
|---|---|
| Host(s) | Single addresses or hostnames |
| Network(s) | Subnets in CIDR form |
| Port(s) | Ports and ranges |
| URL (IPs) | A list downloaded once |
| URL Table (IPs) | A list downloaded and refreshed on a schedule |
| GeoIP | All addresses of chosen countries |
| MAC address | Hardware addresses |
| Network group | Other aliases combined |
| BGP ASN | Every network of one organisation |
| Dynamic IPv6 Host | An IPv6 host whose prefix changes |
| OpenVPN group | Logged-in VPN users |
| Internal / External | Filled by the system itself |

System aliases, not to be edited:

- **`bogons` / `bogonsv6`:** address ranges that are reserved or unallocated and should never appear as a source on the internet (0.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, multicast, reserved space). Used by "Block bogon networks".
- **`sshlockout`:** filled automatically with addresses that failed too many logins to SSH or the GUI; they are blocked for a while. If I mistype the password many times, this is why I am shut out.
- **`virusprot`:** filled when a rule's connection-rate limit is exceeded.

### Interface groups

A set of interfaces sharing rules. `LAB_ZONES` (MGMT, SERVERS, USERS) carries the rules every zone needs, written once. Group rules run before each member's own rules.

### The minimum rule set

| Where | Rules, in order |
|---|---|
| `LAB_ZONES` | Pass DNS 53 (TCP/UDP), NTP 123 (UDP), ICMP echo request → This Firewall |
| MGMT | Default allow to any, plus anti-lockout |
| SERVERS | Block → This Firewall · Block → `RFC1918` · Pass → any |
| USERS | Block → This Firewall · Block → `RFC1918` · Pass → any |
| WAN | None |

Walking packets from USERS:

| Packet | Matched by | Result |
|---|---|---|
| DNS to 10.10.30.1 | Group rule 1 | Pass |
| GUI 10.10.30.1:443 | USERS rule 1 | Block |
| GUI by its MGMT address 10.10.10.1:443 | USERS rule 1 (This Firewall covers all its addresses) | Block |
| Proxmox 10.10.10.5:8006 | USERS rule 2 | Block |
| Home router 10.0.0.1 | USERS rule 2 | Block |
| 1.1.1.1:443 | USERS rule 3 | Pass |

Move rule 3 to the top and everything passes. Order is the policy.

### NAT

| Menu in 26.7 | Older name | Does |
|---|---|---|
| Source NAT | Outbound | Rewrites the source of traffic leaving. In use, on Automatic |
| Destination NAT | Port Forward | Rewrites the destination of traffic arriving, to expose a server. Never used here |
| One-to-One NAT | One-to-One | One public address mapped to one private, both ways |
| NPTv6 | NPTv6 | IPv6 prefix translation |

Automatic source NAT makes every lab client leave as 192.168.250.2, the only address the Proxmox host accepts and translates.

```text
10.10.30.105 →(OPNsense)→ 192.168.250.2 →(Proxmox)→ 10.0.0.67 →(home router)→ public address
```

### Services

- **Dnsmasq** hands out DHCP on MGMT and USERS. **Unbound** answers DNS on port 53. Both can speak DNS, so Dnsmasq's DNS port must not be 53.
- **Unbound is a recursive resolver:** it asks the root servers itself and needs no upstream provider.
- DHCP works on an interface with no rules because the service adds its own automatic allow rules. Everything else on that interface stays blocked.
- Only one DHCP backend per interface.

### Settings chosen, and why

| Setting | Value | Reason |
|---|---|---|
| WAN: Block private networks | Off | The WAN is a private network by design. The option is meant for a WAN on the real internet |
| WAN: Block bogon networks | Off | Same reasoning; nothing reaches this WAN but the host |
| Hardware checksum offload, TSO, LRO | Disabled | A virtual NIC has no hardware to offload to; with offload on, routed packets can carry bad checksums. Symptom: ping works, web pages hang |
| Allow IPv6 | Off | No IPv6 rules exist yet, so all of it is dropped |
| SERVERS DHCP | None | Servers are static |
| ZFS | Yes | Boot environments allow rolling back a bad update from inside OPNsense |

---

## 3. Good to know

- **OPNsense is FreeBSD**, not Linux. NICs are `vtnet0`, `vtnet1` (VirtIO); the disk is `da0`; the packet filter is `pf`, controlled with `pfctl`.
- **Installer login** is `installer` / `opnsense`. Logging in as root on the ISO gives the live system, not the installer.
- **OVMF with Secure Boot keys enrolled will not boot OPNsense.** Untick "Pre-Enroll keys" when creating the VM.
- **The default interface guess was wrong** (LAN = `vtnet0`, WAN = `vtnet1`, LAN at 192.168.1.1). Assign by MAC address, not by order.
- **The LAN had to be created as a VLAN at the console.** The admin laptop sits in VLAN 10, so an untagged LAN would have been unreachable.
- **The subnet mask dropdown defaults to 32** when adding an address. Set 24.
- **The wizard can overwrite console settings.** Check the WAN and LAN pages before applying.
- **"Firmware" means the whole operating system and packages.** Updates are under System → Firmware.
- **Device, assignment, interface:** a VLAN *device* is the raw tagged sub-interface; *assigning* it makes OPNsense adopt it and give it a menu entry, a rules tab and services.
- **The parent `vtnet1` stays unassigned.** Untagged traffic is the switch's native VLAN 99, which carries nothing.
- **Renaming LAN to MGMT** changes only the label. Internally it is still `lan`, so the anti-lockout rule still applies.
- **Menu names move between releases.** "Outbound NAT" became "Source NAT" in 26.7. When a path does not match, look for the function, not the word.
- **`pfctl -sn` shows the NAT rules actually loaded**, whatever the GUI looks like. The same goes for `pfctl -sr` and the filter rules.
- **Lab clients could reach the home LAN** if "internet" were simply "any": the home LAN sits between the host and the internet. The `RFC1918` block closes that.
- **Plan correction:** the plan lists the AWS allow rules under the WireGuard interface. They belong on SERVERS, where that traffic enters. The WireGuard interface gets one block-and-log rule.
- **The guest agent is enabled only after the plugin is installed**, and needs a full stop and start of the VM.
- **A ping to another zone's gateway** (10.10.20.1 from USERS) is addressed to the firewall itself, so the group's ping rule may answer it. That is not a leak between zones.

### Console menu

| Option | Use |
|---|---|
| 1 | Assign interfaces (and create VLANs) |
| 2 | Set an interface's address, DHCP, GUI protocol |
| 3 | Reset the root password |
| 4 | Factory reset |
| 5 / 6 | Power off / reboot |
| 7 | Ping |
| 8 | Shell |
| 9 | pfTop: live connections |
| 10 | Firewall log |
| 11 | Reload all services |
| 12 | Update from the console |
| 13 | Restore an earlier configuration |

---

## 4. Command cheat sheet

### On the firewall (console option 8)

| Command | Does |
|---|---|
| `pfctl -sr` | Loaded filter rules, in evaluation order |
| `pfctl -sn` | Loaded NAT rules |
| `pfctl -ss` | State table |
| `pfctl -si` | Counters: states, packets passed and blocked |
| `pfctl -d` / `pfctl -e` | Firewall off / on. Off also stops NAT. Emergency access only |
| `configctl filter reload` | Rebuild and reload the rules from the config |
| `ifconfig` | Interfaces; VLANs show their parent and tag |
| `netstat -rn4` | IPv4 routing table |
| `drill name @127.0.0.1` | DNS query against the local resolver |
| `tcpdump -ni vtnet1 -e vlan 30` | Tagged traffic on the trunk |
| `ntpq -pn` | Time sources |

Reading a NAT line:

```text
nat on vtnet0 inet from (vlan0.30:network) to any -> (vtnet0:0) port 1024:65535
```
Traffic leaving WAN, from the USERS subnet, to anywhere: replace the source with the WAN address and choose a free source port.

### On the Proxmox host

| Command | Does |
|---|---|
| `qm snapshot 100 NAME` | Before every change session |
| `qm rollback 100 NAME` | Undo everything since |
| `qm listsnapshot 100` / `qm delsnapshot 100 NAME` | List and clean up |
| `qm config 100` | Check the VM against the spec |
| `nft list table inet forge` | Host counters when the firewall cannot reach the internet |

### On a test laptop

| Command | Does |
|---|---|
| `dig @10.10.10.1 example.com +short` | Ask one DNS server, answer only |
| `nc -zvw2 10.10.10.5 8006` | Does the port open: `-z` test only, `-v` report, `-w2` two-second limit |
| `curl -sI https://example.com \| head -1` | HTTP status line only |
| `traceroute -n 1.1.1.1` | Each router on the path. Expected: 10.10.30.1 → 192.168.250.1 → 10.0.0.1 |
| `ping -c2 -W2 host` | Two pings, two-second wait |
| `resolvectl dns eno1` | DNS server in use on that link |
| `nmcli radio wifi off` | Remove the laptop's other path, so a test really goes through the lab |

TTL trick: a ping reply with `ttl=63` from a Linux host (which sends 64) passed through exactly one router.

---

## 5. What went wrong, and what it taught

| # | What happened | Cause | Fix | Lesson |
|---|---|---|---|---|
| 1 | After install, **LAN was on `vtnet0` at 192.168.1.1 and WAN had nothing** | OPNsense's default assignment is the reverse of this design | Console option 1, assigned by MAC, LAN created as VLAN 10 | Identify NICs by MAC, never by position |
| 2 | **"Firewall → NAT → Outbound" did not exist** | Renamed "Source NAT" in 26.7; the instructions used the old name | Found the function under the new name; `pfctl -sn` as a version-proof check | Verify against the running system, not the documentation |
| 3 | VM came out with **1 core and a generic CPU type** | Wizard defaults | `qm set 100 --cores 2 --cpu host` | Compare `qm config` with the spec |
| 4 | **Ping from USERS to its gateway failed** right after DHCP worked | No rules on USERS yet; only DHCP's automatic rule existed | Expected; the rule set fixes it | A new interface is default deny. "DHCP works, nothing else" is the correct intermediate state |
| 5 | Risk: **"must fail" tests succeed** with the laptop's Wi-Fi on | The laptop reaches the target by its other network | Wi-Fi off during proof tests | A test proves something only if there is one path |
| 6 | Risk: the laptop's **MAC stays learned** on a switch port after a test | Port-security sticky | `clear port-security sticky interface <port>` | Test equipment leaves traces in security features |

### From the first attempt (August 2026)

An earlier build of this lab used management in VLAN 99 (192.168.99.0/24) and a phone on USB tethering as the WAN, bridged straight into the firewall. It was rebuilt with the current plan. Two faults from that build are worth keeping.

| # | What happened | Cause | Fix | Lesson |
|---|---|---|---|---|
| A | After a factory reset of the firewall and a change of bridges on the host, **the gateway stopped answering**. On the laptop, `ip neigh` showed the host as resolved and the gateway as `INCOMPLETE` | The VM's two NICs had swapped bridges, so `vtnet0` and `vtnet1` were reversed. The firewall was listening for the tagged LAN on the WAN bridge and asking for a WAN lease on the trunk | Console option 1: create the VLAN on the NIC that is really on the trunk, assign WAN and LAN again. Option 2: set the LAN address | The same fault as number 1 above, months apart. `INCOMPLETE` in the ARP table is a layer 2 problem: no rule can cause it, so look at tagging and NIC assignment first |
| B | **WAN had no address**: `ifconfig vtnet1` showed `status: active`, many packets sent, few received, no `inet` line | The Proxmox host had taken the upstream DHCP lease itself. Details in `PROXMOX-NOTES.md`, first attempt, fault B | Fixed on the host, then a new lease requested from the firewall | An interface that is up with no address and one-way counters is asking and not being answered. The fault is upstream |

Commands used for these, added to the cheat sheet:

| Where | Command | Does |
|---|---|---|
| Firewall shell | `ifconfig vtnet1` | Link state, address, packet counters in each direction |
| Firewall shell | `dhclient vtnet1` | Ask for a WAN lease now |
| Firewall shell | `configctl interface reconfigure wan` | Rebuild the WAN interface from the saved configuration |
| Laptop | `ip neigh show dev <if>` | ARP table: `REACHABLE`, `STALE` or `INCOMPLETE` per neighbour |
| Laptop | `sudo ip neigh flush all` | Forget old entries before testing again |
| Switch | `show mac address-table vlan <id>` | Which MACs the switch has really seen in that VLAN, and on which port |

---

## 6. Questions I asked, short answers

**What does stateful mean?** The firewall remembers allowed connections and lets their replies back automatically. Rules only say who may start.

**What is RFC 1918?** The standard that reserves 10/8, 172.16/12 and 192.168/16 for private networks. Not routed on the internet; need NAT.

**What alias types exist besides Network?** Host, Port, URL, URL Table, GeoIP, MAC, Network group, BGP ASN and a few more. This project needs Host, Network and Port.

**What are `bogons` and `sshlockout`?** System lists. Bogons are address ranges that should never appear on the internet. `sshlockout` collects addresses that failed too many logins.

**What is M6?** Checking, not building: WAN has no rules, Source NAT is on Automatic, everything is applied and the GUI still answers, Live View is open.

**Which is WAN and which is LAN?** WAN is `vtnet0` on `vmbr0`, the private link to the host. LAN is `vtnet1` on `vmbr1`, the trunk to the switch.

---

## 7. State and what is left

Done: VM, install, console bootstrap, wizard, update, VLAN 20 and 30, DHCP, DNS, Source NAT on Automatic, the minimum rule set, proof V1–V9, encrypted config backup, snapshot `opn-baseline`.

Still open: O4.7, confirming IPv6 is off on every interface.

Deferred: guest agent, personal admin user, SSH hardening, TOTP, host overrides, NTP for the zones, full rule matrix for svc-01 and ci-01, WireGuard.
