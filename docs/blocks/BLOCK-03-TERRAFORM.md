# Block 3 — AWS network and server with Terraform (lab workbook)

**Status:** in progress, started 2026-10-12. Lesson 0.
**How a review happens:** I push from ops-01 to GitHub. The laptop's clone (`~/code/Enterprise-Hybrid-Cloud-Network-Platform`) is pulled and read there. Nothing is read from ops-01 directly, so the machine that holds the AWS key stays out of it.
**How this block works:** I am learning Terraform by writing it myself (decided 2026-10-12, same method as block 5). Each lesson gives a goal, the new ideas, a task and a way to check it. No solutions are given in advance. After each lesson I push my work and it gets reviewed; the review notes and my final files are recorded at the bottom.
**Tool:** Terraform 1.16 on ops-01, with the AWS provider
**Region:** `us-east-1` (changed from `ca-central-1` on 2026-10-12)
**Time:** about 4–5 hours as a lab (estimate)
**Design:** `HYBRID-SLICE-DESIGN.md` · **Checklist:** `HYBRID-SLICE-ROADMAP.md` (tasks B3.0–B3.8)
**Code:** `terraform/aws/` in the infra repo (`Enterprise-Hybrid-Cloud-Network-Platform`), cloned on ops-01 at `~/infra`
**Moved out of this block on 2026-10-12:** the WireGuard key on OPNsense and the WireGuard part of the user data. Block 4 is not done tonight, so they travel with it (lesson 9, written later).

---

## 1. What this block must achieve

After block 2 the account is safe but empty. At the end of this block, files in git describe a network and one server in AWS, and one command creates, changes or removes all of it.

```text
 ops-01 (control node)                      AWS us-east-1
 ┌──────────────────────────┐   HTTPS    ┌────────────────────────────────────────────┐
 │ ~/infra/terraform/aws/   │   to the   │ VPC 10.50.0.0/16                           │
 │   *.tf     desired state ├───────────►│  ┌ public subnet 10.50.0.0/24 ──────────┐  │
 │   tfstate  what exists   │  AWS API   │  │ web-01  10.50.0.10  t3.small         │  │
 │                          │            │  │ security group: 80, 443, udp 51820   │  │
 │ plan  = show the change  │            │  └───────────────────┬──────────────────┘  │
 │ apply = make the change  │            │  route table: 0.0.0.0/0 → internet gateway │
 └──────────────────────────┘            │  Elastic IP ──► web-01                     │
                                         └────────────────────────────────────────────┘
```

Terraform never logs in to the server. It talks to the AWS API from ops-01 with the `forge` profile from block 2.

The requirements. How to meet them is the exercise.

| # | Requirement |
|---|---|
| R1 | All code lives in `~/infra/terraform/aws/`. State, `*.tfvars` and the `.terraform/` folder are never in git; the lock file is |
| R2 | The Terraform version and the AWS provider version are pinned. The region and the CLI profile are not hard-coded in resources |
| R3 | Every resource carries the tags `Project = forge-hybrid` and `ManagedBy = terraform` without repeating them on each resource |
| R4 | A VPC `10.50.0.0/16` with DNS hostnames enabled |
| R5 | A subnet `10.50.0.0/24` in an Availability Zone that offers `t3.small` |
| R6 | An internet gateway, and a route table that sends `0.0.0.0/0` to it, associated with the subnet |
| R7 | A security group: TCP 80 and 443 from anywhere, UDP 51820 from anywhere, everything outbound, and **no port 22** |
| R8 | Break-glass: a variable that, only when set, opens TCP 22 to that one address. Unset by default (design section 11) |
| R9 | A key pair made from ops-01's public key |
| R10 | One instance `web-01`: the newest Ubuntu 24.04 image found by a lookup (no hard-coded image ID), `t3.small`, private address `10.50.0.10`, 20 GB encrypted `gp3` root disk, metadata service version 2 only |
| R11 | An Elastic IP attached to web-01 |
| R12 | Outputs: the Elastic IP and the instance ID |
| R13 | A second `terraform plan` reports no changes. `terraform destroy` removes everything, and `apply` brings it all back |

---

## 2. Concepts

### What Terraform is

A tool that reads files describing what should exist, compares that with what does exist, and calls the provider's API to close the gap. You write the end state, not the steps. This is called **declarative**; a shell script of `aws ec2 create-...` commands is **imperative**.

### The words

| Word | Meaning |
|---|---|
| **Provider** | The plugin that knows one API (here: AWS). Downloaded by `terraform init` |
| **Resource** | One thing Terraform creates and owns: a VPC, an instance |
| **Data source** | A read-only lookup of something that already exists: the newest Ubuntu image |
| **Variable** | An input to your code, set from outside |
| **Local** | A named value computed inside your code |
| **Output** | A value printed after `apply` and readable by other tools |
| **State** | Terraform's record of which real object belongs to which name in your files |
| **Plan** | The list of changes Terraform would make. Nothing is changed |
| **Apply** | Make the changes in the plan |
| **Backend** | Where the state is stored. Here: a local file on ops-01 (design D7) |
| **Module** | A folder of `.tf` files. The folder you run Terraform in is the *root module* |

### The loop

```text
 write .tf ──► init ──► fmt ──► validate ──► plan ──► read it ──► apply
                │                                                   │
        once per folder, and                              state is updated
        when providers change
```

| Command | What it does |
|---|---|
| `terraform init` | Downloads providers into `.terraform/` and writes `.terraform.lock.hcl` |
| `terraform fmt` | Rewrites the files in the standard layout |
| `terraform validate` | Checks syntax and references. Does not contact AWS |
| `terraform plan` | Reads the real state from AWS and shows the difference |
| `terraform apply` | Shows the plan, asks for `yes`, then acts |
| `terraform destroy` | Plans and applies the removal of everything in the state |

### State

The state file (`terraform.tfstate`) maps `aws_vpc.main` in your code to `vpc-0abc...` in AWS.

- Without it Terraform does not know what it made, and would try to create everything again.
- It can contain secrets in plain text, so it never goes into git.
- It is not a backup of the infrastructure; it is a map of it.
- Edit it only through `terraform state ...` commands, never by hand.

### Reading a plan

| Symbol | Meaning |
|---|---|
| `+` | Create |
| `~` | Change in place |
| `-/+` | Destroy, then create a replacement |
| `-` | Destroy |
| `<=` | Read (a data source) |

`(known after apply)` means AWS decides the value, such as an ID. `# forces replacement` beside an argument means that change cannot be made in place. The last line counts it up: `Plan: 3 to add, 0 to change, 0 to destroy.` Read that line every time before typing `yes`.

### Dependencies

When one resource uses a value from another, Terraform creates them in the right order by itself. You do not write the order. Independent resources are created in parallel.

### HCL in two minutes

```hcl
# a comment
block_type "label_one" "label_two" {
  a_string  = "text"
  a_number  = 5
  a_bool    = true
  a_list    = ["a", "b"]
  a_map     = { key = "value" }
  reference = other_type.other_name.attribute
  inside    = "text with ${var.something} in it"

  nested_block {
    setting = "value"
  }
}
```

Terraform reads every `.tf` file in the folder as one document. File names are for humans; the usual ones are `versions.tf`, `providers.tf`, `variables.tf`, `main.tf` (or one file per topic), `outputs.tf`.

### The AWS pieces

| Thing | What it is | From your CCNA |
|---|---|---|
| **VPC** | A private network of your own inside a region | A site's address space |
| **Subnet** | A range inside the VPC, living in one Availability Zone | A VLAN with its subnet |
| **Internet gateway** | The VPC's door to the internet. Does one-to-one NAT for public addresses | The edge router |
| **Route table** | Where the subnet sends traffic for each destination | A routing table |
| **Security group** | A stateful firewall on the instance's network card. Allow rules only | A stateful ACL on the host port |
| **Elastic IP** | A public IPv4 address that stays yours until released | A static public IP |
| **AMI** | The disk image an instance starts from | A template (VM 9000) |
| **Key pair** | A public SSH key that AWS hands to cloud-init | `--sshkeys` in `qm set` |
| **User data** | The cloud-init instructions for first boot | The cloud-init drive |

A subnet is called **public** when its route table has a route to an internet gateway. Nothing else makes it public.

### Where Terraform sits among the other tools

| Tool | Job | Talks to |
|---|---|---|
| Terraform | Make the server and its network exist | The AWS API |
| cloud-init (user data) | First boot: users, keys, a few packages | Runs inside the server once |
| Ansible | Configure the running server | The server, over SSH |
| The GitOps agent | Keep the right app version running | Git and the registry |

### How to find answers yourself

- **The provider documentation:** `registry.terraform.io/providers/hashicorp/aws/latest/docs`. Every resource has its own page with the arguments (what you set), the attributes (what you can read afterwards) and an example. This is the page you will use most.
- **`terraform validate`** names the file, the line and the wrong argument.
- **`terraform console`** is a prompt for trying expressions and functions: `cidrsubnet("10.50.0.0/16", 8, 0)`, `var.region`.
- **`terraform state show TYPE.NAME`** prints every attribute of a real object, with the exact names you can reference.
- **The AWS CLI** shows what really exists, independent of Terraform.

### Cost while you work

The VPC, subnet, gateway, route table, security group and key pair cost nothing. The instance and its public address cost about 0.026 USD an hour together. An Elastic IP is charged whether or not it is attached. `terraform destroy` at the end of a session stops all of it.

---

## 3. Lessons

Work from `~/infra/terraform/aws` on ops-01. After each lesson: `terraform fmt`, commit, push, and ask for a review.

### Lesson 0 — Workspace and safety checks (15 min)

**Goal:** a place to write code where a secret cannot be committed by accident.

- [x] **0.1** Close block 2: `aws sts get-caller-identity` ends in `user/arsham-admin`.
- [x] **0.2** Create the folder `~/infra/terraform/aws`.
- [ ] **0.3** Prove that git will ignore the dangerous files before any of them exist. Ask git about these four names from inside the folder: `terraform.tfstate`, `terraform.tfstate.backup`, `terraform.tfvars`, `.terraform/x`. If any is not ignored, fix `.gitignore` at the repo root and commit that first.
- [ ] **0.4** Find which Availability Zones in `us-east-1` offer `t3.small`, with the AWS CLI. The command family is `aws ec2 describe-instance-type-offerings`; it needs a location type and a filter on the instance type.

**Syntax to adapt:**

```bash
git check-ignore -v some/path/file.txt      # prints the rule that ignores it, or nothing
```

**Check:** four lines from `git check-ignore`, each naming a rule. A list of zones for `t3.small`.

**Answer in your own words:**
1. Why check the ignore rules before running Terraform instead of after?
2. Was `t3.small` offered in all six zones? Which one will you use?

### Lesson 1 — Provider, `init`, and a plan with nothing in it (20 min)

**Goal:** Terraform can talk to your account, and has nothing to do yet.

**New ideas:** the `terraform` settings block, version constraints, the provider block, the lock file.

**Syntax to adapt** (generic names and numbers, not yours):

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    examplecloud = {
      source  = "examplecorp/examplecloud"
      version = "~> 3.2"
    }
  }
}

provider "examplecloud" {
  some_setting = "value"
}
```

- [ ] **1.1** In `versions.tf`: require the Terraform version you have installed or newer, and the AWS provider from HashiCorp. Find its current major version on the registry and pin to that major version.
- [ ] **1.2** In `providers.tf`: configure the provider for region `us-east-1` and the CLI profile `forge`. Hard-code both for now; lesson 3 moves them to variables.
- [ ] **1.3** Run `terraform init`. Look at what appeared in the folder.
- [ ] **1.4** Run `terraform fmt`, `terraform validate`, `terraform plan`.
- [ ] **1.5** Run `git status`. Decide which of the new files belong in git.

**Check:**

```bash
terraform version        # lists Terraform and the provider version it selected
terraform providers      # shows the provider and where it is required
terraform plan           # "No changes. Your infrastructure matches the configuration."
git status --short       # the .tf files and the lock file; no .terraform/
```

**Answer in your own words:**
1. What does `~> 3.2` allow, and what does it refuse? How is `~> 3.2.0` different?
2. What is in `.terraform.lock.hcl`, and why is it committed while `.terraform/` is not?
3. `plan` succeeded with no resources. What did it still prove?
4. The provider block names a profile. Where is the access key itself, and does Terraform ever write it into your files?

### Lesson 2 — First resource, and the state (30 min)

**Goal:** create one real thing, find it three ways, remove it, and bring it back.

**New ideas:** the resource block, the resource address `TYPE.NAME`, state.

**Syntax to adapt** (a different resource from yours):

```hcl
resource "aws_sns_topic" "alerts" {
  name = "example-alerts"

  tags = {
    Name = "example-alerts"
  }
}
```

`aws_sns_topic` is the type, fixed by the provider. `alerts` is your own name for it inside Terraform. Together they are its address: `aws_sns_topic.alerts`.

- [ ] **2.1** Find the VPC resource on the registry. Write one that meets R4, with a `Name` tag of `forge-vpc`.
- [ ] **2.2** `plan`. Before typing anything else, write down from the plan: how many to add, and three values that are `(known after apply)`.
- [ ] **2.3** `apply`.
- [ ] **2.4** Find the VPC three ways: `terraform state list`, `terraform state show` with its address, and `aws ec2 describe-vpcs`.
- [ ] **2.5** Run `plan` again.
- [ ] **2.6** `terraform destroy`, then `apply` again. Compare the VPC ID before and after.

**Check:** `describe-vpcs` shows two VPCs, the default `172.31.0.0/16` and yours. The second `plan` says no changes. After destroy and apply the ID is different.

**Answer in your own words:**
1. Which file changed during `apply`? What is `terraform.tfstate.backup`?
2. If you deleted `terraform.tfstate` now and ran `apply`, what would happen in AWS?
3. Terraform did not touch the default VPC during `destroy`. Why not?
4. You changed the name `alerts`-style label of a resource in your file and ran `plan`. What would Terraform want to do, and why? (Try it; do not apply.)

### Lesson 3 — Variables, locals, outputs and default tags (30 min)

**Goal:** no value is typed twice, and tags apply themselves.

**New ideas:** `variable`, `local`, `output`, the ways to set a variable, `default_tags`.

**Syntax to adapt:**

```hcl
variable "environment" {
  description = "Short name of the environment"
  type        = string
  default     = "dev"
}

locals {
  name_prefix = "shop-${var.environment}"
}

output "topic_arn" {
  description = "ARN of the alerts topic"
  value       = aws_sns_topic.alerts.arn
}
```

A variable can be set, from weakest to strongest: its `default`, an environment variable `TF_VAR_name`, the file `terraform.tfvars`, a file given with `-var-file`, `-var name=value` on the command line.

- [ ] **3.1** `variables.tf`: variables for the region, the CLI profile, the project name, the VPC range and the subnet range. Each has a type and a description. Choose which get defaults.
- [ ] **3.2** Use them in the provider and in the VPC. No literal `us-east-1` or `10.50.0.0/16` is left outside `variables.tf`.
- [ ] **3.3** Meet R3 with the provider's `default_tags`. Remove nothing but keep `Name` on the VPC itself.
- [ ] **3.4** `outputs.tf`: output the VPC ID.
- [ ] **3.5** Create `terraform.tfvars.example` with the variable names and placeholder values. This file is committed; the real `terraform.tfvars` is not.
- [ ] **3.6** `plan`, read it, `apply`.

**Check:**

```bash
terraform plan                      # after 3.3: the VPC changes in place (tags), nothing is replaced
terraform output                    # the VPC ID
terraform console                   # try: var.region   and   local.<one of yours>
aws ec2 describe-vpcs --filters Name=tag:Project,Values=forge-hybrid --query 'Vpcs[].Tags'
```

**Answer in your own words:**
1. In the plan for 3.3, was the symbol `~` or `-/+`? What is the difference in practice?
2. Variable versus local: when do you use each?
3. The same variable is set in `terraform.tfvars` and with `-var`. Which wins?
4. Why is `terraform.tfvars` ignored by git in this project, when many projects commit it?

### Lesson 4 — References and the dependency graph (30 min)

**Goal:** a subnet that can reach the internet, built in the right order without you giving the order.

**New ideas:** referencing another resource's attribute, implicit dependencies, `terraform graph`.

**Syntax to adapt:**

```hcl
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn        # TYPE.NAME.ATTRIBUTE
  protocol  = "email"
  endpoint  = "ops@example.com"
}
```

The reference does two jobs: it passes the value, and it tells Terraform that the topic must exist first.

- [ ] **4.1** The subnet (R5), in the zone you chose in lesson 0. The zone is a variable.
- [ ] **4.2** The internet gateway, attached to your VPC.
- [ ] **4.3** A route table in your VPC with the default route to the gateway.
- [ ] **4.4** The association between that route table and the subnet.
- [ ] **4.5** Output the subnet ID.
- [ ] **4.6** `plan`, `apply`, `plan`.

**Check:**

```bash
terraform state list                          # five resources
terraform graph | grep -- '->'                # who depends on whom
aws ec2 describe-route-tables --filters Name=vpc-id,Values=$(terraform output -raw vpc_id) \
  --query 'RouteTables[].{id:RouteTableId,main:Associations[0].Main,routes:Routes[].[DestinationCidrBlock,GatewayId]}'
```

Expect two route tables: the VPC's automatic *main* table with only the `local` route, and yours with `local` plus `0.0.0.0/0` to `igw-...`.

**Answer in your own words:**
1. Nobody wrote the `10.50.0.0/16 → local` route. Where does it come from, and can it be removed?
2. What exactly makes this subnet "public"?
3. Which resource did Terraform create first, and how did it know?
4. A subnet with no association of its own uses which route table? Why is leaving the main table without an internet route a good habit?

### Lesson 5 — The security group, and a conditional rule (30 min)

**Goal:** the firewall in front of web-01, with a door that exists only when you ask for it.

**New ideas:** rules as their own resources, `count`, the conditional expression, `null`.

**Syntax to adapt:**

```hcl
variable "enable_debug_topic" {
  type    = bool
  default = false
}

resource "aws_sns_topic" "debug" {
  count = var.enable_debug_topic ? 1 : 0      # condition ? value_if_true : value_if_false
  name  = "example-debug"
}
```

With `count`, the resource becomes a list: `aws_sns_topic.debug[0]`. A count of zero means it does not exist.

The provider offers two ways to write rules: inside the security group block, or as separate rule resources. Read the note at the top of the security group page on the registry and use the way it recommends.

- [ ] **5.1** The security group, in your VPC, named `forge-web`, with a description.
- [ ] **5.2** Inbound rules for R7. One resource per rule, each with a description.
- [ ] **5.3** The outbound rule: everything, to anywhere. Find how "all protocols" is written.
- [ ] **5.4** Break-glass (R8): a variable `admin_cidr`, a string with a default of `null`. A rule for TCP 22 from that address exists only when the variable is set.
- [ ] **5.5** `plan` and `apply` with the variable unset.
- [ ] **5.6** `plan` only, with `-var admin_cidr=203.0.113.7/32`. Read it. Do not apply.

**Check:**

```bash
aws ec2 describe-security-group-rules \
  --filters Name=group-id,Values=$(terraform output -raw web_sg_id) \
  --query 'SecurityGroupRules[].{egress:IsEgress,proto:IpProtocol,from:FromPort,to:ToPort,cidr:CidrIpv4}' --output table
```

Expect four rows: TCP 80, TCP 443, UDP 51820 inbound, and one outbound. The plan in 5.6 shows one rule to add.

**Answer in your own words:**
1. There is no rule that lets replies to the server's outbound requests back in. Why do `apt update` and `curl` still work?
2. A security group has no "deny" rules. How is something blocked?
3. Compare with your OPNsense rules: first match versus this model. What is the practical difference?
4. Why must your home address never be written into a committed file, and how will you pass it when you need it?
5. Optional: add a `validation` block so that `admin_cidr` must end in `/32`.

### Lesson 6 — Data sources, and the key pair (25 min)

**Goal:** find the right Ubuntu image by asking AWS, and hand AWS your public key.

**New ideas:** the `data` block, filters, the `file()` function.

**Syntax to adapt:**

```hcl
data "aws_caller_identity" "current" {}

output "account_id" {
  value = data.aws_caller_identity.current.account_id      # data.TYPE.NAME.ATTRIBUTE
}
```

- [ ] **6.1** Add the caller-identity data source and an output for the account ID, as a first data source. `apply` and read the output.
- [ ] **6.2** A data source for the newest Ubuntu 24.04 server image, 64-bit x86, published by Canonical. You need three things: Canonical's owner ID (search the Ubuntu documentation for "Canonical AWS owner ID"), a filter on the image name with a wildcard, and "most recent". Explore the names first with `aws ec2 describe-images --owners <that id>` and a name filter.
- [ ] **6.3** Output the image ID and the image name.
- [ ] **6.4** The key pair (R9), reading ops-01's public key from its file with a function. The path is a variable.
- [ ] **6.5** `plan`, `apply`.

**Check:**

```bash
terraform output                                   # an ami-... ID and a name containing noble-24.04-amd64-server
aws ec2 describe-key-pairs --query 'KeyPairs[].{name:KeyName,type:KeyType,fp:KeyFingerprint}'
ssh-keygen -l -f ~/.ssh/id_ed25519.pub             # compare with the fingerprint above
```

**Answer in your own words:**
1. Resource versus data source: what is the difference in what Terraform does with each?
2. The lookup returns the newest image. Next month Canonical publishes a newer one and you run `plan`. What will Terraform want to do to web-01, and is that what you want? Find the `lifecycle` setting that controls this.
3. Why does AWS need only the public key? Where is the private key, and has it moved?
4. Why not copy an `ami-...` ID from a tutorial?

### Lesson 7 — The instance and its address (40 min)

**Goal:** web-01 is running, reachable on its Elastic IP, and closed on port 22.

**New ideas:** nested blocks, `(known after apply)` values flowing between resources, break-glass in practice.

- [ ] **7.1** The instance, meeting every part of R10. It uses your image lookup, subnet, security group and key pair by reference. Tag `Name = web-01`.
- [ ] **7.2** The Elastic IP (R11), attached to the instance.
- [ ] **7.3** Outputs (R12).
- [ ] **7.4** `plan`. Read every line of the instance. `apply`.
- [ ] **7.5** Wait for both status checks to pass.
- [ ] **7.6** From ops-01, test TCP 22, 80 and 443 on the Elastic IP with `nc -zv -w5`. Note the exact message for each.
- [ ] **7.7** Break-glass: apply with `admin_cidr` set to your home public address (`curl -s https://checkip.amazonaws.com`) as a `/32`, on the command line only. `ssh ubuntu@<elastic ip>`. Inside: `cloud-init status`, `ip -4 addr`, `curl -s https://checkip.amazonaws.com`.
- [ ] **7.8** Apply again without the variable. Test port 22 again.

**Check:**

```bash
aws ec2 describe-instance-status --instance-ids $(terraform output -raw instance_id) \
  --query 'InstanceStatuses[].[InstanceState.Name,SystemStatus.Status,InstanceStatus.Status]' --output text
aws ec2 get-console-output --instance-id $(terraform output -raw instance_id) --latest --output text | tail -20
terraform plan                                     # no changes
```

Expect `running ok ok`; the console log ends with cloud-init finishing; port 22 times out before 7.7 and after 7.8.

**Answer in your own words:**
1. Port 22 gave one message and port 80 another. What does each message tell you about where the packet stopped?
2. Inside the server, `ip -4 addr` shows only `10.50.0.10`. Where is the Elastic IP? Relate it to the NAT lesson (`LESSON-NFTABLES-NAT.md`).
3. Why an Elastic IP instead of the automatic public address?
4. What does "metadata service version 2 only" protect against?
5. The break-glass address was passed with `-var`. Is it in the state file? Check, and say what that means for where the state may live.

### Lesson 8 — Drift, replacement, and destroy (30 min)

**Goal:** see what Terraform does when reality and the files disagree, and learn which changes are dangerous.

**New ideas:** drift, in-place versus replacement, saved plans.

- [ ] **8.1** Drift: in the AWS console, add a tag `Owner = console` to web-01 by hand. Run `plan`. Decide who wins, then `apply`.
- [ ] **8.2** In-place: change the root disk size in your code from 20 to 25. `plan` only. Note the symbol. Change it back.
- [ ] **8.3** Replacement: change the private address to `10.50.0.11`. `plan` only. Find the line marked `# forces replacement`. Change it back.
- [ ] **8.4** A saved plan: `terraform plan -out=tfplan`, `terraform show tfplan`, then `terraform apply tfplan`. Check that `tfplan` is ignored by git; add a rule if it is not.
- [ ] **8.5** Meet R13: `plan` reports no changes. Then `terraform destroy`, read the count, confirm. Then `apply` and compare the Elastic IP before and after.
- [ ] **8.6** If you are stopping for the night, finish with `terraform destroy` and `aws ec2 describe-addresses` (expect an empty list).

**Check:** `terraform plan` prints "No changes." `terraform state list` after destroy prints nothing.

**Answer in your own words:**
1. In 8.1, what did Terraform plan to do with the hand-made tag, and why?
2. Which of your arguments on the instance force a replacement? How do you find that out before a real change in production?
3. What problem does a saved plan solve when two people, or a CI job, apply changes?
4. The Elastic IP changed after destroy and apply. What will depend on that address in blocks 4 and 9, and how could the address be kept?
5. `terraform destroy` versus stopping the instance in the console: what keeps costing money in each case?

**Then:** commit, push, and ask for a review.

### Coming next

| Lesson | Topic | When |
|---|---|---|
| 9 | User data and `templatefile`: WireGuard on first boot, OPNsense's public key as a variable | With block 4 |
| 10 | Remote state in S3 with locking | Hardening |
| 11 | A limited IAM role for Terraform instead of `AdministratorAccess` | Hardening |
| later | Modules, `for_each`, `import`, `moved` blocks | When web-01 is split into tiers |

---

## 4. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `No valid credential sources found` | The profile is not set or misspelled | `aws sts get-caller-identity`; check the profile in the provider |
| `Inconsistent dependency lock file` | Provider version changed after `init` | `terraform init -upgrade` |
| `Reference to undeclared resource` | Typo in a type or a name | Read the line it names; compare with `terraform state list` |
| `Unsupported argument` | The argument does not exist in this provider version | Open the resource page on the registry for the version in the lock file |
| `InvalidParameterValue ... not supported in your requested Availability Zone` | That zone does not offer the instance type | Lesson 0.4; change the zone variable |
| `The specified instance type is not eligible for Free Tier` or similar | Free plan limits | Check the plan type from B2.4; choose an eligible type or upgrade the plan |
| `Address 10.50.0.10 is in subnet's reserved address range` | AWS keeps the first four and the last address of each subnet | `.10` is fine; `.0` to `.3` and `.255` are not |
| `InvalidAMIID.NotFound` | Image ID from another region | Use the lookup, not a copied ID |
| `apply` hangs on the internet gateway during destroy | Something with a public address is still in the VPC | Let it finish; Terraform removes things in order |
| `Error acquiring the state lock` | A previous run was killed | Make sure no run is active, then `terraform force-unlock <id>` |
| Plan wants to replace web-01 with nothing changed | A newer Ubuntu image was published | Lesson 6, question 2 |
| SSH during break-glass times out | Home address changed, or the wrong one was used | `curl -s https://checkip.amazonaws.com` from ops-01, apply again |
| `Permission denied (publickey)` | Wrong user or wrong key | The user on Ubuntu images is `ubuntu`; the key is ops-01's |

## 5. Review log

*(one entry per lesson: what I wrote, what was corrected, and why)*

### Lesson 0 — 2026-10-12, in progress

- **0.1, 0.2** done. Identity is `user/arsham-admin`.
- **0.3** open. The `.gitignore` already exists on the laptop, untracked, in the infra repo. It has to be committed and pushed from the laptop, and `~/infra` on ops-01 has to be a clone of the repo, not a folder made with `mkdir`.
- **0.4** `t3.small` is offered. Open: I answered with the region (`us-east-1`); a subnet lives in one **zone**, so the answer must be a zone name such as `us-east-1a`.
- **Question 1, my answer:** "because we don't want to send the credential to git and commit it."
  **Correction:** right about *what* is protected, but the question was about *when*. Git keeps every committed version for ever, so deleting the file later does not remove it from history, and on a public repo it is copied the moment it is pushed. Also, `.gitignore` only affects files that are not tracked yet: once a file is committed, adding an ignore rule does nothing. So the rule has to exist before the file does.
  **Second correction:** the AWS access key is not what Terraform would leak. It stays in `~/.aws/credentials`, outside the repo. The files at risk are the state (every attribute of every resource, sometimes passwords) and `terraform.tfvars` (here: the home public IP).

## 6. My final files

*(recorded when the block is finished: the tree, and a line-by-line explanation of each file as I wrote it)*

## 7. Result log

*(filled in when the block is finished: resource IDs, the Elastic IP is not recorded here, tool versions, what the checks proved)*
