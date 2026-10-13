# Lesson: Troubleshooting a Linux server from logs

Built on a real incident: `ifreload -a` killed Wi-Fi on the Proxmox host on 2026-10-08. The method is the same on any production Linux server.

---

## 1. The incident in one page

| | |
|---|---|
| **What I did** | Ran `ifreload -a` over SSH on the host's Wi-Fi address to apply new bridges |
| **Symptom** | SSH froze, host unreachable, the 5-minute rollback did not help |
| **Recovery** | Power cycle; the config on disk was already the rolled-back one |
| **Root cause** | `wpa-ssid` / `wpa-psk` lines in `/etc/network/interfaces` are handled by a hook script made for classic ifupdown. ifupdown2's `ifreload -a` re-ran that hook on an interface that was already up. A second `wpa_supplicant` started, collided with the first on the control socket, and the running one exited |
| **Fix** | Wi-Fi login moved to the systemd unit `wpa_supplicant@wlo1`. `interfaces` keeps only DHCP for `wlo1` |
| **Proof** | `ifreload -a` with no changes; SSH stayed alive |

The evidence, three lines out of hundreds:

```text
22:49:24 wpa_supplicant[22703]: ctrl_iface exists and seems to be in use - cannot override it
22:49:24 wpa_supplicant[22703]: Failed to initialize control interface '/run/wpa_supplicant'.
22:49:24 wpa_supplicant[855]:   wlo1: CTRL-EVENT-TERMINATING
```

---

## 2. The method, step by step

Use the same eight steps every time, in this order.

### Step 1: Restore service first, investigate second

In production the first job is to get users working again, not to understand the bug. Roll back, fail over, or restart. Here: power cycle onto the rolled-back config.

Before restoring, grab evidence that the restore would destroy, if it takes seconds: a screenshot, `ip a`, `ps aux`, `dmesg | tail`. Logs on disk survive a reboot; process state and the routing table do not.

### Step 2: Write down facts, separate them from guesses

Facts from this incident:

- The freeze came at the exact moment of `ifreload -a`.
- I was connected to 10.0.0.67 (Wi-Fi), the laptop was 10.0.0.72, same subnet.
- The rollback timer was armed.
- After a power cycle everything worked.

The question that always pays off: **what changed?** Most outages follow a change.

### Step 3: Narrow the layer

Go bottom-up and stop at the first layer that fails.

| Layer | Question | Commands |
|---|---|---|
| 1 Physical | Is the link up? | `ip -br link`, `ethtool nic0`, `iw dev wlo1 link` |
| 2 Data link | Right VLAN, right MAC learned? | `bridge vlan show`, `bridge fdb show`, `ip neigh` |
| 3 Network | Address and route correct? | `ip -br a`, `ip route`, `ip route get 1.1.1.1`, `ping` |
| 4 Transport | Is the port listening and reachable? | `ss -tlnp`, `nc -zv host 22` |
| 7 Application | Does the service answer correctly? | `systemctl status`, `curl -v`, `dig` |

Reasoning used here: laptop and host share a subnet, so no router and no default route is involved. Layer 3 cannot be the cause. The fault must be at layer 1 or 2 on the Wi-Fi link. That one deduction removed routing, firewall and SSH from the list before reading a single log line.

### Step 4: Pick the right log and the right time window

- The host had been rebooted, so the failure was in the **previous** boot: `journalctl -b -1`.
- The time window was known: the minute `ifreload` ran.
- The components were known from step 3: Wi-Fi.

```bash
journalctl -b -1 --no-pager | grep -iE 'wlo1|wpa_supplicant|dhclient|ifreload|net-rollback|vmbr'
```

Reading the wrong boot is the classic mistake. `journalctl -b` showed a perfectly clean start and proved nothing.

### Step 5: Read the log like a timeline

Three things to track:

1. **Timestamp.** Line everything up against what you did and when.
2. **Process name and PID** in `name[PID]`. A low PID started at boot. A new high PID appearing at the moment of the failure is something that was just launched.
3. **The first error, not the last.** Later errors are usually consequences.

Applied:

- `wpa_supplicant[855]`: low PID, the healthy instance from boot.
- `wpa_supplicant[22703]`: appeared at 22:49:24, the same second as the reload. Something started a second copy.
- 22703 logs `ctrl_iface exists and seems to be in use`. It wanted a socket that 855 owned.
- 855 logs `CTRL-EVENT-TERMINATING`. The healthy one died.
- 22:51:19: `Started net-rollback.service`, then a third PID (23130) with the same pattern. The rollback repeated the fault.

### Step 6: Form a hypothesis that explains every fact

"`ifreload -a` starts a second wpa_supplicant for an interface that already has one."

Check it against the facts: explains the freeze at that moment, explains why the rollback failed (same command), explains why a reboot fixed it (only one instance starts at boot). No fact is left over. If a fact does not fit, the hypothesis is wrong or incomplete.

### Step 7: Fix the cause, then prove it

- Fix the cause, not the symptom. Restarting Wi-Fi after each reload would be a symptom fix.
- Prove it with the smallest safe test: `ifreload -a` with zero config changes.
- Only then repeat the real change.

### Step 8: Write it up and prevent it

Timeline, root cause, fix, what would have caught it earlier. Update the runbook. This is a post-incident review, and it should blame the process, not the person.

---

## 3. `journalctl` and `systemctl` cheat sheet

```bash
journalctl -b                 # current boot
journalctl -b -1              # previous boot
journalctl --list-boots       # all boots with times
journalctl -u ssh             # one unit
journalctl -u ssh -b -1       # one unit, previous boot
journalctl -k                 # kernel messages (like dmesg)
journalctl -p err -b          # errors and worse, this boot
journalctl --since "22:45" --until "22:55"
journalctl --since "10 min ago"
journalctl -f                 # follow live, like tail -f
journalctl -g 'pattern'       # built-in grep
journalctl _PID=855           # everything one process logged
journalctl -o short-precise   # microsecond timestamps
journalctl -xe                # jump to the end with explanations
```

```bash
systemctl status <unit>           # state, last log lines, main PID
systemctl cat <unit>              # the unit file plus drop-ins
systemctl list-timers             # scheduled jobs, including systemd-run timers
systemctl --failed                # every failed unit
systemctl list-dependencies <unit>
systemd-analyze critical-chain <unit>   # what it waited for at boot
systemctl is-active / is-enabled <unit>
```

Other tools worth knowing:

```bash
dmesg -T | tail -50          # kernel ring buffer with readable times
ps -ef --forest              # process tree: who started what
ss -tlnp                     # listening TCP ports and their process
ss -xl                       # listening unix sockets
lsof -i :8006                # who holds a port
last -x | head               # reboots, shutdowns, logins
df -h ; df -i                # disk space and inodes
free -h ; uptime             # memory and load
```

---

## 4. Patterns that follow the same path

Recognise the pattern and you know where to look.

| Pattern | Typical clue in logs | Usual cause |
|---|---|---|
| **Two copies of one daemon** (this incident) | `already in use`, `Address already in use`, `cannot override`, `PID file exists` | Something started it twice: a hook and a service, two managers, a manual start plus systemd |
| **Works at boot, breaks on reload or restart** | Errors only at the reload timestamp | Script written to run once; reload is not idempotent |
| **Works by hand, fails at boot** | `Dependency failed`, device or address not found | Ordering: started before the network, the disk or another service. Fix with `After=` / `Wants=` |
| **Dies some time after start** | `Out of memory: Killed process` in `journalctl -k` | OOM killer; check `free -h`, memory limits |
| **Service "active" but nothing answers** | No error; `ss -tlnp` shows it listening on 127.0.0.1 or another port | Bind address or firewall, not the service |
| **Locked out after a config change** | Nothing, because you cannot log in | sshd, firewall or network config. Prevent with a syntax check and a rollback |
| **Everything slow or failing at once** | `No space left on device` | Disk or inodes full: `df -h`, `df -i` |
| **Name works for some, not others** | Timeouts, then success | DNS. Test by IP first: if IP works and the name does not, it is DNS |
| **Ping works, big transfers hang** | Stalls after connect | MTU or MSS: `ping -M do -s 1472 host` |
| **Traffic goes out, replies vanish** | Requests seen in tcpdump, no replies | Asymmetric routing, `rp_filter`, missing return route |

Ask two questions each time: **who started this process**, and **what else touched the same resource** (socket, port, file, interface, address)?

---

## 5. Safe change rules for remote servers

1. **Always have a second way in** that the change does not touch: console, IPMI/iDRAC, a serial line, a second network. Here: Wi-Fi while changing Ethernet.
2. **Arm an automatic rollback** before the change: `systemd-run --on-active=5min ...`, `at now + 5 min`, Cisco `reload in 10`, Juniper `commit confirmed`.
3. **Test the mechanism with a no-op first.** The rollback used the same command as the change, so it failed the same way. A no-op `ifreload -a` beforehand would have exposed the bug with nothing at stake.
4. **Check syntax before applying.** `sshd -t`, `nft -c -f file`, `nginx -t`, `ifreload -a -s`, `visudo -c`.
5. **One change at a time.** Two changes, one failure: you do not know which.
6. **Keep the current session open** and test with a new one. Never close the only working session.
7. **Back up the file first**, with a date in the name.
8. **Know the difference:** *reload* re-reads config without stopping; *restart* stops and starts. Restart drops connections.

---

## 6. Practice on the lab

Each takes ten minutes and builds the reflex. Snapshot or have console access first.

1. Stop a service and find the stop in the journal by time only: `journalctl --since "5 min ago"`.
2. Start a second listener on a used port (`nc -l 8006`) and read the `Address already in use` error. Find the owner with `ss -tlnp`.
3. Put a typo in a unit's drop-in, `daemon-reload`, restart, and read `systemctl status`.
4. Reboot, then find the previous boot's shutdown messages with `journalctl -b -1 -e`.
5. Arm a `systemd-run` timer that only writes a file, watch it in `systemctl list-timers`, then find its run in the journal.
6. Fill a small test filesystem and watch which services complain first.
