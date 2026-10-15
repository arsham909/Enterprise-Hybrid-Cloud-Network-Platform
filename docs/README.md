# Documents

Working documents kept during the build. The task lists are checklists with the real state ticked; open boxes are open work. Dates inside the files are when something was done or decided.

## Design

| File | What it is |
|---|---|
| [`HYBRID-SLICE-DESIGN.md`](HYBRID-SLICE-DESIGN.md) | The accepted design: machines, addresses, the six traffic flows, firewall changes, secrets, guarantees, shortcuts |
| [`HYBRID-SLICE-ROADMAP.md`](HYBRID-SLICE-ROADMAP.md) | The build checklist, block by block, with the re-plans |

## Per device

| Device | Tasks and reference config | Notes: concepts, commands, what went wrong |
|---|---|---|
| Cisco Catalyst 3750X | [`SWITCH-CONFIG.md`](SWITCH-CONFIG.md) | [`SWITCH-NOTES.md`](SWITCH-NOTES.md) |
| Proxmox host | [`PROXMOX-CONFIG.md`](PROXMOX-CONFIG.md) | [`PROXMOX-NOTES.md`](PROXMOX-NOTES.md) |
| OPNsense firewall | [`OPNSENSE-CONFIG.md`](OPNSENSE-CONFIG.md), [`OPNSENSE-MVP-RUNSHEET.md`](OPNSENSE-MVP-RUNSHEET.md) | [`OPNSENSE-NOTES.md`](OPNSENSE-NOTES.md) |

## Lessons

| File | Topic |
|---|---|
| [`LESSON-PROXMOX-NETWORKING.md`](LESSON-PROXMOX-NETWORKING.md) | Bridges, VLAN-aware bridges, bridged versus routed, the Wi-Fi uplink |
| [`LESSON-NFTABLES-NAT.md`](LESSON-NFTABLES-NAT.md) | nftables, forwarding and NAT on the host |
| [`LESSON-TROUBLESHOOTING.md`](LESSON-TROUBLESHOOTING.md) | The lockout on the Proxmox host and the method used to find its cause |
| [`TROUBLESHOOTING-LOG.md`](TROUBLESHOOTING-LOG.md) | Every real fault so far: symptom, layer by layer checks, root cause, fix, proof |
| [`evidence/`](evidence/README.md) | Raw command output and screenshots behind the proof tests |
| [`LESSON-QM-AUTOMATION.md`](LESSON-QM-AUTOMATION.md) | `qm`, templates and cloud-init |
| [`LESSON-ANSIBLE-PRIMER.md`](LESSON-ANSIBLE-PRIMER.md) | Ansible concepts before the lab |

## Block workbooks

One file per block of the roadmap: purpose, concepts, each command with what it does, verification, troubleshooting and a result log.

| File | State |
|---|---|
| [`blocks/BLOCK-01-TEMPLATE-AND-VMS.md`](blocks/BLOCK-01-TEMPLATE-AND-VMS.md) | Done |
| [`blocks/BLOCK-02-AWS-ACCOUNT.md`](blocks/BLOCK-02-AWS-ACCOUNT.md) | Nearly done |
| [`blocks/BLOCK-03-TERRAFORM.md`](blocks/BLOCK-03-TERRAFORM.md) | Lab in progress; the result log fills in as lessons are completed |
| [`blocks/BLOCK-05-ANSIBLE.md`](blocks/BLOCK-05-ANSIBLE.md) | Lab in progress |

## Names used in these files

- **Forge Hybrid** is the working name of this project.
- `FORGE-HYBRID-PLAN.md` is the original, larger plan. It is not published here; the slice design above replaces it.
- `forge-infra` in older notes means this repository.
