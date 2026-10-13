# Block 5 — Configure the servers with Ansible (lab workbook)

**Status:** in progress (started 2026-10-11). Done before blocks 2–4 because the AWS account is unreachable; web-01 joins the inventory when it exists.
**How this block works:** I am learning Ansible by writing it myself. Each lesson gives a goal, the new ideas, a task and a way to check it. No solutions are given in advance. After each lesson I push my work and it gets reviewed; the review notes and my final files are recorded at the bottom.
**Start here if Ansible is new:** `LESSON-ANSIBLE-PRIMER.md`, a crash course with worked examples on the sandbox host. Then come back for the lessons.
**Tool:** Ansible, run from ops-01
**Design:** `HYBRID-SLICE-DESIGN.md` · **Checklist:** `HYBRID-SLICE-ROADMAP.md` (tasks B5.0–B5.6)
**Code:** `ansible/` in the infra repo (`Enterprise-Hybrid-Cloud-Network-Platform`), cloned on ops-01 at `~/infra`

---

## 1. What this block must achieve

After block 1 the VMs exist but are bare Ubuntu. At the end of this block, files in git describe what every server must look like, and one command makes them match.

```text
 ops-01 (control node)                          managed nodes
 ┌──────────────────────────────┐
 │ ~/infra/ansible/             │   local       ops-01
 │   inventory  = which hosts   ├──────────────►
 │   playbooks  = desired state │   SSH :22     svc-01
 │                              ├──────────────►ci-01
 │ one command applies it all   │   (through    stg-01
 └──────────────────────────────┘    OPNsense)
                                     later, through the tunnel:  web-01
```

The requirements. How to meet them is the exercise.

| # | Requirement | Applies to |
|---|---|---|
| R1 | Packages are up to date | all |
| R2 | `curl`, `htop`, `ca-certificates`, `unattended-upgrades` are installed | all |
| R3 | `qemu-guest-agent` is installed | Proxmox VMs only (not web-01 later) |
| R4 | Time zone is America/Toronto | all |
| R5 | SSH refuses password logins and root logins | all |
| R6 | Docker, the Compose plugin and Buildx are installed; Docker runs now and at boot | svc-01, ci-01, stg-01 (later web-01) |
| R7 | Each container's log is capped at 3 files of 10 MB | same |
| R8 | User `arsham` can run `docker` without sudo | same |
| R9 | The Prometheus node exporter runs now and at boot, on port 9100 | all |
| R10 | One command applies everything, and a second run reports `changed=0` | all |

---

## 2. Concepts

### What Ansible is

A configuration management tool. You declare the state a server should be in; Ansible logs in over SSH, checks the current state, and changes only what differs.

- **Agentless:** nothing is installed on the managed servers except Python, which Ubuntu already has.
- **Push model:** the control node connects out to the servers when you run it. (The GitOps agent in block 8 is the opposite, a pull model.)

### The words

| Word | Meaning |
|---|---|
| **Control node** | Where Ansible is installed and run (ops-01) |
| **Managed node** | A server Ansible configures |
| **Inventory** | The list of managed nodes, in groups |
| **Group** | A set of hosts addressed together |
| **Module** | One unit of work: install a package, write a file, manage a service |
| **Task** | One call of a module with arguments |
| **Play** | A list of tasks applied to a group of hosts |
| **Playbook** | A file containing one or more plays |
| **Handler** | A task that runs only when something notified it, once, at the end |
| **Facts** | Details Ansible gathers about each host at the start of a play |
| **Variable** | A named value used in tasks |
| **Collection** | A package of modules, such as `ansible.builtin` or `community.general` |

### Idempotency

Running the same playbook twice gives the same result as running it once; the second run reports `changed=0`. A shell script says *do this* and repeats it every run. An Ansible task says *this must be true* and does nothing if it already is. That is what makes it safe to run against production at any time, and what lets a re-run repair drift.

### Reading the output

| Word | Meaning |
|---|---|
| `ok` | Already in the desired state; nothing done |
| `changed` | Was different; Ansible fixed it |
| `skipped` | A condition was false for this host |
| `failed` | The task could not be completed; the play stops for that host |
| `unreachable` | SSH did not connect |

### Where Ansible sits among the other tools

| Tool | Question it answers | When it runs |
|---|---|---|
| Terraform | Does the server exist? | When infrastructure changes |
| cloud-init | Who is this server (name, user, key, address)? | Once, at first boot |
| Ansible | How is the server set up inside? | Any time, repeatedly |
| GitOps agent | Which version of the app is running? | Continuously |

### How to find answers yourself

This matters more than any single answer.

| Command | Gives |
|---|---|
| `ansible-doc -l \| grep <word>` | Search module names |
| `ansible-doc <module>` | Full documentation of one module, with examples at the bottom |
| `ansible-doc -s <module>` | Just the parameters, as a snippet |
| `ansible-doc -t keyword -l` | Every playbook keyword (`hosts`, `become`, `when`, `notify`, ...) |
| `ansible-config init --disabled \| less` | Every configuration setting with its description |
| `ansible-inventory --graph` / `--list` / `--host <name>` | How Ansible understood the inventory |
| `ansible-playbook <file> --syntax-check` | Is the YAML and structure valid |
| `ansible-playbook <file> --list-tasks` / `--list-hosts` | What would run, and where, without running |
| docs.ansible.com | The same module pages, in a browser |

### YAML in two minutes

```yaml
key: value                 # a mapping
number: 42
text: "quoted when it contains : or # or starts with a special character"
a_list:
  - first
  - second
nested:
  inner_key: inner_value   # two spaces per level
```

- Indentation is spaces only, never tabs. Two per level is the convention.
- A file is usually one big mapping or one big list.
- `---` on the first line marks the start of a document; conventional in playbooks.
- Most "Ansible errors" for beginners are indentation errors. `--syntax-check` finds them.

For `nano`, put this in `~/.nanorc` on ops-01 so the Tab key produces two spaces:

```text
set tabsize 2
set tabstospaces
set autoindent
```

---

## 3. Lessons

Work from `~/infra/ansible` on ops-01. After each lesson: commit, push, and ask for a review.

### Lesson 0 — Staging VM and workspace

**Goal:** a fourth server exists, and there is a place to write code.

- [ ] **0.1** Clone `stg-01` yourself. Specification: VM ID 113, VLAN 20, 10.10.20.13/24, gateway and DNS 10.10.20.1, 2 cores, 2048 MB, 20 GB disk, starts at boot in order 3, same user and key file as the other VMs. `blocks/BLOCK-01-TEMPLATE-AND-VMS.md` step B1.7 is the pattern.
- [ ] **0.2** On ops-01, add `stg-01` to `~/.ssh/config` and connect once.
- [ ] **0.3** On the laptop, commit and push the `.gitignore` that is waiting in the infra repo. On ops-01, clone the repo to `~/infra` and create the folder `ansible` in it.
- [ ] **0.4** Set up `~/.nanorc` as above (or use the editor you prefer).

**Check:** `ssh stg-01 hostname` prints `stg-01`. `ls -A ~/infra` shows `.git`, `.gitignore`, `README.md`, `ansible`.

**Think about:** why does Ansible need you to have connected to stg-01 once by hand?

### Lesson 1 — Ad-hoc commands, no files at all

**Goal:** run modules on servers straight from the command line.

**New ideas:** a *module* does one job. `-m` chooses the module, `-a` gives it arguments. The inventory can be typed inline instead of read from a file.

**Syntax to adapt** (generic names, not yours):

```bash
ansible all -i 'server1.example.com,' -u someuser -m some_module -a 'arguments'
```

The trailing comma tells Ansible "this is a list of hosts, not a file name".

- [ ] **1.1** Run the `ping` module against ci-01 only, using an inline inventory.
- [ ] **1.2** Run it against svc-01, ci-01 and stg-01 in one command.
- [ ] **1.3** Run `uptime` on those three with the `command` module.
- [ ] **1.4** Run the `setup` module on ci-01, filtered so it shows only the facts whose names start with `ansible_distribution`.
- [ ] **1.5** Read `ansible-doc ping` and `ansible-doc command`.

**Check:** `"ping": "pong"` from each host; three uptime lines; the Ubuntu version from facts.

**Answer in your own words:**
1. Does the `ping` module send an ICMP ping? What does a `pong` actually prove?
2. What is the difference between the `command` and `shell` modules, and which is the safer default?
3. What was `"changed"` in each result, and why?

### Lesson 2 — The inventory file

**Goal:** describe your servers once, in a file, with groups.

**New ideas:** hosts, groups, groups of groups (`children`), variables at different levels.

**Syntax to adapt** (generic names):

```yaml
all:
  vars:
    some_variable: value_for_every_host
  children:
    webservers:
      hosts:
        web1:
          ansible_host: 192.0.2.10
        web2:
          ansible_host: 192.0.2.11
    databases:
      hosts:
        db1:
          ansible_host: 192.0.2.20
    europe:
      children:
        webservers:
        databases:
```

- [ ] **2.1** Write `inventory/hosts.yml` that satisfies all of these:
  - The four hosts appear by name: `ops-01`, `svc-01`, `ci-01`, `stg-01`, each with its address.
  - Role groups: `control` (ops-01), `monitoring` (svc-01), `ci` (ci-01), `staging` (stg-01).
  - A group `docker_hosts` made of the groups `monitoring`, `ci` and `staging`, without repeating any host name.
  - A group `proxmox_vms` made of all four role groups.
  - For every host: the login user is `arsham`, and a variable `timezone` is `America/Toronto`.
  - ops-01 is managed **without SSH**, since Ansible is already on it. Find the variable that sets the connection type.

**Check:**

```bash
ansible-inventory -i inventory/hosts.yml --graph
ansible-inventory -i inventory/hosts.yml --host svc-01
ansible -i inventory/hosts.yml docker_hosts --list-hosts
ansible -i inventory/hosts.yml all -m ping
```

Expect: a tree with four role groups and two parent groups; svc-01's variables including the user and the time zone; three hosts in `docker_hosts`; four pongs.

**Answer in your own words:**
1. What are the groups `all` and `ungrouped`?
2. If the same variable is set under `all` and again on one host, which wins?
3. Why make `docker_hosts` out of groups instead of listing the three host names?

### Lesson 3 — `ansible.cfg`

**Goal:** stop typing `-i` every time, and set safe defaults for this project.

**New ideas:** Ansible looks for its configuration in this order and uses the first it finds: the `ANSIBLE_CONFIG` environment variable, `ansible.cfg` in the current directory, `~/.ansible.cfg`, `/etc/ansible/ansible.cfg`.

- [ ] **3.1** Create `ansible.cfg` in `~/infra/ansible` so that:
  - the inventory file from lesson 2 is the default;
  - SSH host key checking is explicitly on;
  - `.retry` files are not created.
  - Optional: task results are printed as YAML instead of JSON.

  Find the setting names with `ansible-config init --disabled | less` (search with `/`).

**Check:**

```bash
ansible --version                    # the "config file =" line points at your file
ansible all -m ping                  # works with no -i
ansible-config dump --only-changed   # lists exactly what you set
```

**Answer in your own words:**
1. What happens if you run `ansible all -m ping` from your home directory instead, and why?
2. What risk would `host_key_checking = False` create?

**Then:** `git add ansible`, commit, push, and ask for a review.

### Coming next

| Lesson | Topic | Requirement it serves |
|---|---|---|
| 4 | Ad-hoc with `become`; feeling idempotency by hand | R2 |
| 5 | First playbook: plays, tasks, check mode, the recap | R1, R2 |
| 6 | Variables and conditions (`when`) | R3, R4 |
| 7 | Files and handlers | R5 |
| 8 | A second playbook for one group: packages, services, users | R6, R7, R8 |
| 9 | Exporters, and one playbook that imports the others | R9, R10 |
| 10 | Verifying, `--limit`, tags, verbosity, `ansible-lint` | R10 |
| later | Templates, roles, Vault | Used for real in blocks 8 and 10 |

---

## 4. Troubleshooting

| Symptom | Likely cause | Where to look |
|---|---|---|
| `UNREACHABLE ... Host key verification failed` | The host is not in `known_hosts` yet | Connect once by hand |
| `UNREACHABLE ... Permission denied (publickey)` | Wrong user, or ops-01's key is not on that host | `ansible-inventory --host <name>`; `ssh <host>` by hand |
| `Missing sudo password` | A task needs root and `become` is missing or sudo needs a password | `sudo -n true` on the host |
| `Could not get lock /var/lib/dpkg/lock` | Another apt run is in progress | Wait a minute, run again |
| `couldn't resolve module/action` | Typo in the module name, or its collection is missing | `ansible-doc -l \| grep <name>` |
| `mapping values are not allowed here`, `did not find expected key` | YAML indentation or a missing space after `:` | `--syntax-check`; count the spaces |
| `conflicting action statements` | Two modules in one task | One module per task |
| A task is `changed` on every run | The task is not idempotent as written | Run with `--diff`; read the module's documentation |
| Wrong inventory or config in use | Not in the project folder | `ansible --version` shows the config file |

Useful flags: `--limit <host>`, `-v` to `-vvv`, `--list-tasks`, `--list-hosts`, `--start-at-task "<name>"`, `--step`.

## 5. Review log

*(one entry per lesson: what I wrote, what was corrected, and why)*

## 6. My final files

*(recorded when the block is finished: the tree, and a line-by-line explanation of each file as I wrote it)*
