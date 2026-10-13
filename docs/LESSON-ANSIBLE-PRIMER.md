# Ansible primer — a crash course on my own lab

Read this, type every example, then do the lessons in `blocks/BLOCK-05-ANSIBLE.md`. The examples here use throwaway jobs (install `tree`, write a demo file) so that the real requirements stay my own work.

**Sandbox:** `stg-01` (10.10.20.13). Nothing on it matters yet. If an experiment breaks it, destroy it and clone it again in two minutes (`qm stop 113; qm destroy 113 --purge`, then the clone commands). That freedom is the point of having it.

**Where to type:** on ops-01. Any folder works for sections 1–3; from section 4 on, use a scratch folder such as `~/sandbox`.

---

## 0. The mental model

```text
 ops-01                                              stg-01
 ┌──────────────────────────┐   1. SSH in           ┌─────────────────────┐
 │ you type a command or    │ ───────────────────►  │                     │
 │ run a playbook           │   2. copy a small     │ 3. the module runs, │
 │                          │      Python program   │    checks the state,│
 │ Ansible reads:           │      (a "module")     │    changes it only  │
 │  - inventory (which)     │                       │    if needed        │
 │  - playbook  (what)      │ ◄───────────────────  │                     │
 └──────────────────────────┘   4. JSON result:     └─────────────────────┘
                                   ok / changed / failed
```

Three things to hold on to:

1. **Inventory** answers *which servers*.
2. **Module** is *one job* (install a package, write a file, manage a service). There are thousands; you will use about ten.
3. **Playbook** is *a list of module calls* applied to servers from the inventory.

For a network engineer:

| Ansible | Closest thing you already know |
|---|---|
| Inventory | The device list in a management tool |
| Module | One configuration command, but one that checks before acting |
| Playbook | A change procedure written so a machine can run it |
| Idempotent | Typing `no shutdown` on an interface that is already up: nothing happens |
| Check mode | Juniper's `commit check`, or reading a diff before applying |
| Handler | "Reload the service, but only if its config actually changed" |

---

## 1. Ad-hoc: one module, one command

The shape:

```text
ansible  <which hosts>  -i <inventory>  -m <module>  -a "<arguments>"  [-b]
```

Type these on ops-01:

```bash
ansible all -i '10.10.20.13,' -m ping
```

| Part | Meaning |
|---|---|
| `all` | The pattern: every host in the inventory |
| `-i '10.10.20.13,'` | The inventory, typed inline. The trailing comma means "a list, not a file" |
| `-m ping` | The module. It logs in and runs a tiny Python check; it is not an ICMP ping |

Result: `"ping": "pong"` and `"changed": false`. It proves SSH works, the key is accepted, and Python is there.

```bash
ansible all -i '10.10.20.13,' -m command -a 'free -h'
ansible all -i '10.10.20.13,' -a 'df -h /'
```

`-a` passes arguments to the module. With no `-m`, the module is `command`: run this program and show me the output.

Now feel idempotency. Run this **twice** and compare:

```bash
ansible all -i '10.10.20.13,' -m apt -a 'name=tree state=present' -b
```

| Part | Meaning |
|---|---|
| `-m apt` | The package module for Debian and Ubuntu |
| `name=tree state=present` | Desired state: the package `tree` is present |
| `-b` | "become": run through sudo. Installing needs root |

First run: `"changed": true`. Second run: `"changed": false`. Ansible did not install it again; it looked first. Remove `-b` and run it once more to see what a permissions failure looks like.

Now undo it, still idempotently:

```bash
ansible all -i '10.10.20.13,' -m apt -a 'name=tree state=absent' -b
```

**The lesson of this section:** you describe a *state* (`present`, `absent`, `started`), never an action.

---

## 2. Finding and reading module documentation

```bash
ansible-doc apt | less
```

How to read it:

- **Top:** what the module does.
- **OPTIONS:** every parameter. `=` at the start of a line means required. Look at `default:` and `choices:`.
- **EXAMPLES** (near the bottom, search with `/EXAMPLES`): working tasks to copy and adapt. This is where you will spend most of your time.

```bash
ansible-doc -l | grep -i timezone     # find a module by keyword
ansible-doc -s service                # just the parameters
```

Ten modules cover most work: `apt`, `copy`, `template`, `file`, `service` (or `systemd`), `user`, `command`, `lineinfile`, `debug`, `git`.

---

## 3. Inventory

A file that lists hosts and puts them in groups. Two formats; the content is the same.

**INI** (older, compact):

```ini
[sandbox]
stg-01 ansible_host=10.10.20.13

[all:vars]
ansible_user=arsham
```

**YAML** (what most projects use now):

```yaml
all:
  vars:
    ansible_user: arsham
  children:
    sandbox:
      hosts:
        stg-01:
          ansible_host: 10.10.20.13
```

Reading the YAML version from the outside in:

- `all` is the built-in group containing every host.
- `vars` under a group applies to every host in it.
- `children` holds sub-groups. `sandbox` is a group I named.
- `hosts` lists the group's members. `stg-01` is the name Ansible shows in output.
- `ansible_host` is the address to connect to. Variables starting with `ansible_` are connection settings: `ansible_user`, `ansible_port`, `ansible_connection`.

Save the YAML version as `~/sandbox/inventory.yml` and try:

```bash
cd ~/sandbox
ansible-inventory -i inventory.yml --graph
ansible -i inventory.yml sandbox -m ping
ansible -i inventory.yml all --list-hosts
```

A group can also be made of other groups, using `children` again one level down. That is how "all Docker hosts" is built from role groups without repeating names.

Patterns choose hosts: `all`, a group name, a host name, `web:db` (either), `web:!db` (in web but not db). `--limit stg-01` narrows any run to one host.

---

## 4. A playbook, line by line

Save as `~/sandbox/demo.yml`:

```yaml
---
- name: Sandbox demo
  hosts: sandbox
  become: true

  tasks:
    - name: Install two small tools
      ansible.builtin.apt:
        name:
          - tree
          - ncdu
        state: present
        update_cache: true

    - name: Write a demo file
      ansible.builtin.copy:
        dest: /etc/demo.conf
        content: "colour=blue\n"
        owner: root
        group: root
        mode: "0644"
```

There are **three levels**, and almost every beginner error is a key at the wrong level:

```text
- name: Sandbox demo              ┐
  hosts: sandbox                  │ LEVEL 1  the PLAY: where and how
  become: true                    ┘
  tasks:
    - name: Install two small tools   ┐ LEVEL 2  a TASK: its name, its module,
      ansible.builtin.apt:            ┘          and task options (when, notify, loop)
        name: [tree, ncdu]            ┐ LEVEL 3  the MODULE's own arguments
        state: present                ┘
```

| Line | Level | Meaning |
|---|---|---|
| `---` | — | Start of a YAML document. Conventional |
| `- name: Sandbox demo` | play | The `-` starts a play (a playbook is a list of plays). The name appears in the output |
| `hosts: sandbox` | play | Which hosts, as a pattern from the inventory |
| `become: true` | play | Run every task through sudo |
| `tasks:` | play | The ordered list of tasks |
| `- name: Install two small tools` | task | The `-` starts a task. Always name tasks; the name is your log |
| `ansible.builtin.apt:` | task | The module, by its full name: collection `ansible.builtin`, module `apt`. Exactly one module per task |
| `name:`, `state:`, `update_cache:` | module | Arguments, straight from `ansible-doc apt` |
| `mode: "0644"` | module | Quoted, so YAML keeps it as text. Unquoted, `0644` is read as a number and the permissions come out wrong |

Run it in four ways, in this order, every time:

```bash
ansible-playbook -i inventory.yml demo.yml --syntax-check
ansible-playbook -i inventory.yml demo.yml --check --diff
ansible-playbook -i inventory.yml demo.yml
ansible-playbook -i inventory.yml demo.yml
```

| Run | What happens |
|---|---|
| `--syntax-check` | Parses the file only. Catches indentation and structure errors |
| `--check --diff` | Dry run. Shows what would change, including file contents, and changes nothing |
| Real run | Applies it. Look for `changed` |
| Again | Everything `ok`, `changed=0`. That is idempotency |

Reading the output:

```text
TASK [Gathering Facts]        Ansible collects information about the host first
TASK [Install two small tools]
changed: [stg-01]             yellow: it was different, now fixed
TASK [Write a demo file]
ok: [stg-01]                  green: already correct

PLAY RECAP
stg-01 : ok=3  changed=1  unreachable=0  failed=0  skipped=0
```

Experiment: change `colour=blue` to `colour=red`, run with `--check --diff` and read the diff, then apply.

---

## 5. Variables

A variable is a name for a value. It is used with double curly braces.

```yaml
---
- name: Variables demo
  hosts: sandbox
  become: true
  vars:
    colour: green
    tools:
      - tree
      - ncdu

  tasks:
    - name: Install the tools
      ansible.builtin.apt:
        name: "{{ tools }}"
        state: present

    - name: Write the demo file
      ansible.builtin.copy:
        dest: /etc/demo.conf
        content: "colour={{ colour }}\n"
        mode: "0644"

    - name: Show what Ansible knows about this host
      ansible.builtin.debug:
        msg: "{{ inventory_hostname }} runs {{ ansible_facts['distribution'] }} {{ ansible_facts['distribution_version'] }}"
```

- `{{ colour }}` is replaced by the value. This is Jinja2 templating.
- **Quoting rule:** if a value *starts* with `{{`, the whole value must be in quotes: `name: "{{ tools }}"`. Otherwise YAML reads `{` as the start of a mapping and fails.
- `debug` prints. It is the `print()` of Ansible; use it to see what a variable holds.
- `inventory_hostname` and `ansible_facts[...]` are provided by Ansible. See all facts with `ansible -i inventory.yml sandbox -m setup | less`.

Where variables can live, from weakest to strongest (a simplified list): inventory group vars → inventory host vars → `vars:` in the play → `-e name=value` on the command line. The more specific and the more explicit wins.

For real projects, variables go in files next to the inventory, loaded automatically by name: `group_vars/all.yml`, `group_vars/<group>.yml`, `host_vars/<host>.yml`.

---

## 6. Conditions: `when`

Run a task only where a test is true. `when` sits at the **task** level, and takes an expression **without** curly braces.

```yaml
    - name: Only on machines with more than 3 GB of memory
      ansible.builtin.debug:
        msg: "This is a big one"
      when: ansible_facts['memtotal_mb'] > 3000

    - name: Only on hosts that belong to the sandbox group
      ansible.builtin.debug:
        msg: "I am a sandbox host"
      when: "'sandbox' in group_names"
```

`group_names` is the list of groups the current host is in. The second expression is quoted as a whole because it begins with a quote character.

On stg-01 (2 GB) the first task reports `skipping`. That is not an error.

---

## 7. Loops

Repeat a task for each item of a list. `loop` is at the task level; the current value is `item`.

```yaml
    - name: Create three demo directories
      ansible.builtin.file:
        path: "/opt/demo/{{ item }}"
        state: directory
        mode: "0755"
      loop:
        - alpha
        - beta
        - gamma
```

For packages, do not loop: `apt` accepts a list in `name:` and installs them in one transaction, which is faster.

---

## 8. Handlers

A handler is a task that runs **only if another task changed something**, and only **once, at the end of the play**. The classic use is restarting a service after its config file changed.

```yaml
---
- name: Handlers demo
  hosts: sandbox
  become: true

  tasks:
    - name: Write the demo config
      ansible.builtin.copy:
        dest: /etc/demo.conf
        content: "colour=blue\n"
        mode: "0644"
      notify: Announce the change

  handlers:
    - name: Announce the change
      ansible.builtin.debug:
        msg: "The file changed. A real handler would restart the service here."
```

- `notify` is at the task level and names the handler exactly, character for character.
- `handlers:` is at the play level, beside `tasks:`.

Run it three times: first with the file already `blue` (handler silent), then change the content and run (handler fires), then run again unchanged (silent). In a real playbook the handler would be `ansible.builtin.service` with `state: restarted`.

Why not simply restart the service in a normal task? Because it would restart on every run, and the playbook would never report `changed=0`.

---

## 9. Growing up: several files

| Tool | Use |
|---|---|
| `ansible.cfg` in the project folder | Defaults, such as where the inventory is, so `-i` is not needed |
| `import_playbook` | One playbook that runs others in order |
| `tags:` on tasks, `--tags x` on the command line | Run part of a playbook |
| **Roles** | A standard folder layout (`tasks/`, `handlers/`, `templates/`, `defaults/`) that packages one job, such as "docker", for reuse |
| `template` module | Like `copy`, but the source file contains `{{ variables }}` |
| **Ansible Vault** | Encrypts files that hold secrets |

Roles, templates and Vault come later in this project, when they are needed for real.

---

## 10. The errors you will meet

| Message | What it means | Fix |
|---|---|---|
| `mapping values are not allowed in this context` | A `:` where YAML did not expect one, usually wrong indentation or an unquoted value containing `: ` | Check the line above the one reported; quote the value |
| `did not find expected key` / `could not find expected ':'` | Indentation is off by a space, or a tab crept in | Two spaces per level; `cat -A file` shows tabs as `^I` |
| `conflicting action statements: apt, copy` | Two modules in one task | One module per task; start a new `- name:` |
| `Unsupported parameters for (apt) module: nmae` | A typo in an argument, or an argument at the wrong level | `ansible-doc apt` |
| `'when' is not a valid attribute for a Play` | A task keyword placed at play level | Indent it under the task |
| `The task includes an option with an undefined variable` | Variable name misspelt, or not defined for this host | `debug` it; check the inventory |
| `The requested handler 'X' was not found` | `notify` text does not match the handler's name exactly | Copy and paste the name |
| `Missing sudo password` | Needs root, and `become` is missing | `become: true` |
| `UNREACHABLE` | SSH failed: wrong address or user, or unknown host key | `ssh` to it by hand |

The line number in a YAML error is often **one below** the real mistake.

---

## 11. Older tutorials versus today

Most good videos are from 2020–2022. They still teach the right ideas. Three differences you will notice:

| In the video | Today | Does the old way still work? |
|---|---|---|
| `apt:` | `ansible.builtin.apt:` (the full name) | Yes. Both are accepted; the full name is the recommended style |
| `include:` | `import_tasks:` / `include_tasks:` / `import_playbook:` | No, `include` was removed |
| `with_items:` | `loop:` | Yes |

---

## 12. After this primer

Go to `blocks/BLOCK-05-ANSIBLE.md`, lesson 0. Each real task there is a variation of something typed here.
