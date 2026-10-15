# Troubleshooting log

Real faults found while building the lab, how each was isolated, and what changed afterwards. Each entry follows the same order: symptom, facts, layer by layer checks, root cause, fix, proof, prevention.

| # | Date | Symptom | Layer | Root cause |
|---|---|---|---|---|
| 1 | 2026-10-08 | Proxmox host unreachable after a network reload over SSH | 2 (Wi-Fi association) | A reload started a second `wpa_supplicant`, which knocked out the first. Full write-up: [LESSON-TROUBLESHOOTING.md](LESSON-TROUBLESHOOTING.md) |
| 2 | 2026-10-15 | Admin laptop on MGMT has no internet, only the lab | 3 (host routing) | The laptop's `lab-mgmt` profile had no default gateway and no DNS, and was set to never take the default route |

---

## Incident 2: no internet from the management VLAN

### Symptom

The admin laptop, cabled to switch port Gi1/0/6 (VLAN 10, MGMT), reaches the firewall, the Proxmox host and the other zones' gateways, but not the internet. To work online, Wi-Fi had to be switched on next to the cable.

### Expected behaviour

MGMT should reach the internet. The design gives it unrestricted outbound access ("allow LAN to any", rule M3), and SERVERS and USERS, with stricter rules, already reach the internet (evidence 05).

### Facts before testing

- The fault was never seen before because it was never tested. Proof test V2 checked only the firewall GUI and pings to the gateways. Wi-Fi was on during V2, so internet traffic left over Wi-Fi and hid the gap.
- USERS, on the same firewall, the same trunk and the same NAT path, reaches the internet. So the firewall's WAN, its NAT and the Proxmox host's NAT work.
- What differs between USERS and MGMT on the laptop: USERS uses DHCP (`lab-users` profile), MGMT uses a static profile (`lab-mgmt`) written in stage 1, before any router existed.

The second fact narrows the search: the shared path works, so the fault is in what MGMT does not share with USERS: its firewall rules, or the laptop's MGMT profile.

### Method: bottom up, one layer at a time, Wi-Fi off

Wi-Fi off first, so that no second path can hide the result:

```bash
nmcli radio wifi off
nmcli con up lab-mgmt
```

| Layer | Check | Result |
|---|---|---|
| 1 Physical | `ip -br link show eno1` | UP |
| 2 Data link | `ping -c3 10.10.10.1`, `ip neigh show 10.10.10.1` | Gateway answers, its MAC is learned |
| 3 Network, address | `ip -br a show eno1` | 10.10.10.50/24, correct |
| 3 Network, routes | `ip route` | **No default route.** Fault found here |
| 7 Application, DNS | `resolvectl dns eno1` | **No DNS server** on the link |

The routing table, before the fix:

```text
❯ ip route
10.10.0.0/16 via 10.10.10.1 dev eno1 proto static metric 100
10.10.10.0/24 dev eno1 proto kernel scope link src 10.10.10.50 metric 100
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown
172.18.0.0/16 dev br-aaf3aa2061d7 proto kernel scope link src 172.18.0.1 linkdown
192.168.49.0/24 dev br-1feaee088fd3 proto kernel scope link src 192.168.49.1 linkdown
```

Reading it: the laptop knows two things. 10.10.10.0/24 is directly on the cable, and the rest of the lab (10.10.0.0/16) is behind 10.10.10.1. For any other address, such as 1.1.1.1, there is no matching route and no default, so the kernel refuses to send the packet ("Network is unreachable"). The packet never reaches the switch, so the firewall rules and the NAT were never involved. That one table removed layers 4 to 7, the firewall and the uplink from the list.

The DNS check matched it:

```text
❯ resolvectl dns eno1
Link 2 (eno1):
```

The profile itself, the cause of both:

```text
❯ nmcli -f ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.dns,ipv4.routes,ipv4.never-default con show lab-mgmt
ipv4.method:                            manual
ipv4.addresses:                         10.10.10.50/24
ipv4.gateway:                           --
ipv4.dns:                               --
ipv4.routes:                            { ip = 10.10.0.0/16, nh = 10.10.10.1 }
ipv4.never-default:                     yes
```

### Root cause

The `lab-mgmt` profile was written in stage 1, when the switch had no router behind it. The rule then was right: no gateway and no DNS on a link with no internet, and `never-default yes`, so that Wi-Fi kept the default route while the cable was plugged in.

When OPNsense arrived in stage 3, only one static route was added to reach the other zones:

```bash
nmcli connection modify lab-mgmt +ipv4.routes "10.10.0.0/16 10.10.10.1"
```

That was enough for every V2 test, which only went to lab addresses. The network changed and the client's configuration did not.

### Fix

Give the profile a gateway and a DNS server, and allow it to take the default route:

```bash
nmcli connection modify lab-mgmt \
  ipv4.method manual \
  ipv4.addresses 10.10.10.50/24 \
  ipv4.gateway 10.10.10.1 \
  ipv4.dns 10.10.10.1 \
  ipv4.never-default no
nmcli connection down lab-mgmt && nmcli connection up lab-mgmt
```

The general form of the command:

```bash
nmcli connection modify "<connection name>" ipv4.addresses <ip>/<prefix> ipv4.gateway <gateway ip> ipv4.dns "<dns ip>" ipv4.method manual
```

The 10.10.0.0/16 route is now redundant, because the default route also points at 10.10.10.1. It does no harm. To remove it:

```bash
nmcli connection modify lab-mgmt -ipv4.routes "10.10.0.0/16 10.10.10.1"
```

### Proof

The routing table after the fix has a default route through the MGMT gateway:

```text
❯ ip route
default via 10.10.10.1 dev eno1 proto static metric 100
10.10.0.0/16 via 10.10.10.1 dev eno1 proto static metric 100
10.10.10.0/24 dev eno1 proto kernel scope link src 10.10.10.50 metric 100
172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown
172.18.0.0/16 dev br-aaf3aa2061d7 proto kernel scope link src 172.18.0.1 linkdown
192.168.49.0/24 dev br-1feaee088fd3 proto kernel scope link src 192.168.49.1 linkdown
```

End to end, with Wi-Fi still off:

```bash
resolvectl dns eno1               # 10.10.10.1
ping -c3 1.1.1.1                  # replies
traceroute -n 1.1.1.1             # 10.10.10.1, 192.168.250.1, 10.0.0.1, then the internet
curl -sI https://example.com | head -1
```

<!-- paste the output of the four commands above here -->

### With Wi-Fi back on

Both links now offer a default route. NetworkManager gives wired links metric 100 and Wi-Fi metric 600, and the lowest metric wins, so traffic goes through the lab while the cable is plugged in and falls back to Wi-Fi when it is not. Check which path a packet takes with:

```bash
ip route get 1.1.1.1
```

### Prevention

- **New proof test V10:** from MGMT with Wi-Fi off, `ping 1.1.1.1`, `traceroute -n 1.1.1.1` and a DNS lookup must work. Added to the OPNsense proof tests.
- **Every proof test runs with Wi-Fi off.** V3 to V5 already did this for USERS; V2 did not.
- **Client profiles are configuration too.** When a router, a gateway or a DNS server is added, review the profiles of every device on that segment, not only the network devices.

### Open question

A trunk capture taken before the fix ([evidence 11](evidence/11-mgmt-capture-before-fix.txt)) shows the laptop sending ARP requests on VLAN 10 for internet addresses (for example `who-has 152.2.23.103 tell 10.10.10.50`). A host only sends ARP for an address it believes is on the local link, and the main routing table above has no such route. Not explained yet. Next check, on the laptop in the broken state: `ip route get 152.2.23.103`, `ip rule`, and `ip route show table all | grep eno1`, to find a route in a table other than `main`.
