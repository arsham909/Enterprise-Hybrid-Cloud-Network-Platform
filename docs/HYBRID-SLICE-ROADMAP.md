# Hybrid Slice Roadmap — Sunday 2026-10-11 to Monday 2026-10-12

The thin version of `FORGE-HYBRID-PLAN.md` Days 2–5. One goal: by Monday night, a `git push` goes live at `https://demo.arsham.codes`, built at home, running on AWS, administered only through the home-initiated VPN.

Task IDs (`B3.2`) are there so a single task can be asked about by name. Design: `HYBRID-SLICE-DESIGN.md` (accepted 2026-10-11). Each block gets its own reference file in `blocks/` with the reasons, the commands, and troubleshooting; this file is the checklist.

---

## The picture

```text
 ┌──────────── HOME ────────────┐                ┌──────────── AWS us-east-1 ──────────────┐
 │ ops-01 10.10.10.20 (VLAN 10) │                │ VPC 10.50.0.0/16, public subnet /24     │
 │  Terraform, Ansible, AWS CLI │                │  web-01  (one EC2, t3.small, 10.50.0.10)│
 │ ci-01 10.10.20.12 (VLAN 20)  │   WireGuard    │   Caddy :443 ─► app ─► Postgres         │
 │  GitHub runner only          ├───────────────►│   GitOps pull agent (systemd timer)     │
 │ svc-01 10.10.20.11 (VLAN 20) │ home initiates │   WireGuard 10.10.99.2, UDP 51820       │
 │  Prometheus, Grafana         │  home scrapes  │   node exporter :9100 (tunnel only)     │
 │ OPNsense 10.10.99.1          │                │                                         │
 └──────────────────────────────┘                └─────────────────────────────────────────┘
        ▲ git push                                        ▲ pulls image + compose
        └──────────── GitHub: repos, Actions, GHCR ───────┘
```

The laptop is only a screen and keyboard:

```text
laptop (home Wi-Fi) ─ssh─► Proxmox host 10.0.0.67 ─► ops-01 10.10.10.20 ─┬─► ci-01 10.10.20.12
                                                                         └─► tunnel ─► web-01 10.50.0.10
```

## Decisions

| Topic | Choice | Reason |
|---|---|---|
| Scope | One EC2 instance; no private tier, no sync worker | Fits two days. Splitting into web / vpn-gw / data is a Terraform change later |
| Region | `us-east-1` (N. Virginia) | Changed from `ca-central-1` on 2026-10-12, my choice |
| Instance | `t3.small`, about $20/month with its public IPv4 | Django and Postgres need 2 GB |
| SSH to AWS | Not open to the internet; only through WireGuard | A real job for the tunnel |
| Terraform, Ansible | Run on **ops-01**, a control VM in MGMT (chosen 2026-10-11) | Nothing lives on the laptop; MGMT may reach every zone and AWS |
| Control node separate from ci-01 | Yes | ci-01 runs CI jobs from a public repo. AWS admin keys, SSH keys and Terraform state must not sit on a machine that executes repository code |
| Jump path | Proxmox host, then ops-01 | From ops-01 everything is direct |
| Home VMs | cloud-init by hand; Terraform for AWS only | Chosen 2026-10-11 |
| Repos | Infra in `Enterprise-Hybrid-Cloud-Network-Platform` (existing, public); app in a new repo | Chosen 2026-10-11 |
| Images | Public on GHCR | web-01 pulls with no token |
| TLS | Caddy with Let's Encrypt first; Cloudflare proxy later | Fifteen minutes |
| App | Placeholder with `/healthz` first, real apps swapped in after the pipeline works | The pipeline is the demo; the app is the passenger |
| Data | Demo data only on AWS | The "PII stays at home" design stays on the roadmap |
| Monitoring | Prometheus and Grafana on **svc-01** at home; exporters on every host, AWS scraped through the tunnel (added 2026-10-11) | Prometheus pulls, so home starts every connection and AWS never calls home. Grafana is never exposed; reached by SSH tunnel |
| Hardening | After Monday | Chosen 2026-10-11 |

Addresses added by this slice:

| Thing | Address |
|---|---|
| ops-01 (VM 110) | 10.10.10.20/24, gateway and DNS 10.10.10.1 |
| svc-01 (VM 111) | 10.10.20.11/24, gateway and DNS 10.10.20.1 |
| ci-01 (VM 112) | 10.10.20.12/24, gateway and DNS 10.10.20.1 |
| AWS VPC / public subnet | 10.50.0.0/16 / 10.50.0.0/24 |
| web-01 private | 10.50.0.10 |
| WireGuard tunnel | 10.10.99.0/30: OPNsense .1, web-01 .2 |
| Public name | `demo.arsham.codes` → web-01 Elastic IP |

**Never in git:** `terraform.tfstate`, `*.tfvars`, WireGuard private keys, AWS keys, `.env` files, OPNsense `config.xml`, the home public IP.

## Schedule

| When | Blocks | Hours |
|---|---|---|
| Sunday | 1 template + ops-01 + ci-01 + svc-01 · 2 AWS prep · 3 Terraform · 4 WireGuard · 5 Ansible (with node exporters) | about 7 |
| Monday | 6 repo + placeholder · 7 CI at home · 8 GitOps deploy · 9 public URL · 10 monitoring · 11 real apps · 12 packaging | about 8.5–11.5 |

Monday is full. Cut order if behind: depth of block 11 (show the placeholder plus one simple app) → monitoring levels 2 and 3 → block 9 (show by IP) → polish in block 12. Never cut 4, 7 or 8. Monitoring level 1 stays because its exporters are already installed on Sunday.

## Re-plan, 2026-10-11 evening: AWS account unreachable

The AWS account cannot be reached and is with AWS support. Everything that does not need AWS moves forward, and a staging host at home (`stg-01`, design D11) lets the whole pipeline be built and tested before AWS exists.

| Order | Block | Needs AWS? | State |
|---|---|---|---|
| 1 | Template, ops-01, ci-01, svc-01 | no | done |
| 5 | Ansible on the home hosts (plus `stg-01`) | no | **now** |
| 6 | Repos and placeholder app | no | next |
| 7 | CI at home: runner, build, GHCR | no | next |
| 8 | GitOps agent, deploying to `stg-01` first | no | next |
| 10 | Monitoring level 1 for the home hosts | no | next |
| 3 (prep) | OPNsense WireGuard keys; Terraform files written and validated | no | next |
| 2 | AWS account preparation | **yes** | waiting for support |
| 3 | `terraform apply` | **yes** | after 2 |
| 4 | WireGuard tunnel | **yes** | after 3 |
| — | Add web-01 to Ansible, the agent and Prometheus | **yes** | about 1 hour once it exists |
| 9 | DNS and TLS | **yes** | after 3 |
| 11, 12 | Real apps, packaging | staging: no | Monday |

If AWS access takes longer than a day, the demo still exists: push, build at home, automatic deploy to staging, health-gated rollback, monitoring. Production then becomes a second target of the same pipeline.

## Re-plan, 2026-10-12: AWS account is back

The account is reachable again. Decided the same day: region `us-east-1`; Terraform is written by me as a lab, like Ansible; Terraform and Ansible come first, and the WireGuard block is not done tonight. `stg-01` stays in the design: staging first, production second.

| Order | Block | Hours | State |
|---|---|---|---|
| 1 | Template, ops-01, ci-01, svc-01 | 1.5 | done |
| 2 | AWS account preparation | 0.1 left | identity, MFA and key confirmed; open: B2.3, B2.5 (budget to 25 USD, credits excluded), B2.8 |
| 3 | AWS network and server, Terraform lab (9 lessons) | 4–5 (estimate) | **tonight, first**; lesson 0 in progress |
| 5 | Ansible lab (10 lessons) | 4–6 (estimate) | after Terraform; started 2026-10-11 |
| 4 | WireGuard tunnel, home to AWS, with Terraform lesson 9 (user data) | 2 | not tonight |
| 6 | App repo and placeholder app | 0.75 | |
| 7 | CI at home: runner, build, GHCR | 1.5 | |
| 8 | GitOps agent: staging, then web-01 | 1.5 | |
| — | web-01 into Ansible, the agent and Prometheus | 1 | needs block 4 |
| 9 | DNS and TLS | 0.75 | |
| 10 | Monitoring level 1 | 1.5 | |
| 11 | Real apps | 1–4 | |
| 12 | Packaging | 1.5 | |
| | **Left to do** | **about 20–26** | |

Optional on top: monitoring level 2 (0.75 h) and level 3 (1 h).

Until block 4 exists, web-01 has no SSH path: port 22 is closed and there is no tunnel. Terraform does not need one. For a look inside, the break-glass variable from Terraform lesson 5 opens port 22 to the home address for a few minutes. Ansible works on the home hosts meanwhile.

---

## Block 1: Template, ops-01 and ci-01 (1.5 h) — cloud-init

**Learn:** cloud images, the cloud-init drive, templates and clones, a control node.

- [x] **B1.1** Copy the laptop's public key to the host. `qm` reads keys from a file on the host and cloud-init installs them in each new VM.
  ```bash
  scp ~/.ssh/id_ed25519.pub root@10.0.0.67:/root/lab-keys.pub
  ```
- [x] **B1.2** Build the template (on the host, once).
  ```bash
  cd /var/lib/vz/template/iso
  wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

  qm create 9000 --name ubuntu-2404-tmpl --ostype l26 --cores 2 --memory 2048 \
    --scsihw virtio-scsi-single --net0 virtio,bridge=vmbr1,tag=20
  qm set 9000 --scsi0 local-lvm:0,import-from=/var/lib/vz/template/iso/noble-server-cloudimg-amd64.img,discard=on,ssd=1
  qm set 9000 --ide2 local-lvm:cloudinit
  qm set 9000 --boot order=scsi0 --serial0 socket --vga serial0
  qm template 9000
  ```
  - The cloud image is a ready-installed disk with cloud-init inside; no installer runs.
  - `import-from` copies the image in as the VM's disk. `ide2 ...cloudinit` is the instruction drive.
  - The serial console is what cloud images expect, and makes `qm terminal` work.
  - No `--agent 1`: the agent is not in the image yet.
- [x] **B1.3** Clone **ops-01**, the control node, into MGMT (on the host).
  ```bash
  qm clone 9000 110 --name ops-01 --full
  qm resize 110 scsi0 20G
  qm set 110 --cores 2 --memory 2048 --onboot 1 --startup order=2 \
    --net0 virtio,bridge=vmbr1,tag=10 \
    --ciuser arsham --sshkeys /root/lab-keys.pub \
    --ipconfig0 ip=10.10.10.20/24,gw=10.10.10.1 --nameserver 10.10.10.1 --searchdomain lab
  qm set 100 --startup order=1,up=60
  qm start 110
  ```
  - `--net0 ...tag=10` overrides the template's VLAN 20: this VM is an access port in MGMT.
  - `--ciuser`, `--sshkeys`, `--ipconfig0`, `--nameserver` are written to the instruction drive and applied at first boot.
  - `up=60` on the firewall: after a host reboot it gets 60 seconds before the other VMs start.
- [x] **B1.4** Laptop `~/.ssh/config`, so the jump through the host is automatic:
  ```text
  Host pve
      HostName 10.0.0.67
      User root

  Host ops-01
      HostName 10.10.10.20
      User arsham
      ProxyJump pve
  ```
  Then `ssh ops-01`. Inside: `cloud-init status --wait` says done, `hostname` is `ops-01`, `ping -c2 github.com` works.
- [x] **B1.5** Tools on ops-01.
  ```bash
  sudo apt update && sudo apt -y upgrade
  sudo apt -y install ansible git gh tmux unzip wireguard-tools qemu-guest-agent
  sudo snap install aws-cli --classic
  wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
  echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com noble main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
  sudo apt update && sudo apt -y install terraform
  terraform version && ansible --version | head -1 && aws --version
  ```
  - Terraform comes from HashiCorp's own package repository; the two lines before it add that repository and its signing key.
  - `wireguard-tools` gives `wg genkey` for block 3. `tmux` keeps a session alive when the laptop sleeps.
  - Then on the host: `qm set 110 --agent 1`, and `qm reboot 110`.
- [x] **B1.6** ops-01 gets its own SSH identity, and that key is added to the list for future VMs.
  ```bash
  # on ops-01
  ssh-keygen -t ed25519 -C ops-01 -f ~/.ssh/id_ed25519
  # on the laptop
  ssh ops-01 cat .ssh/id_ed25519.pub | ssh pve 'cat >> /root/lab-keys.pub'
  ssh pve cat /root/lab-keys.pub      # two lines: laptop, ops-01
  ```
  A private key never leaves the machine it was made on. ops-01 logs in to other servers as itself.
- [x] **B1.7** Clone **ci-01** into SERVERS (on the host). It is needed from block 7; cloning now takes two minutes.
  ```bash
  qm clone 9000 112 --name ci-01 --full
  qm resize 112 scsi0 60G
  qm set 112 --cores 2 --memory 4096 --onboot 1 --startup order=3 \
    --ciuser arsham --sshkeys /root/lab-keys.pub \
    --ipconfig0 ip=10.10.20.12/24,gw=10.10.20.1 --nameserver 10.10.20.1 --searchdomain lab
  qm start 112
  ```
- [x] **B1.8** From ops-01: `ssh arsham@10.10.20.12` works (MGMT may reach SERVERS), and ci-01 pings github.com.
- [x] **B1.10** Clone **svc-01**, the monitoring host, into SERVERS (on the host). Used from block 10.
  ```bash
  qm clone 9000 111 --name svc-01 --full
  qm resize 111 scsi0 40G
  qm set 111 --cores 2 --memory 4096 --onboot 1 --startup order=3 \
    --ciuser arsham --sshkeys /root/lab-keys.pub \
    --ipconfig0 ip=10.10.20.11/24,gw=10.10.20.1 --nameserver 10.10.20.1 --searchdomain lab
  qm start 111
  ```
- [x] **B1.9** GitHub login on ops-01: `gh auth login` (HTTPS, device code in the laptop's browser), then `gh auth setup-git`.

No login? `qm terminal 110` on the host shows the boot and the cloud-init output (exit with Ctrl+O).

**Working from the laptop without running anything on it:** `ssh ops-01`, then `tmux new -A -s main`. VS Code's Remote-SSH extension also works through the same `ssh ops-01` entry and edits files directly on the VM.

## Block 2: AWS preparation (45 min) — console and CLI (`blocks/BLOCK-02-AWS-ACCOUNT.md`)

**Learn:** root versus IAM, MFA, budgets, CLI profiles.

The root login can do anything, including closing the account, and cannot be restricted. It is used to set up one admin user and then put away.

- [x] **B2.1** Root MFA. Console → account name (top right) → Security credentials → Multi-factor authentication → Assign MFA device → Authenticator app. Scan the code, enter two consecutive codes.
- [x] **B2.2** Root has no access keys. Same page → Access keys: the list must be empty. Delete any that exist.
- [ ] **B2.3** Let IAM users see billing. Account name → Account → "IAM user and role access to Billing information" → Edit → Activate.
- [x] **B2.4** Billing and Cost Management → Credits: note the amount and the expiry date. Note whether the account is on the **free plan** or the **paid plan**.
- [ ] **B2.5** Budget. Billing and Cost Management → Budgets → Create budget → Customize → Cost budget, monthly, amount `25` USD, alerts at 50 %, 80 % and 100 % of actual cost to your email.
  - With credits applied the net cost stays zero and the alert never fires. In the budget's advanced options, exclude **Credits** so it follows real usage.
- [x] **B2.6** Admin user. IAM → Users → Create user: name `arsham-admin`, console access on, attach the policy `AdministratorAccess` directly. Add MFA to this user too (user → Security credentials). Create an account alias on the IAM dashboard.
- [x] **B2.7** Access key for the CLI. User → Security credentials → Create access key → Command Line Interface. The secret is shown once; copy it straight into B2.9, not into a file.
  - A long-lived key is the simple choice for this weekend. The hardening block replaces it with short-lived credentials.
- [ ] **B2.8** Sign out of root. Sign in as `arsham-admin` with MFA from now on. Region selector: **US East (N. Virginia)**.
- [x] **B2.9** CLI profile on **ops-01** (the AWS CLI was installed in B1.5).
  ```bash
  aws configure --profile forge      # key, secret, region us-east-1, output json
  chmod 600 ~/.aws/credentials
  echo 'export AWS_PROFILE=forge' >> ~/.bashrc && source ~/.bashrc
  aws sts get-caller-identity
  ```
  - A profile is a named set of credentials and defaults in `~/.aws/`. Terraform reads the same files.
  - `sts get-caller-identity` answers "who am I": the ARN must end in `user/arsham-admin`, not `root`.
- [x] **B2.10** Look around with the CLI: zones, the default VPC, no instances, the budget (commands in the block file).
- **Accept:** `aws sts get-caller-identity` on ops-01 shows `user/arsham-admin`, and `describe-instances` returns `[]`.

---

## Block 3: AWS network and server — Terraform, written by hand as a lab (`blocks/BLOCK-03-TERRAFORM.md`)

**Learn:** providers, state, plan and apply, variables and outputs, references, data sources, drift; VPC, subnet, internet gateway, route table, security group, EC2, Elastic IP.

One box per lesson. The tasks, checks and questions are in the block file.

- [ ] **B3.0** Lesson 0: folder `terraform/aws/`, proof that git ignores state and tfvars, zones that offer `t3.small`.
- [ ] **B3.1** Lesson 1: versions, provider, `init`, lock file, an empty plan.
- [ ] **B3.2** Lesson 2: the VPC 10.50.0.0/16; state; destroy and re-create.
- [ ] **B3.3** Lesson 3: variables, locals, outputs, default tags `Project=forge-hybrid`.
- [ ] **B3.4** Lesson 4: public subnet 10.50.0.0/24, internet gateway, route table, association.
- [ ] **B3.5** Lesson 5: security group: 80 and 443 from anywhere, UDP 51820 from anywhere, **no port 22**, all outbound; break-glass variable for port 22.
- [ ] **B3.6** Lesson 6: Ubuntu 24.04 image by lookup; key pair from ops-01's public key.
- [ ] **B3.7** Lesson 7: instance `t3.small`, private IP 10.50.0.10, 20 GB gp3, Elastic IP, outputs.
- [ ] **B3.8** Lesson 8: drift, in-place change versus replacement, saved plan, destroy.
- **Accept:** `terraform plan` a second time reports no changes; port 22 from the internet times out.

## Block 4: The hybrid link (1.5 h) — OPNsense WireGuard

**Learn:** key pairs and peers, AllowedIPs as both filter and route, keepalive through NAT, rules by direction.

- [ ] **B4.1** Snapshot the firewall.
- [ ] **B4.1a** On OPNsense, create the WireGuard instance (keys and tunnel address only). Its **public** key goes into the git-ignored `terraform.tfvars`. (Moved from block 3 on 2026-10-12.)
- [ ] **B4.1b** Terraform lesson 9, user data: install WireGuard, generate a key pair on the instance, write `wg0` with address 10.10.99.2/30 and OPNsense's public key as the peer, enable it, print the instance's public key to the console log (design D4). Apply; web-01 is replaced. (Moved from block 3 on 2026-10-12.)
- [ ] **B4.2** Read web-01's public key from its console log: `aws ec2 get-console-output --latest`.
- [ ] **B4.3** Peer: web-01's public key, endpoint Elastic IP:51820, allowed IPs 10.50.0.0/16 and 10.10.99.0/30, keepalive 25.
- [ ] **B4.4** Enable; assign the WireGuard device as interface `AWS`; alias `NET_AWS`.
- [ ] **B4.5** Rules. Interface `AWS`: block and log everything inbound. Nothing to add for ops-01: MGMT already passes to any. SERVERS stays blocked from AWS by its `RFC1918` rule until CI needs a path.
- [ ] **B4.6** Handshake visible on both ends; `ssh` from ops-01 to 10.50.0.10 works.
- [ ] **B4.7** Direction proof: from web-01, `ping 10.10.10.20` and `ping 10.10.20.12` fail and the blocks show in Live View.
- [ ] **B4.8** `~/.ssh/config` on ops-01: hosts `ci-01` and `web-01`.
- **Accept:** `ssh web-01` from ops-01 works with port 22 closed on the internet side.

## Block 5: Configure the servers — Ansible, written by hand as a lab (`blocks/BLOCK-05-ANSIBLE.md`)

**Learn:** inventory, modules, playbooks, idempotency, check mode, connecting through jump hosts.

- [ ] **B5.0** Clone `stg-01` (VM 113, 10.10.20.13) as the staging host (design D11).
- [ ] **B5.1** `ansible/` on ops-01: `ansible.cfg`, inventory with `ops-01` (local), `ci-01`, `svc-01` and `web-01`.
- [ ] **B5.2** `ansible all -m ping`.
- [ ] **B5.3** Playbook `base.yml`: updates, time zone, `qemu-guest-agent` on ci-01, unattended security updates.
- [ ] **B5.4** Playbook `docker.yml`: Docker Engine and the compose plugin on both, user in the `docker` group.
- [ ] **B5.5** Playbook `exporters.yml`: `prometheus-node-exporter` on all four hosts. Ten minutes now saves a second pass on Monday.
- [ ] **B5.6** Run with `--check --diff` first, then for real, then again.
- **Accept:** the second real run reports `changed=0`.

## Block 6: Repository and placeholder app (45 min)

- [ ] **B6.1** New public app repo; `.gitignore`.
- [ ] **B6.2** Tiny web app with `/` and `/healthz`, Dockerfile, non-root user.
- [ ] **B6.3** Runs locally with `docker run`.

## Block 7: CI at home (1.5 h) — GitHub Actions, GHCR

**Learn:** self-hosted runners, workflows, registries, image digests.

- [ ] **B7.1** Runner on ci-01, labels `home,x64`, as a service, non-root.
- [ ] **B7.2** Repo settings: fork pull requests need approval.
- [ ] **B7.3** Workflow on `[self-hosted, home]`: build, smoke test `/healthz`, push to GHCR tagged with the commit SHA.
- [ ] **B7.4** Package visibility public.
- **Accept:** a push turns the workflow green and the runner log on ci-01 shows the job.

## Block 8: GitOps deploy (1.5 h) — pull agent

**Learn:** pull versus push delivery, pinning by digest, health gates, rollback.

- [ ] **B8.1** `deploy/web/compose.yml` in the infra repo: Caddy and the app, image pinned by digest.
- [ ] **B8.2** Agent on web-01 (installed by Ansible): script, systemd service and timer every 2 minutes. `git pull`; if `deploy/web` changed, `compose pull` and `up -d`; check `/healthz`; on failure go back to the previous commit.
- [ ] **B8.3** CI step: on main, open a pull request on the infra repo that changes the digest (design D6). Branch protection on both `main` branches; fine-grained token that can open but not merge.
- **Accept:** change a string, push, and it is live in under ten minutes with no manual step. A deliberately broken release rolls back by itself.

## Block 9: Public URL (45 min)

- [ ] **B9.1** Cloudflare DNS: `demo` A record → Elastic IP, DNS only (grey cloud) for now.
- [ ] **B9.2** Caddy site block for `demo.arsham.codes`; certificate issued automatically.
- **Accept:** `curl -I https://demo.arsham.codes` returns 200 with a valid certificate.

## Block 10: Monitoring (1.5 h for level 1) — Prometheus, Grafana

**Learn:** pull-based metrics, exporters, scrape targets, PromQL basics, dashboards as code, probing from outside.

How it fits the design: Prometheus **pulls**. svc-01 at home opens every connection, to home hosts directly and to web-01 through the tunnel. AWS never starts a connection towards home, so the direction rule and the Rogers constraint both hold.

```text
                         ┌──────────── svc-01 (home, VLAN 20) ────────────┐
 you ─ssh tunnel─► :3000 │ Grafana ◄── Prometheus ◄── blackbox exporter   │
                         └───────────────┬───────────────────┬────────────┘
        scrape :9100                     │                   │ probe https://demo.arsham.codes
   ┌───────────┬───────────┬─────────────┤                   ▼ (out through the internet)
 ops-01      ci-01      svc-01      web-01 (through WireGuard)
```

**Level 1 (do on Monday):**

- [ ] **B10.1** Firewall. Aliases `HOST_SVC01` (10.10.20.11), `HOST_OPS01` (10.10.10.20). SERVERS rules, above the two blocks: pass `HOST_SVC01` → `HOST_OPS01` TCP 9100; pass `HOST_SVC01` → `NET_AWS` TCP 9100.
- [ ] **B10.2** `monitoring/` in the infra repo: `compose.yml` (Prometheus, Grafana, blackbox exporter), `prometheus.yml` with the four node targets and the HTTPS probe, Grafana data source provisioned from a file.
- [ ] **B10.3** Ansible playbook `monitoring.yml` deploys it to svc-01.
- [ ] **B10.4** Reach Grafana from the laptop: `ssh -L 3000:10.10.20.11:3000 ops-01`, then `http://localhost:3000`. Change the admin password at first login.
- [ ] **B10.5** Dashboards: import "Node Exporter Full" (ID 1860) and a blackbox dashboard (ID 7587).
- [ ] **B10.6** Prometheus → Status → Targets: every target `UP`.
- **Accept:** stop the app container on web-01 and the probe turns red within a minute; start it and it recovers. Screenshot both.

**Level 2 (+45 min, if time):**

- [ ] **B10.7** cAdvisor on web-01 and ci-01 for per-container CPU and memory.
- [ ] **B10.8** Proxmox host: `prometheus-node-exporter` bound to 10.10.10.5 only, plus the rule svc-01 → 10.10.10.5:9100.
- [ ] **B10.9** OPNsense: `os-node_exporter` plugin, plus a rule svc-01 → This Firewall 9100 above the SERVERS block.

**Level 3 (+1 h, after Monday):**

- [ ] **B10.10** CloudWatch data source in Grafana with a read-only IAM user: EC2 CPU credits, network, status checks, and estimated charges.
- [ ] **B10.11** Alertmanager to Discord or email: site down, tunnel down, disk above 80 %.

Not opened anywhere: port 9100 in the AWS security group. Scrapes arrive inside the tunnel, which the security group sees only as UDP 51820.

## Block 11: Real apps (1–4 h)

- [ ] **B11.1** Pick the apps; confirm each runs in Docker.
- [ ] **B11.2** Production compose: no source mounts, no dev servers, Postgres volume, secrets in an `.env` on web-01 only.
- [ ] **B11.3** Same pipeline: build at home, pin the digest, the agent deploys.

## Block 12: Packaging (1.5 h)

- [ ] **B12.1** README: pitch, diagram, what it proves, how the pipeline works, cost, what is next.
- [ ] **B12.2** Screenshots: green workflow, runner at home, WireGuard handshake, blocked AWS → home in Live View, the live site.
- [ ] **B12.3** Tag `v0.1.0`; LinkedIn post.

---

## After Monday

1. **Hardening block** (`OPNSENSE-MVP-RUNSHEET.md`, Block A): admin users, SSH keys, two-factor, switch VTY ACL, backups, short-lived AWS credentials, Cloudflare proxy in front with the security group limited to Cloudflare ranges.
2. **Back to the full plan:** split web-01 into web / vpn-gw / private data tier, svc-01 with Postgres at home, the sync worker, Ansible push to the private tier, drills, monitoring.
3. **Terraform for Proxmox**, Ansible for the switch, IPsec demo mode.

## Cost watch

| Item | About |
|---|---|
| `t3.small` in us-east-1 | $0.0208/hour |
| Public IPv4 address | $0.005/hour |
| 20 GB gp3 | $1.60/month |
| **Running all month** | **about $20** |

`terraform destroy` removes everything when a demo is over. The budget alert from B2.5 is the safety net. Credit on the account: 100 USD, free plan, six months (2026-10-12).
