# Hybrid Slice — Design

**Status: ACCEPTED 2026-10-11**, all decisions D1–D10 as recommended, D6 in its revised form (release by pull request). Build steps: `HYBRID-SLICE-ROADMAP.md`. One reference file per finished block: `blocks/`.

The thin version of `FORGE-HYBRID-PLAN.md`: one home lab, one AWS server, a home-initiated VPN between them, and a pipeline that turns a `git push` into a live website.

---

## 1. Where we are (built and tested)

```text
internet ── home router 10.0.0.1 ┄Wi-Fi┄ Proxmox host (10.0.0.67 / 10.10.10.5)
                                           │ routes + NATs, forward policy drop
                                         OPNsense fw-01  (WAN 192.168.250.2)
                                           │ one trunk, tags 10/20/30
                                         Cisco 3750X
                         ┌─────────────────┼──────────────────┐
                    VLAN 10 MGMT      VLAN 20 SERVERS     VLAN 30 USERS
                    10.10.10.0/24     10.10.20.0/24       10.10.30.0/24
                    admin, full       internet only       internet only
                    access            (empty today)       DHCP
```

| Layer | State |
|---|---|
| Switch | VLANs, trunk, L2 security done. VTY ACL deferred |
| Proxmox | Wi-Fi uplink, bridges, NAT, forward-drop. Reboot-tested |
| OPNsense | Three zones routed, DHCP, DNS, minimum rules, proof passed, snapshot `opn-baseline` |
| Open | O4.7 (IPv6, 5 min), hardening block |

Rules in force today: MGMT may go anywhere. SERVERS and USERS may reach DNS, NTP and ping on the firewall, and the internet; they are blocked from the firewall's GUI and from every private network. Nothing is allowed in on WAN.

---

## 2. What gets added

### Machines

| Name | Where | Address | Size | Job | Holds secrets? |
|---|---|---|---|---|---|
| `ops-01` (VM 110) | Home, VLAN 10 MGMT | 10.10.10.20 | 2 cores, 2 GB, 20 GB | Control node: Terraform, Ansible, AWS CLI, git | **Yes**: AWS key, SSH key, Terraform state, app secrets |
| `svc-01` (VM 111) | Home, VLAN 20 SERVERS | 10.10.20.11 | 2 cores, 4 GB, 40 GB | Prometheus, Grafana, blackbox exporter | Grafana password only |
| `ci-01` (VM 112) | Home, VLAN 20 SERVERS | 10.10.20.12 | 2 cores, 4 GB, 60 GB | GitHub Actions runner, Docker builds | **No**, on purpose |
| `stg-01` (VM 113) *(D11, accepted 2026-10-11)* | Home, VLAN 20 SERVERS | 10.10.20.13 | 2 cores, 2 GB, 20 GB | Staging: the same GitOps agent and compose stack as production, reachable only from MGMT | Staging `.env` only |
| `web-01` | AWS `us-east-1` | 10.50.0.10 + Elastic IP | `t3.small`, 20 GB | Caddy, app, Postgres, GitOps agent, WireGuard endpoint | Its own WireGuard key, app `.env` |
| Template 9000 | Home | — | — | Ubuntu 24.04 cloud image all home VMs are cloned from | No |

Home RAM in use: 4 (firewall) + 2 + 4 + 4 = 14 GB of 32.

### External services

| Service | Used for |
|---|---|
| GitHub | Two public repos, Actions (the job queue), GHCR (image registry) |
| Cloudflare DNS | One record: `demo.arsham.codes` → Elastic IP, DNS only |
| Let's Encrypt | Certificate, fetched automatically by Caddy |

### Addresses added

| Network | Range | Members |
|---|---|---|
| AWS VPC | 10.50.0.0/16 | — |
| AWS public subnet | 10.50.0.0/24 | web-01 .10 |
| WireGuard tunnel | 10.10.99.0/30 | OPNsense .1, web-01 .2 |

No overlap with the lab (10.10.0.0/16), the home LAN (10.0.0.0/24) or the transit link (192.168.250.0/30).

---

## 3. The whole picture

```text
                                    ┌───────────── GitHub ──────────────┐
                                    │ app repo ─► Actions queue         │
                                    │ infra repo (deploy state)         │
                                    │ GHCR (images)                     │
                                    └───▲────────────▲──────────▲───────┘
                              push code │   poll jobs│          │ pull compose + image
                                        │   push img │          │
 ┌──────────────────────── HOME ────────┼────────────┼───┐   ┌──┼─────────── AWS us-east-1 ─────────────┐
 │                                      │            │   │   │  │   VPC 10.50.0.0/16                    │
 │  laptop ─ssh─► Proxmox ─► ops-01 ────┘            │   │   │  │   public subnet 10.50.0.0/24          │
 │                 host      10.10.10.20             │   │   │  │                                       │
 │                           Terraform ──────────────┼───┼───┼──┼──► AWS API (creates everything here)  │
 │                           Ansible ───┐            │   │   │  │                                       │
 │                                      │        ci-01   │   │ ┌┴───────────── web-01 ───────────────┐  │
 │   svc-01 10.10.20.11                 │   10.10.20.12  │   │ │ 10.50.0.10          Elastic IP      │  │
 │   Prometheus ── scrape ──┐           │   runner       │   │ │                                     │  │
 │   Grafana                │           │                │   │ │  Caddy :80/:443 ◄──────────────────┼──┼── users
 │                          ▼           ▼                │   │ │    └► app ─► Postgres              │  │
 │                   ┌──────────────────────────┐        │   │ │  GitOps agent (timer, 2 min)       │  │
 │                   │ OPNsense   wg 10.10.99.1 │════════╪═══╪═│  wg0 10.10.99.2   UDP 51820        │  │
 │                   └──────────────────────────┘ WireGuard  │ │  sshd :22, node exporter :9100     │  │
 │                    home starts it, keepalive 25 s     │   │ │   (reachable through the tunnel    │  │
 │                                                       │   │ │    only)                           │  │
 └───────────────────────────────────────────────────────┘   │ └────────────────────────────────────┘  │
                                                             │ Security group IN: 80, 443, UDP 51820   │
                                                             │                    nothing else         │
                                                             └─────────────────────────────────────────┘
```

Three sentences that describe it:

1. **Users talk only to AWS.** Home serves nobody.
2. **Home talks to AWS through a tunnel that home opens.** AWS cannot open anything towards home.
3. **Code reaches production through git.** Nobody logs in to deploy.

---

## 4. The six flows

### Flow 1: A visitor opens the site

```text
browser ─► Cloudflare DNS: demo.arsham.codes = Elastic IP
browser ─► web-01 :443 ─► Caddy (TLS) ─► app container ─► Postgres container
```

Home is not involved. If the home lab is switched off, the site stays up.

### Flow 2: The tunnel

```text
OPNsense 192.168.250.2 ─UDP─► Proxmox NAT ─► home router NAT ─► Elastic IP :51820
        tunnel inside:  10.10.99.1 ⇄ 10.10.99.2
        routed through it:  10.10.0.0/16 (home lab)  ⇄  10.50.0.0/16 (AWS)
```

- OPNsense knows web-01's address and calls it. web-01 has no address for home and learns it only from the packets that arrive, so it cannot call first.
- A keepalive every 25 seconds holds the three NAT mappings open.
- Inside the tunnel, OPNsense blocks and logs everything that AWS tries to start. Replies to home's own connections pass by state.

Key handling: each side makes its own key pair and only public keys are exchanged. web-01 generates its pair at first boot and prints the public half to its console log, where the AWS CLI reads it. No private key is ever in git, in Terraform or in transit.

### Flow 3: Administration

```text
laptop ─ssh─► Proxmox host 10.0.0.67 ─► ops-01 ─┬─► ci-01, svc-01      (through OPNsense, MGMT → SERVERS)
                                                └─► web-01 10.50.0.10  (through OPNsense, into the tunnel)
```

- Port 22 on web-01 is closed in the AWS security group. SSH works only from inside the tunnel.
- Terraform is the exception: it does not log in to servers. It calls the AWS API over HTTPS from ops-01.

### Flow 4: Build (CI)

```text
git push (app repo) ─► GitHub Actions queues a job
ci-01 runner (already connected outbound, waiting) takes the job
   build image ─► start it, check /healthz ─► push to GHCR, tagged with the commit
   then: commit the new image digest into the infra repo (deploy/web/compose.yml)
```

The runner never accepts a connection. It holds an outbound connection to GitHub and waits.

### Flow 5: Deploy (GitOps, pull)

```text
web-01, every 2 minutes:
   git pull infra repo
   deploy/web changed?  no ─► stop
                        yes ─► docker compose pull, up -d
                               curl /healthz   ok ─► done
                                               fail ─► return to the previous commit, up -d
```

- The infra repo is the single statement of what should be running. The server makes itself match it.
- web-01 needs no credentials (public repo, public images) and no inbound deploy port.
- A rollback is a `git revert`.

### Flow 6: Monitoring

```text
svc-01 Prometheus ─scrape :9100─► ops-01, ci-01, svc-01      (home)
                  ─scrape :9100─► web-01                      (through the tunnel)
       blackbox   ─HTTPS probe──► https://demo.arsham.codes   (out through the internet, like a visitor)
laptop ─ssh -L 3000─► ops-01 ─► svc-01 Grafana :3000
```

Prometheus pulls, so home opens every connection. Grafana is not published anywhere.

---

## 5. Firewall changes

### OPNsense

New aliases: `NET_AWS` 10.50.0.0/16 · `HOST_OPS01` 10.10.10.20 · `HOST_SVC01` 10.10.20.11.

| Interface | Rule | Why |
|---|---|---|
| **AWS** (new, the WireGuard tunnel) | Block + log, any → any, inbound | AWS may start nothing. The log is the proof |
| MGMT | No change (already pass to any) | Covers ops-01 → web-01 and ops-01 → home VMs |
| SERVERS, above the two blocks | Pass `HOST_SVC01` → `HOST_OPS01` TCP 9100 | Prometheus scrapes the control node |
| SERVERS, above the two blocks | Pass `HOST_SVC01` → `NET_AWS` TCP 9100 | Prometheus scrapes web-01 through the tunnel |
| SERVERS | Everything else unchanged | ci-01 gets internet only: GitHub and GHCR |
| USERS | No change | The `RFC1918` block already covers AWS and the tunnel |
| WAN | No change, still empty | The tunnel is outbound; replies pass by state |

Who can reach what, after the change:

| From ↓ / To → | Internet | MGMT | SERVERS | USERS | AWS (tunnel) | Firewall GUI |
|---|---|---|---|---|---|---|
| MGMT (ops-01, admin) | yes | — | yes | yes | yes | yes |
| ci-01 | yes | no | same VLAN | no | **no** | no |
| svc-01 | yes | ops-01:9100 only | same VLAN | no | :9100 only | no |
| USERS | yes | no | no | — | no | no |
| AWS web-01 | yes (its own) | **no** | **no** | **no** | — | **no** |

### AWS security group on web-01

| Direction | Port | Source | Why |
|---|---|---|---|
| In | TCP 80, 443 | Anywhere | The website; port 80 also for the certificate challenge |
| In | UDP 51820 | Anywhere | WireGuard. It stays silent to anyone without the right key, and it must keep working when the home IP changes |
| In | Everything else, including 22 and 9100 | — | Closed |
| Out | All | Anywhere | Updates, GitHub, GHCR |

### Unchanged

Proxmox nftables (the tunnel is ordinary outbound UDP from OPNsense, already allowed and NATed) and the switch (all new VMs sit behind the trunk).

---

## 6. Where each secret lives

| Secret | Lives on | How it got there |
|---|---|---|
| AWS admin access key | ops-01, `~/.aws/` | Typed once into `aws configure` |
| Terraform state | ops-01, in the repo folder, git-ignored | Written by Terraform |
| SSH private keys | Laptop (its own), ops-01 (its own) | Generated in place, never copied |
| WireGuard private keys | OPNsense, web-01 | Generated in place, never copied |
| App secrets (`.env`) | ops-01 (source), web-01 (copy) | Ansible copies it over the tunnel |
| Token that lets CI update the infra repo | GitHub Actions secret in the app repo | Fine-grained token, one repo, contents only |
| Grafana admin password | svc-01 | Set at first login |

Never in git: state, `*.tfvars`, any private key, `.env`, OPNsense `config.xml`, the home public IP. ci-01 holds none of the above; it runs code from a public repo, so it is treated as untrusted.

---

## 7. Repositories

```text
Enterprise-Hybrid-Cloud-Network-Platform   (exists, public, empty except README) = infra
├── README.md              pitch, diagram, how it works
├── docs/                  design, decisions, journal, sanitized switch and host configs
├── terraform/aws/         VPC, security group, web-01, user data
├── ansible/               inventory, playbooks: base, docker, exporters, gitops-agent, monitoring
├── deploy/web/            compose.yml + Caddyfile, images pinned by digest   ← what production runs
├── monitoring/            Prometheus, Grafana and blackbox config for svc-01
└── .gitignore             state, tfvars, keys, env

forge-app   (new, public) = application
├── app/                   placeholder first, real apps after
├── Dockerfile
└── .github/workflows/ci.yml
```

---

## 8. What this design guarantees

1. **Nothing can connect into home.** No port forward, no inbound WAN rule, three NATs, and an explicit block on the tunnel.
2. **AWS exposes three ports**: 80, 443 and the VPN.
3. **SSH and metrics on AWS are reachable only through the tunnel.**
4. **The machine that runs untrusted code (ci-01) holds no secrets** and its zone can reach only the internet.
5. **A compromised web-01 gains nothing at home**: it sits at the end of a tunnel whose home side drops everything it starts.
6. **Production is whatever the infra repo says.** Every change and every rollback is a commit.
7. **The public site does not depend on home.** Lose the home link and only deploys and monitoring pause.

## 9. Shortcuts taken, and their price

| Shortcut | Risk | Fix later |
|---|---|---|
| One EC2 for web, database and VPN endpoint | Single point of failure; the internet-facing host is also the tunnel endpoint | Split into web / vpn-gw / private data tier (the original plan) |
| Database on the same host, no backups | Data loss if the instance dies. Demo data only | Nightly `pg_dump`; the plan's on-prem system of record |
| Long-lived AWS admin key on ops-01 | Full account access if ops-01 is compromised | Short-lived credentials, a limited role for Terraform |
| Terraform state on ops-01's disk | Lose the VM, lose track of what was created | S3 backend with versioning, or a Proxmox backup job for ops-01 |
| Origin IP public, no Cloudflare proxy or WAF | Direct scanning of web-01 | Proxy on, security group limited to Cloudflare ranges |
| Self-hosted runner on a public repo | A malicious pull request could run code on ci-01 | Already limited: jobs only for pushes to main, fork PRs need approval, ci-01 has no secrets and no route to MGMT or AWS |
| No break-glass login if the tunnel never comes up | web-01 unreachable for SSH | It is disposable: `terraform destroy` and `apply` rebuild it. A Terraform variable can also open port 22 to the home IP for a few minutes |
| Home uplink is Wi-Fi through three NATs | Tunnel drops when Wi-Fi does | Accepted; the site stays up without it |

## 10. Build order

One change from the earlier roadmap: OPNsense's WireGuard key pair is created before Terraform runs, because web-01 needs OPNsense's public key at first boot.

```text
1  template, ops-01, ci-01, svc-01          cloud-init
2  AWS account preparation                  console, CLI
3a OPNsense WireGuard instance (keys only)  OPNsense
3b VPC, security group, web-01              Terraform
4  peer, tunnel up, rules, direction proof  OPNsense
5  base, Docker, exporters on all hosts     Ansible
── Monday ──
6  repos, placeholder app
7  runner and CI
8  GitOps agent
9  DNS and TLS
10 monitoring
11 real apps
12 README, screenshots
```

## 11. Developer workflow: who can change what

Two words, used precisely from here on:

- **The deploy state** is one folder in the infra repo: `deploy/web/`. It says which image, by digest, should be running.
- **Production** is web-01 running whatever that folder says. Nobody pushes to production. Production pulls.

So "who can deploy" is the same question as "who can change `deploy/web/` on the infra repo's main branch".

### The path of one change

```text
 developer's machine
      │ 1. git push  (a feature branch, never main)
      ▼
 app repo ── pull request ──► CI on ci-01: build, start, check /healthz     GATE 1  tests pass
      │
      │ 2. a maintainer reviews and merges                                  GATE 2  code review
      ▼
 app repo main ──► CI on ci-01: build image, push to GHCR, read its digest
      │
      │ 3. the CI bot opens a pull request on the infra repo:
      │       deploy/web/compose.yml   image digest  A  →  B
      ▼
 infra repo ── pull request ── a maintainer merges                          GATE 3  release approval
      ▼
 infra repo main  =  what production should be
      │
      │ 4. within 2 minutes, pulled by web-01
      ▼
 web-01 agent: pull image, restart, check /healthz                          GATE 4  health
      │ fail ─► back to the previous commit, automatically
      ▼
 live
```

### Who can do what

| Actor | Read code | Push a branch to the app repo | Merge to app `main` | Change `deploy/web/` on infra `main` | Log in to web-01 | AWS account |
|---|---|---|---|---|---|---|
| Anyone on the internet | yes (public) | no; fork and open a pull request | no | no | no | no |
| Developer (collaborator on the app repo) | yes | yes | no; needs a maintainer's approval | no | no | no |
| Maintainer (you) | yes | yes | yes, after CI passes | yes, by merging the bot's pull request | through ops-01 only | yes |
| CI bot (a token in the app repo's secrets) | — | — | no | may **open** a pull request, cannot merge it | no | no |
| ci-01 (the runner) | — | — | — | no | no route | no |
| web-01 (the agent) | reads the infra repo | — | — | no; it has no write credentials at all | — | no |

How GitHub enforces it:

- **Branch protection on both `main` branches:** no direct pushes, a pull request is required, the CI check must pass, one approval.
- **The bot's token** is fine-grained: one repository (infra), permission to write contents on its own branch and open pull requests. It cannot approve or merge.
- **Fork pull requests** do not run on the home runner until a maintainer approves the run.
- **Production secrets** (`.env`) exist only on ops-01 and web-01. A developer never needs or sees them.

Today you hold every role. The value of drawing it this way is that adding a second developer is one invitation on the app repo, and nothing about production access changes.

### Everyday cases

| Situation | What happens |
|---|---|
| Normal feature | Branch, pull request, merge, bot's pull request, merge. Live in minutes |
| A bad release reaches production | The health gate rolls it back by itself. Then `git revert` the digest change so git matches reality |
| Roll back a release that is healthy but wrong | Revert the digest commit in the infra repo. The agent applies it |
| Change server configuration (Caddy, ports, a new service) | Edit `deploy/web/` in a pull request on the infra repo. Same gate 3, same agent |
| Change the infrastructure (instance size, security group) | Edit `terraform/`, pull request, then `terraform apply` from ops-01 by a maintainer |
| Emergency fix on the server | SSH from ops-01 is possible, but the agent will put back whatever git says within 2 minutes. The fix has to go through git |

Not in the slice: a separate staging environment. The CI job starts the container on ci-01 and checks it before pushing, which is the only pre-production test for now. A `deploy/staging/` folder with its own small target is the natural next step.

## 12. Decisions (accepted 2026-10-11)

| # | Decision | Alternative |
|---|---|---|
| D1 | Control node `ops-01` in MGMT, separate from ci-01 | Run tools on ci-01 (faster, unsafe) or on the laptop |
| D2 | Monitoring on `svc-01` at home, pull through the tunnel | Monitoring on AWS (costs RAM there, and would need exposing or another tunnel path) |
| D3 | One EC2 instance for web, database and tunnel endpoint | Two or three instances (plan), about 2–3 more hours |
| D4 | WireGuard keys generated in place; web-01's public key read from its console log | Generate both on ops-01 and pass the private key through Terraform (simpler, but the key sits in state) |
| D5 | No SSH from the internet at all; rebuild if the tunnel never forms | Keep port 22 open to the home IP |
| D6 | **Revised:** CI opens a pull request on the infra repo and a maintainer merges it. This is the release approval (gate 3 in section 11). About 15 more minutes to set up, one click per deploy | CI commits straight to the infra repo's main branch: fully automatic, but then anyone who can merge app code can release to production |
| D7 | Terraform state local on ops-01 for now | S3 backend today, about 20 more minutes |
| D8 | Caddy with Let's Encrypt, DNS only | Cloudflare proxy from day one, about 45 more minutes |
| D9 | Terraform and Ansible code is written by hand on ops-01 as a learning exercise, pushed, then reviewed (`blocks/BLOCK-03-TERRAFORM.md`, `blocks/BLOCK-05-ANSIBLE.md`). ops-01 pulls the repo; nothing is run from the laptop. CI and the GitOps agent are decided per block | Paste finished files onto ops-01 |
| D10 | VM IDs 110 / 111 / 112, addresses as listed, app repo name `forge-app` | Your choice |
| D11 | **Accepted 2026-10-11.** A staging host `stg-01` at home. The GitOps agent deploys `deploy/staging/` there first; production (`deploy/web/` on web-01) is a second target of the same pipeline. Lets blocks 6–8 be built while AWS is unreachable, and closes the "no staging" gap from section 11 | No staging: wait for AWS before building the deploy agent |
