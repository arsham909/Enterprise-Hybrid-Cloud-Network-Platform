# Evidence

Raw output and screenshots behind the proof tests, captured 2026-10-15. MAC addresses are replaced with labels such as `<laptop-mac>`, and the internet provider's hops are masked. Nothing else is edited, apart from one block of unrelated application traffic removed from file 04.

| File | Device | What it proves | Proof test |
|---|---|---|---|
| [01-switch-trunk.txt](01-switch-trunk.txt) | Switch | Gi1/0/1 is an 802.1Q trunk, native VLAN 99, only VLANs 10, 20, 30 allowed and forwarding | V1 |
| [02-switch-vlans.txt](02-switch-vlans.txt) | Switch | The three zones and their access ports; every unused port parked in VLAN 999 and shut down | Switch tasks |
| [03-switch-security.txt](03-switch-security.txt) | Switch | Port security on the SERVERS ports, DHCP snooping on VLANs 20 and 30 with only the trunk trusted, Dynamic ARP Inspection on VLAN 30, Rapid PVST+ with BPDU Guard on by default | Switch tasks |
| [04-trunk-tagged.txt](04-trunk-tagged.txt) | Proxmox host | Frames on the trunk carry VLAN tags. A USERS laptop's ping to 1.1.1.1 gets replies; its attempts on the Proxmox GUI get none | V4, V5, V6 |
| [05-users-path.txt](05-users-path.txt) | Laptop on USERS | DHCP lease 10.10.30.146 from OPNsense, default route 10.10.30.1, path out: firewall, host NAT, home router | V3, V4 |
| [06-users-blocked.txt](06-users-blocked.txt) | Laptop on USERS | The firewall GUI on both addresses, the Proxmox GUI, switch SSH and the home router all time out | V5 |
| [07-firewall-blocks.png](07-firewall-blocks.png) | OPNsense | The blocks from file 06 in the live log, each with the rule that matched | V5 |
| [08-firewall-rules-users.png](08-firewall-rules-users.png) | OPNsense | USERS rules: group rules for DNS, NTP and ping to the gateway, then block the firewall, block RFC 1918, allow the internet | Rule set |
| [08-firewall-rules-servers.png](08-firewall-rules-servers.png) | OPNsense | The same pattern on SERVERS | V8 |
| [09-proxmox-network.png](09-proxmox-network.png) | Proxmox host | `vmbr0` transit 192.168.250.1/30, VLAN-aware `vmbr1` on `nic0`, host management on `vmbr1.10`, Wi-Fi `wlo1`; the VM list with fw-01, ops-01, svc-01, ci-01, stg-01 | Proxmox tasks |
| [11-mgmt-capture-before-fix.txt](11-mgmt-capture-before-fix.txt) | Proxmox host | Trunk capture during incident 2, while the MGMT laptop had no gateway | [Troubleshooting log](../TROUBLESHOOTING-LOG.md) |

Two rows in file 07 come from 10.0.0.72, the laptop's Wi-Fi address, arriving on the USERS cable. The firewall dropped them with its default deny, because no USERS rule allows a source outside 10.10.30.0/24.
