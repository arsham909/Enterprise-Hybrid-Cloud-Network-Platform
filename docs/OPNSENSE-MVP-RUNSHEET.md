# OPNsense MVP run sheet: O6 → rules → proof → save

One pass, top to bottom. Task IDs match `OPNSENSE-CONFIG.md`. Written 2026-10-11 for OPNsense 26.7.6; menu names can differ slightly.

**Before starting**

- Laptop cabled to switch Gi1/0/6, profile `lab-mgmt` up, GUI open at `https://10.10.10.1`.
- A second tab on the Proxmox GUI (`https://10.0.0.67:8006`) with the VM 100 console ready. That is the way back in if a rule locks the GUI.
- Snapshot on the host:
  ```bash
  qm snapshot 100 pre-services-rules
  ```

Known addresses: WAN 192.168.250.2 · MGMT 10.10.10.1 · SERVERS 10.10.20.1 · USERS 10.10.30.1 · host 10.10.10.5 · switch 10.10.10.2 · home router 10.0.0.1.

---

## Part 1: Services (O6)

### 1.1 DHCP service (O6.1, O6.4)

Services → find the DHCP service the console enabled. Expected: **Dnsmasq DNS & DHCP**. If the MGMT pool sits under Kea or ISC instead, stop and ask; the steps differ.

Dnsmasq → General:

| Field | Value | Why |
|---|---|---|
| Enable | ✔ | |
| Interface | MGMT (LAN) **and** USERS | DHCP answers only on listed interfaces. SERVERS is static |
| Listen port | not 53 (53053) or 0 | Port 53 belongs to Unbound |
| DHCP register firewall rules | ✔ | Creates the allow rules for DHCP itself |

Check that no other DHCP server (Kea, ISC) is enabled on MGMT or USERS.

### 1.2 Ranges (O6.2)

Dnsmasq → DHCP ranges. Keep the MGMT range from the console (10.10.10.100–119). Add:

| Interface | Start | End | Domain |
|---|---|---|---|
| USERS | 10.10.30.100 | 10.10.30.199 | lab |

Apply.

### 1.3 DNS (O6.5)

Services → Unbound DNS → General: Enable ✔, port 53, Network interfaces All, DNSSEC ✔. Apply.

### 1.4 Quick check from MGMT (O6.9)

```bash
dig @10.10.10.1 example.com +short      # an internet address
dig @10.10.10.1 fw-01.lab +short        # 10.10.10.1
```

`dig @server name` asks one DNS server directly; `+short` prints only the answer.

---

## Part 2: Minimum rule set (M1–M6)

How rules work here:

- A rule filters traffic where it **enters** the firewall. A rule on USERS controls what USERS clients may start.
- Top to bottom, first match wins (with Quick on).
- Order of evaluation: automatic and floating rules → interface groups → the interface's own rules.
- No match means dropped. SERVERS and USERS have no rules yet, so they pass nothing except DHCP.
- "This Firewall" means every address the firewall owns, on all interfaces.

For every rule below: Quick ✔, Direction in, TCP/IP version IPv4, and fill in the Description. Tick Log on every block rule.

### M1: Alias

Firewall → Aliases → add:

| Field | Value |
|---|---|
| Name | `RFC1918` |
| Type | Network(s) |
| Content | `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` |
| Description | All private address space |

Save, Apply. An alias is a named list; rules refer to the name, and editing the list updates every rule that uses it.

### M2: Group and its rules

Firewall → Groups → add: Name `LAB_ZONES`, Members MGMT, SERVERS, USERS. Save, Apply.

A group is a set of interfaces that share rules. Its rules run before each member's own rules, so common services are written once.

Firewall → Rules → LAB_ZONES, three rules:

| # | Action | Protocol | Source | Destination | Dest. port | Description |
|---|---|---|---|---|---|---|
| 1 | Pass | TCP/UDP | any | This Firewall | 53 (DNS) | Zones: DNS to firewall |
| 2 | Pass | UDP | any | This Firewall | 123 (NTP) | Zones: NTP to firewall |
| 3 | Pass | ICMP, type Echo Request | any | This Firewall | — | Zones: ping the gateway |

### M3: MGMT

Firewall → Rules → MGMT. Do not add anything. Confirm two things exist:

- the default "allow LAN to any" rule (IPv4);
- the anti-lockout rule, visible under the automatically generated rules.

### M4: SERVERS

Firewall → Rules → SERVERS, in this order:

| # | Action | Protocol | Source | Destination | Log | Description |
|---|---|---|---|---|---|---|
| 1 | Block | any | SERVERS net | This Firewall | ✔ | SERVERS: no access to firewall |
| 2 | Block | any | SERVERS net | `RFC1918` | ✔ | SERVERS: no private networks |
| 3 | Pass | any | SERVERS net | any | | SERVERS: internet |

### M5: USERS

Firewall → Rules → USERS, in this order:

| # | Action | Protocol | Source | Destination | Log | Description |
|---|---|---|---|---|---|---|
| 1 | Block | any | USERS net | This Firewall | ✔ | USERS: no access to firewall |
| 2 | Block | any | USERS net | `RFC1918` | ✔ | USERS: no private networks |
| 3 | Pass | any | USERS net | any | | USERS: internet |

Why this order works:

- DNS, NTP and ping to the firewall were already passed by the group, so rule 1 only catches the rest: the GUI (443), SSH (22) and everything else on the firewall.
- Rule 2 covers MGMT, the other zone, the transit network 192.168.250.0/30 and the home LAN 10.0.0.0/24. All of them are private addresses.
- Rule 3 is then safe: "any" can only mean public addresses by the time a packet reaches it.

### M6: WAN and apply

- Firewall → Rules → WAN: no rules. Leave it empty.
- **Apply changes** on each rules page.
- Firewall → NAT → Source NAT (named "Outbound" before 26.7): mode Automatic, with entries for the three lab networks.
- GUI still answers from the MGMT laptop. If not: console, option 13 restores the previous config, or `qm rollback 100 pre-services-rules` on the host.

---

## Part 3: Proof (V1–V9)

Open Firewall → Log Files → Live View in the GUI before starting and leave it running.

### V1: Trunk (switch console)

```text
show interfaces trunk
```
Gi1/0/1 trunking, VLANs 10,20,30 in the forwarding list.

### V2: MGMT (laptop on Gi1/0/6, profile `lab-mgmt`)

```bash
ping -c2 10.10.10.1 && ping -c2 10.10.20.1 && ping -c2 10.10.30.1
```
All answer. `https://10.10.10.1` and `https://10.10.10.5:8006` open.

### V3: USERS gets a lease (move the cable to Gi1/0/4)

```bash
nmcli con delete lab-users 2>/dev/null
nmcli con add type ethernet con-name lab-users ifname eno1 ipv4.method auto ipv6.method disabled
nmcli radio wifi off
nmcli con up lab-users
ip -br a show eno1
ip route
resolvectl dns eno1
```

- A plain DHCP profile: address, default route and DNS all come from the firewall.
- `nmcli radio wifi off` removes the laptop's other path, so every test below really goes through the lab. If anything goes wrong, `nmcli radio wifi on` brings the internet back.
- Want: address in 10.10.30.100–199, `default via 10.10.30.1`, DNS 10.10.30.1.

The lease alone proves the VLAN 30 tag survives switch → trunk → bridge → firewall.

### V4: USERS reaches the internet, by the expected path

```bash
ping -c3 10.10.30.1
dig example.com +short
curl -sI https://example.com | head -1
traceroute -n 1.1.1.1
```

Traceroute hops: `10.10.30.1` (OPNsense), `192.168.250.1` (Proxmox host), `10.0.0.1` (home router), then the ISP. Each hop is one router; the first three are the three NATs.

### V5: USERS is contained (each of these must fail)

```bash
nc -zvw2 10.10.30.1 443      # firewall GUI on its own gateway address
nc -zvw2 10.10.10.1 443      # firewall GUI on the MGMT address
nc -zvw2 10.10.10.5 8006     # Proxmox GUI
nc -zvw2 10.10.10.2 22       # switch SSH
nc -zvw2 192.168.250.1 8006  # Proxmox GUI through the transit network
ping -c2 -W2 10.0.0.1        # home router
ping -c2 -W2 10.10.20.1      # other zone's gateway
```

`nc -z` only tests whether the port opens; `-v` prints the result; `-w2` gives up after 2 seconds.

In Live View each attempt appears in red with the description of the rule that blocked it. The ping to 10.10.20.1 is a special case: it is addressed to the firewall itself, so the group's ping rule may pass it. Either result is acceptable; note which one you get.

### V6: Router-on-a-stick, seen on the wire

Laptop still on USERS. On the Proxmox host, two sessions:

```bash
# session 1
tcpdump -e -nn -i nic0 icmp
# session 2
ping -c4 <laptop's 10.10.30.x address>
```

- The host (10.10.10.5, VLAN 10) sends to the firewall, the firewall routes, and the packet leaves the trunk tagged `vlan 30`. tcpdump on `nic0` shows requests with `vlan 30` going out and replies with `vlan 30` coming back.
- The ping replies show `ttl=63`. The laptop sent 64; one router in between took one off. That one router is OPNsense.
- No reply at all but tagged requests visible: the laptop's own firewall is dropping ping. The tagged requests are still the proof.

### V7: The switch saw it (switch console)

```text
show mac address-table interface Gi1/0/1
show ip dhcp snooping binding
```

- The firewall's trunk MAC `bc24.11xx.xxxx` appears in VLAN 10 and VLAN 30 on Gi1/0/1. One MAC, several VLANs, one port: router-on-a-stick from the switch's point of view.
- The laptop is listed as a snooping binding on Gi1/0/4, VLAN 30.

### V8: SERVERS (move the cable to Gi1/0/2)

```bash
nmcli con delete lab-servers 2>/dev/null
nmcli con add type ethernet con-name lab-servers ifname eno1 ipv4.method manual \
  ipv4.addresses 10.10.20.50/24 ipv4.gateway 10.10.20.1 ipv4.dns 10.10.20.1 ipv6.method disabled
nmcli con up lab-servers

ping -c2 10.10.20.1                    # works
curl -sI https://example.com | head -1 # works
nc -zvw2 10.10.10.5 8006               # fails
nc -zvw2 10.10.20.1 443                # fails
ping -c2 -W2 10.10.30.1                # see the note in V5
```

Then put the laptop back:

```bash
nmcli con down lab-servers
nmcli radio wifi on
```

Cable back to Gi1/0/6, `nmcli con up lab-mgmt`. On the switch, free the test MAC from the SERVERS port:

```text
clear port-security sticky interface Gi1/0/2
```

### V9: Survives a power loss

On the host: `reboot`. Touch nothing. After a few minutes:

- `qm status 100` reports running without anyone starting it.
- Laptop on Gi1/0/4 with `lab-users` (Wi-Fi off) gets a lease and loads a web page.

---

## Part 4: Save (O8.4, O7.11)

**Config backup.** System → Configuration → Backups → Download configuration, with "Encrypt this configuration file" ticked and a password. Keep the file off the host and out of git: it holds password hashes and later VPN keys.

**Snapshot.** On the host:

```bash
qm snapshot 100 opn-baseline --description "MVP: 3 zones, DHCP, DNS, minimum rules, proof passed"
qm listsnapshot 100
qm delsnapshot 100 pre-update
qm delsnapshot 100 pre-vlans
qm delsnapshot 100 pre-services-rules
```

Old snapshots are removed because long chains waste thin storage. `opn-bootstrap` and `opn-baseline` stay.

---

## If something goes wrong

| Symptom | Look at |
|---|---|
| GUI gone after a rule change | VM console: option 13 (restore a backup), or `pfctl -d` to switch the firewall off until the next reload |
| No lease on USERS | Dnsmasq interface list and range; switch `show ip dhcp snooping binding`, `show interfaces Gi1/0/4 status` |
| Lease but no DNS | LAB_ZONES rule 1; Unbound running and listening on all interfaces |
| DNS but no internet | USERS rule 3 present and below the blocks; NAT → Source NAT automatic; host `nft list table inet forge` counters |
| A "must fail" test succeeds | Wi-Fi still on (the laptop used its other path), or rule order wrong |
| Everything breaks at once | `qm rollback 100 pre-services-rules` |

---

## After this: the road from here

### Block A: Harden what exists (about half a day)

Small items, deferred on purpose. None changes the design.

| Device | Tasks |
|---|---|
| OPNsense | O4.4 guest agent · O4.8 personal admin user · O8.1 SSH (MGMT only, key only) · O8.3 TOTP · O6.6 host overrides (`pve.lab`, `sw-01.lab`) · O6.7 NTP for the zones · confirm O4.2, O4.3, O4.7 |
| Switch | VTY ACL + `access-class` · `ntp server 10.10.10.1` · rogue DHCP test · new golden config |
| Proxmox | P1.7 SSH key · P1.8 TOTP · P1.4 microcode · X3 nightly backup job for VM 100 · P5.9 home-LAN test |
| Docs | Journal entries, sanitized configs into `forge-infra/network/`, ADRs, lockout runbook |

### Block B: Servers (rest of plan Day 2)

1. Ubuntu 24.04 cloud-init template (VM 9000).
2. Clone **svc-01** (10.10.20.11) and **ci-01** (10.10.20.12) on VLAN 20.
3. Full rule matrix: svc-01 and ci-01 passes, USERS → SERVERS on 80/443/3000.
4. `scripts/verify-segmentation.sh`: the V-checks as a PASS/FAIL script.
5. GitHub Actions runner on ci-01.

### Block C: Cloud and the hybrid link (plan Day 3)

Terraform two-tier AWS VPC, WireGuard from OPNsense to `vpn-gw`, proof that AWS cannot start connections into home.

### Block D: Application and pipeline (plan Days 4–5)

Repair Status Portal, CI on ci-01, GHCR, GitOps pull agent on web-01, Ansible push to data-01, Cloudflare in front.

### Block E: Drills and packaging (plan Day 6)

Rollback drill, VPN-loss drill, monitoring, README, diagram, video, LinkedIn post.

### Then: Weeks 2–8

Terraform for Proxmox, Ansible for the switch and hosts, S2S IPsec demo mode, SNMP and LibreNMS, CML labs.

**Schedule note.** The plan's MVP date was 2026-10-04; the network foundation is landing about a week later. The network is the part every later block stands on, and it is now built and understood, with three lesson files to show for it. To recover time, keep Block A to the security items (admin user, SSH keys, VTY ACL, backup job) and push journal polish to the end.
