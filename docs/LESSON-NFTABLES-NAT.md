# Lesson: Linux routing, NAT and firewalling with nftables, explained through Step 5

What was built on the Proxmox host on 2026-10-09, why, and how to read, change and debug it.

---

## 1. Why Step 5 exists

After Step 4 the host had the right interfaces but could not pass traffic between them. Two things were missing, and one thing was dangerous:

| Problem | Without the fix | Fix |
|---|---|---|
| A Linux box does not forward packets by default | OPNsense's WAN (192.168.250.2) reaches the host and stops there | `net.ipv4.ip_forward = 1` |
| The home router has never heard of 192.168.250.0/30 | Packets go out, replies never come back | Source NAT (masquerade) on the way out the Wi-Fi |
| A box that forwards will forward **anything** it has a route for | Home LAN ↔ lab traffic could pass through the host and skip OPNsense entirely | `forward` chain with `policy drop` |

Turning on forwarding makes the host a router. A router with no filter is a hole around the firewall. So forwarding and the drop policy belong together; never enable the first without the second.

---

## 2. Concepts

### The five hooks

Every IP packet the kernel handles passes through fixed checkpoints called netfilter hooks. Rules are attached to hooks. Knowing which hook a packet goes through is most of firewall troubleshooting.

```text
                      ┌────────────────── this host's own programs ─────────────────┐
                      │            (pveproxy :8006, sshd :22, ping, apt)            │
                      └───────▲───────────────────────────────────────┬─────────────┘
                              │                                       │
                         ┌────┴────┐                             ┌────▼────┐
                         │  INPUT  │                             │ OUTPUT  │
                         └────▲────┘                             └────┬────┘
                              │ for me                                │
 packet    ┌────────────┐  ┌──┴───────┐ not for me ┌─────────┐   ┌────▼────────┐   packet
 arrives ─►│ PREROUTING ├─►│ ROUTING  ├───────────►│ FORWARD ├──►│ POSTROUTING ├─► leaves
           └────────────┘  │ DECISION │            └─────────┘   └─────────────┘
            (DNAT here)    └──────────┘                           (SNAT here)
```

- **input:** packets addressed to the host itself.
- **forward:** packets passing through to somewhere else. Only used when `ip_forward = 1`.
- **output:** packets the host's own programs create.
- **prerouting / postrouting:** before and after the routing decision. Destination NAT happens in prerouting, source NAT in postrouting.

A packet goes through **input or forward, never both**. Blocking the GUI is an input job. Blocking home LAN ↔ lab is a forward job.

**Bridged traffic is different.** Frames switched inside `vmbr1` (switch ↔ OPNsense trunk) are layer 2. They do not pass these IP hooks at all, unless the `br_netfilter` module pushes them there (`net.bridge.bridge-nf-call-iptables = 1`). That is why the forward drop policy does not cut the VLAN trunk, and why that sysctl was checked.

### Connection tracking (stateful filtering)

The kernel remembers every connection it has seen in the conntrack table. Each packet gets a state:

| State | Meaning |
|---|---|
| `new` | First packet of a connection |
| `established` | Belongs to a connection already seen in both directions |
| `related` | A helper packet tied to an existing connection, such as an ICMP "unreachable" error |
| `invalid` | Fits nothing; usually dropped |

`ct state established,related accept` is the line that makes a firewall stateful. Rules then only need to describe who may **start** a connection. Replies are handled by that one line. Without it every allow rule would need a mirror rule for the return direction.

NAT uses the same table. The translation is decided once, on the first packet, and remembered; replies are translated back automatically.

### NAT flavours

| Type | Changes | Hook | Used for | Cisco equivalent |
|---|---|---|---|---|
| SNAT | Source address, to a fixed address | postrouting | Outbound with a static public IP | `ip nat inside source static` / pool |
| Masquerade | Source address, to whatever address the outgoing interface has right now | postrouting | Outbound when the address comes from DHCP | `ip nat inside source list X interface Y overload` (PAT) |
| DNAT | Destination address | prerouting | Port forwarding inbound | `ip nat inside source static tcp ...` |

Masquerade is the right one here: the Wi-Fi address comes from DHCP and could change.

### nftables structure

```text
table  ──►  chain  ──►  rule
(family)    (hook, priority, policy)   (match ... action)
```

- **Table:** a named container. Family `inet` covers IPv4 and IPv6 together; `ip` is IPv4 only; `bridge` is for layer 2.
- **Base chain:** attached to a hook with a priority and a default policy. This is where packets enter.
- **Rule:** matches from left to right, then a verdict: `accept`, `drop`, `reject`, or a non-final action such as `counter` or `log`.
- **Policy:** the verdict when no rule gave one.

Rules are checked top to bottom; the first final verdict wins.

Several tables can attach to the same hook. Priority decides the order (lower runs first: `dstnat` -100, `filter` 0, `srcnat` 100). **An `accept` in one table does not protect a packet from a `drop` in another.** A packet must survive every chain on the hook. This matters when Docker, the Proxmox firewall or old iptables rules are on the same box.

---

## 3. What was built

### The three pieces

```text
/etc/sysctl.d/99-forge.conf     turn forwarding on, at every boot
/etc/nftables.conf              the rules
nftables.service (enabled)      loads that file at boot
```

### The policy as a picture

```text
                         HOME LAN 10.0.0.0/24  (router 10.0.0.1, laptop, phones)
                                      │
                                    wlo1  10.0.0.67
        ┌─────────────────────────────┼──────────────────────────────────────┐
        │  Proxmox host               │                                      │
        │                             │                                      │
        │   INPUT (to the host)       │      FORWARD (through the host)      │
        │   policy ACCEPT             │      policy DROP                     │
        │                             │                                      │
        │   wlo1 → GUI/SSH      ✔     │   vmbr0 → wlo1, src transit   ✔ +NAT │
        │   wlo1 → 10.10.x.x    ✘     │   replies (established)       ✔      │
        │   vmbr0 → ping        ✔     │   wlo1  → vmbr0  (new)        ✘      │
        │   vmbr0 → anything    ✘     │   wlo1  → vmbr1.10 (new)      ✘      │
        │   vmbr1.10 → GUI/SSH  ✔     │   vmbr1.10 → wlo1  (new)      ✘      │
        │                             │   everything else      ✘ + log       │
        │                             │                                      │
        └────────┬────────────────────┴───────────────────┬──────────────────┘
               vmbr0  192.168.250.1/30                 vmbr1.10  10.10.10.5
                 │                                        │
          OPNsense WAN .2                          VLAN 10 MGMT
                                                   (vmbr1 trunk itself is bridged,
                                                    not seen by these chains)
```

Read it as three statements:

1. **Only OPNsense may use the host as a router, and only towards the internet.**
2. **The OPNsense side and the home LAN side cannot reach each other's world through the host.**
3. **Admin access to the host stays open from the home Wi-Fi and from MGMT**, on purpose: one is the recovery path, the other is the normal path.

### A packet's journey: OPNsense fetches an update

```text
① OPNsense sends      src 192.168.250.2:50000   dst 1.1.1.1:443
        │ arrives on vmbr0
② PREROUTING          nothing to do
③ ROUTING DECISION    1.1.1.1 is not mine → default route → out wlo1 → FORWARD
④ FORWARD             state is new, so rule 1 does not match
                      rule 2: in vmbr0, out wlo1, src in 192.168.250.0/30 → ACCEPT
                      conntrack records the connection
⑤ POSTROUTING         out wlo1, src in transit → MASQUERADE
                      src becomes 10.0.0.67:50000   (translation recorded)
⑥ leaves on Wi-Fi     home router NATs again to the Rogers public address

   ...reply comes back...

⑦ arrives on wlo1     src 1.1.1.1:443   dst 10.0.0.67:50000
⑧ PREROUTING          conntrack recognises it, reverses the NAT:
                      dst becomes 192.168.250.2:50000
⑨ ROUTING DECISION    192.168.250.2 is on vmbr0 → FORWARD
⑩ FORWARD             rule 1: established → ACCEPT
⑪ out vmbr0           OPNsense receives its reply
```

Step ⑧ is the part people miss: the reply is un-NATed **before** routing, so the host knows where to send it. No rule was written for it.

### A blocked packet: a phone on the home LAN tries to reach the lab

```text
phone 10.0.0.50 → 10.10.20.11   (the phone has a static route via 10.0.0.67)
arrives on wlo1 → not mine → route says vmbr1.10 → FORWARD
  rule 1: not established
  rule 2: wrong input interface
  rule 3: log "forge-fwd-drop " (rate limited)
  rule 4: counter +1
  policy: DROP
```

---

## 4. The config, line by line

### `/etc/sysctl.d/99-forge.conf`

```text
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 0
```

- `sysctl` values are kernel settings, visible as files under `/proc/sys/` (`cat /proc/sys/net/ipv4/ip_forward`).
- `sysctl -w key=value` changes one until reboot. A file in `/etc/sysctl.d/` makes it permanent. Files load in name order, so `99-` wins over lower numbers.
- IPv6 forwarding stays off: the lab is IPv4 only for now, and a host that forwards IPv6 with no IPv6 rules would be a second, unfiltered path.

### `/etc/nftables.conf`

```text
#!/usr/sbin/nft -f
```
Lets the file be run directly. The service runs `nft -f /etc/nftables.conf`.

```text
define WAN_IF  = "wlo1"
define TRANSIT = 192.168.250.0/30
```
Variables, replaced when the file loads. One place to change if the Wi-Fi card or the transit subnet changes.

```text
table inet forge
delete table inet forge
```
Create the table if it does not exist, then delete it, so the block below always starts clean. This makes the file safe to load again and again. The common alternative, `flush ruleset`, wipes **every** table, including any that Proxmox or another tool created. Own your table, leave the rest alone.

```text
table inet forge {
    chain input {
        type filter hook input priority filter; policy accept;
```
A base chain on the input hook. Policy accept: anything not explicitly dropped below reaches the host. A deliberate choice, because the GUI and SSH must stay reachable from Wi-Fi for recovery. A stricter host would use policy drop and list what is allowed.

```text
        iifname "vmbr0" ct state established,related accept
        iifname "vmbr0" icmp type echo-request accept
        iifname "vmbr0" counter drop
```
Three rules for the OPNsense-facing bridge:
- Replies to things the host started are allowed.
- Ping is allowed, because OPNsense monitors its gateway by pinging it.
- Everything else from that side is counted and dropped. Without this, any lab client that OPNsense allows "to the internet" could open `https://192.168.250.1:8006`, because that address is on the way.

```text
        iifname $WAN_IF ip daddr 10.10.0.0/16 counter drop
```
A device on the home LAN that aims at a lab address on the host (10.10.10.5) is dropped. The host's lab address answers only from the lab side.

```text
    chain forward {
        type filter hook forward priority filter; policy drop;
```
Default deny for everything passing through.

```text
        ct state established,related accept
```
First, so the bulk of traffic (replies and ongoing connections) matches immediately. Also a performance rule: put the busiest match at the top.

```text
        iifname "vmbr0" oifname $WAN_IF ip saddr $TRANSIT accept
```
The single allowed way to start a connection through the host. Three conditions, all required: came from the OPNsense bridge, leaving by Wi-Fi, source inside the /30. The source check stops a misconfigured VM on `vmbr0` using another address.

```text
        limit rate 5/minute log prefix "forge-fwd-drop "
        counter
```
Neither is a verdict, so the packet continues to the policy and is dropped. The log line goes to the kernel log, at most five a minute so a scan cannot fill the disk. The counter gives a number even when logging is rate limited.

```text
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname $WAN_IF ip saddr $TRANSIT masquerade
    }
```
A NAT chain. Only the first packet of each connection passes through NAT chains; the rest follow the recorded translation. Policy accept here means "do not translate", not "allow"; filtering is the filter chains' job.

---

## 5. Commands used, and their relatives

| Command | What it does |
|---|---|
| `sysctl --system` | Load every sysctl file now |
| `sysctl net.ipv4.ip_forward` | Read one value |
| `nft -c -f file` | Check a file without loading it |
| `nft -f file` | Load a file. The whole file applies atomically: all of it or none of it |
| `nft list table inet forge` | Show one table with live counters |
| `nft list ruleset` | Show everything from every tool. Always look here when confused |
| `systemctl enable nftables` | Load `/etc/nftables.conf` at boot |
| `systemd-run --on-active=3min ... nft delete table inet forge` | Dead-man's switch: remove our rules if nobody cancels |

More nft worth knowing:

```bash
nft -a list table inet forge                    # -a shows a handle number per rule
nft delete rule inet forge forward handle 7     # remove one rule by handle
nft insert rule inet forge forward ...          # add at the top
nft add rule inet forge forward ...             # add at the bottom
nft reset counters table inet forge             # zero the counters before a test
nft monitor                                     # watch ruleset changes live
```

Rules added on the command line live in memory only. To keep one, put it in the file.

---

## 6. Troubleshooting

### The order to check

1. **Is it routing at all?** `sysctl net.ipv4.ip_forward`. Then `ip route get <dst> from <src> iif <in-interface>` shows the kernel's forwarding decision for a transit packet.
2. **Which hook does this packet use?** To the host: input. Through the host: forward. Inside one bridge: neither.
3. **Do the counters move?** `nft reset counters table inet forge`, repeat the test, `nft list table inet forge`. A moving drop counter names the rule.
4. **What does the log say?** `journalctl -k -g forge-fwd-drop`. Each line shows `IN=`, `OUT=`, `SRC=`, `DST=`, `PROTO=`, `DPT=`.
5. **Watch the wire on both sides.** Request visible on the inside but not the outside: dropped or not routed. Visible outside with the wrong source: NAT did not apply. Visible outside, no reply: the next hop has no route back.
   ```bash
   tcpdump -nn -i vmbr0 host 1.1.1.1      # before NAT: src 192.168.250.2
   tcpdump -nn -i wlo1  host 1.1.1.1      # after NAT:  src 10.0.0.67
   ```
6. **Look at the state table.** `apt install conntrack`, then `conntrack -L | grep 192.168.250.2` lists tracked connections with both the original and the translated addresses; `conntrack -E` shows events live.

### Tracing one packet through every rule

The strongest nft tool. Mark the packets of interest, then watch which rule and which verdict they hit:

```bash
nft insert rule inet forge forward ip saddr 192.168.250.2 meta nftrace set 1
nft monitor trace
# ...run the test, read the output, Ctrl+C...
nft -a list chain inet forge forward        # find the handle of the trace rule
nft delete rule inet forge forward handle <N>
```

### Common faults

| Symptom | Likely cause |
|---|---|
| Nothing forwards, counters at zero | `ip_forward` is 0, or the packet never reaches this host (routing on the sender) |
| Leaves with a private source address, no reply | NAT rule did not match: wrong `oifname`, wrong source subnet |
| Works until reboot | Rules were added by hand, service not enabled, or sysctl set with `-w` only |
| Works one way, replies dropped | Missing `established,related` rule, or asymmetric routing so conntrack sees half the connection |
| Rules look right, traffic still dropped | Another table on the same hook drops it. Read `nft list ruleset`, not just your table |
| VMs on a bridge lose network after adding a forward drop | `bridge-nf-call-iptables = 1` is sending bridged frames through the IP chains |
| Rules vanish after another tool starts | That tool ran `flush ruleset` |
| Load fails at boot only: "interface does not exist" | Rule uses `iif` (needs the interface to exist at load time). Use `iifname`, a string match that works for interfaces created later, such as VM taps and bridges |
| Ping works, large downloads stall | MTU. Path MTU discovery needs ICMP "fragmentation needed", which `related` allows; a blanket ICMP drop breaks it |

### Tips

- **Counters are free diagnostics.** Put `counter` on any rule you may want to ask about later.
- **Rate-limit every log rule.** An unlimited log on a drop rule turns a port scan into a full disk.
- **`iptables` commands still exist** on Debian but write into nftables through a compatibility layer (`iptables-nft`). Their rules appear in `nft list ruleset` as tables named `ip filter`, `ip nat`. Mixing both styles on one host is the usual source of "who added this rule".
- **Docker sets the forward policy to drop** in its own tables and adds its own NAT. A container host and a hand-written firewall need care.
- **Reverse path filtering** (`rp_filter`) is a separate kernel check that drops packets arriving on an interface the reply would not leave by. It drops silently, before any nft rule; `nstat -az TcpExtIPReversePathFilter` shows the count.
- **Test denials, not only allows.** A firewall that passes everything also passes every "it works" test.
- **Before a remote firewall change:** syntax check, rollback timer, apply, test from a new session, cancel the timer. Same habit as the network change.

---

## 7. Practice on the lab

1. Reset counters, ping 192.168.250.1 from OPNsense once it exists, and find which input rule counted it.
2. From OPNsense, try `https://192.168.250.1:8006` and watch the drop counter on the third input rule rise.
3. Capture the same ping to 1.1.1.1 on `vmbr0` and on `wlo1` at once, and compare the source addresses.
4. Add a temporary trace rule, follow one packet with `nft monitor trace`, then remove the rule by handle.
5. Set `ip_forward` to 0 with `sysctl -w`, watch OPNsense lose the internet, set it back. Note that a reboot would also have restored it, and why.
6. Read `conntrack -L` during a download and identify the original and translated tuples.
