# Block 2 — AWS account preparation

**Status:** in progress, started 2026-10-12. Paused 2026-10-11 while the account could not be reached; access is back
**Tool:** AWS console (browser), AWS CLI on ops-01
**Time:** about 45 minutes
**Design:** `HYBRID-SLICE-DESIGN.md` · **Checklist:** `HYBRID-SLICE-ROADMAP.md` (tasks B2.1–B2.10)

---

## 1. What this block does, and why

Nothing is built in AWS yet. This block makes the account safe to use and gives ops-01 an identity that Terraform can act with.

```text
 BEFORE                                   AFTER
 ┌───────────────────────┐                ┌──────────────────────────────────────┐
 │ root user             │                │ root user        MFA, no keys,       │
 │  email + password     │                │                  locked away         │
 │  can do everything    │                │ IAM user         arsham-admin        │
 │  used for everything  │                │   console: password + MFA            │
 └───────────────────────┘                │   CLI: access key ──► ops-01 only    │
                                          │ Budget alert     email at 50/80/100% │
                                          └──────────────────────────────────────┘

 ops-01:  ~/.aws/credentials [forge]  ──►  aws CLI  ──► AWS API
                                      └─►  Terraform ──► AWS API   (block 3)
```

Why it comes before any server: every later step uses these credentials. If the account is compromised or runs up a bill, nothing else matters.

---

## 2. Concepts

### Root user and IAM users

- The **root user** is the email address the account was opened with. It can do everything, including closing the account and changing billing, and it **cannot be restricted** by any policy.
- **IAM** (Identity and Access Management) is the service that creates other identities and decides what each may do.
- Practice: root is used to create one administrator, then stored away with MFA. Daily work happens as an IAM identity.

Things only root can do, for reference: close the account, change the account's email or root password, change the support plan, restore IAM permissions if every admin is locked out.

### The four IAM building blocks

| Thing | What it is | Example here |
|---|---|---|
| **User** | A long-lived identity for a person or a tool. Has a password and/or access keys | `arsham-admin` |
| **Group** | A set of users sharing permissions | Not used yet |
| **Role** | An identity with no long-lived credentials. It is *assumed* for a while and hands out temporary keys | Later: a role for web-01, a limited role for Terraform |
| **Policy** | A JSON document listing allowed or denied actions on resources | `AdministratorAccess` |

Two questions are always separate:

- **Authentication:** who are you? Password plus MFA, or an access key.
- **Authorization:** what may you do? Policies.

How a request is judged: everything is denied by default; an explicit `Allow` in a policy permits it; an explicit `Deny` anywhere overrides every `Allow`.

**Least privilege** means giving an identity only the permissions its job needs. `AdministratorAccess` on `arsham-admin` is the opposite, and is a deliberate shortcut for this weekend. The hardening block replaces it with a limited role for Terraform.

### MFA

Multi-factor authentication adds something you have (a code from an authenticator app) to something you know (the password). A stolen password alone is then useless. It goes on root first, then on the admin user.

### Access keys

An access key is a pair: an **access key ID** (like a username, starts with `AKIA`) and a **secret access key** (like a password, shown once). Programs sign their API requests with it.

- It is **long-lived**: valid until deleted. That is its weakness.
- It carries the user's full permissions. Whoever has this key has the account.
- The alternative is **temporary credentials** from STS (the Security Token Service), which expire in hours. Roles, IAM Identity Center and `aws login` all give those. That is the hardening target.

### Profiles and where the CLI finds credentials

The CLI and Terraform use the same files on ops-01:

```text
~/.aws/credentials        [forge]
                          aws_access_key_id = AKIA...
                          aws_secret_access_key = ...

~/.aws/config             [profile forge]
                          region = us-east-1
                          output = json
```

A **profile** is a named set of credentials and defaults. Tools look for credentials in a fixed order: command-line options, then environment variables (`AWS_PROFILE`, `AWS_ACCESS_KEY_ID`), then these files, then an attached role. Setting `AWS_PROFILE=forge` once makes every command and Terraform use this identity.

### Regions and Availability Zones

- A **region** is a geographic area with its own independent copy of the services: `us-east-1` is Northern Virginia, `ca-central-1` is Montréal.
- An **Availability Zone** is one or more data centres inside a region, isolated from the others: `us-east-1a` to `us-east-1f`. Not every zone offers every instance type, so block 3 checks before choosing one.
- Most resources live in one region. The console shows only the selected region, so the wrong region looks like an empty account.
- IAM, billing and DNS are **global**.

### ARN

An Amazon Resource Name is the unique address of anything in AWS:

```text
arn:aws:iam::123456789012:user/arsham-admin
 │   │   │  │       │          └ resource
 │   │   │  │       └ account ID
 │   │   │  └ region (empty: IAM is global)
 │   │   └ service
 │   └ partition
 └ always "arn"
```

### Budgets and credits

- A **budget** watches spending and sends an email at thresholds. It does not stop anything; it warns.
- **Credits** pay the bill before your card does. A budget that counts credits sees a net cost of zero and never alerts, so credits are excluded from this budget and it follows real usage.
- **Cost Explorer** shows where money went, after the fact. The budget is the alarm; Cost Explorer is the investigation.

### Shared responsibility

AWS secures the cloud itself: buildings, hardware, the hypervisor. The customer secures what they put in it: accounts and keys, security groups, the operating system, the application, the data. Everything in this block is on the customer's side of that line.

---

## 3. Steps

### B2.1 MFA on root

Signed in as root: account name (top right) → **Security credentials** → Multi-factor authentication → **Assign MFA device** → name it → **Authenticator app** → scan the QR code → enter two consecutive codes.

Why: root cannot be limited by policy, so MFA is its only extra protection.

### B2.2 Root has no access keys

Same page → **Access keys**. The list must be empty. Delete any that exist.

Why: a root access key is an unrestricted, long-lived credential in a file. There is no good reason to have one.

### B2.3 Let IAM users see billing

Account name → **Account** → "IAM user and role access to Billing information" → Edit → **Activate**.

Why: by default only root can open the billing pages. Without this, the admin user cannot see budgets or credits, and you would keep logging in as root.

### B2.4 Check the credit and the plan

**Billing and Cost Management** → **Credits**: note the remaining amount and the expiry date.

Then the Billing home page or the Free Tier page: note whether the account is on a **free plan** or a **paid plan**. On a free plan, only certain instance types can be launched. `t3.small` is expected to be among them; if Terraform refuses the instance type in block 3, this is where to look.

### B2.5 Budget

Billing and Cost Management → **Budgets** → Create budget → **Customize (advanced)** → **Cost budget**.

| Field | Value | Why |
|---|---|---|
| Period | Monthly, recurring | Follows the billing cycle |
| Budgeting method | Fixed, 25 USD | Slightly above the expected 20 USD a month |
| Scope | All AWS services | Catches anything forgotten |
| Advanced options | Untick **Credits** | Otherwise net cost is zero and the alert never fires |
| Alerts | 50 %, 80 %, 100 % of **actual** cost | Early warning, warning, limit |
| Email | Your address | The whole point |

### B2.6 The admin user

**IAM** → Users → **Create user**.

| Field | Value |
|---|---|
| User name | `arsham-admin` |
| Console access | Yes, "I want to create an IAM user", your own password |
| Permissions | Attach policies directly → `AdministratorAccess` |

Then:

1. Open the user → **Security credentials** → Assign MFA device. Same procedure as root, a second entry in the authenticator.
2. IAM dashboard → **Account Alias** → create one (for example `<alias>`). The sign-in address becomes `https://<alias>.signin.aws.amazon.com/console`, easier than the 12-digit account number.

### B2.7 Access key for ops-01

User `arsham-admin` → Security credentials → **Create access key** → use case **Command Line Interface** → confirm → Create.

The secret is shown **once**. Keep the page open and go straight to the next step. Do not save it to a file, a note or a chat.

### B2.8 Switch identity

Sign out of root. Sign in at the alias URL as `arsham-admin` with MFA. Set the region selector (top bar) to **US East (N. Virginia)**.

From here on root is not used.

### B2.9 Configure the CLI on ops-01

```bash
aws configure --profile forge
```

It asks four things:

| Prompt | Answer |
|---|---|
| AWS Access Key ID | the `AKIA...` value |
| AWS Secret Access Key | the secret |
| Default region name | `us-east-1` |
| Default output format | `json` |

```bash
chmod 600 ~/.aws/credentials
echo 'export AWS_PROFILE=forge' >> ~/.bashrc
source ~/.bashrc
aws sts get-caller-identity
aws configure list
```

| Command | What it does | Why |
|---|---|---|
| `aws configure --profile forge` | Writes the key and defaults under the name `forge` | A named profile keeps this identity separate from any other |
| `chmod 600` | Owner read and write only | The file holds a credential |
| `echo ... >> ~/.bashrc` | Adds a line to the shell's start-up file | Every new shell uses the `forge` profile without typing it |
| `source ~/.bashrc` | Re-reads that file in the current shell | Takes effect now |
| `aws sts get-caller-identity` | Asks AWS "who am I?" | Proves the key works and shows which identity it is |
| `aws configure list` | Shows which profile, key (masked) and region are active, and where each came from | Debugging "wrong account" problems |

Expected from `get-caller-identity`:

```json
{
    "UserId": "AIDA................",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/arsham-admin"
}
```

The `Arn` must end in `user/arsham-admin`, not `root`.

### B2.10 Look around with the CLI

```bash
aws ec2 describe-availability-zones --query 'AvailabilityZones[].ZoneName' --output text
aws ec2 describe-vpcs --query 'Vpcs[].{id:VpcId,cidr:CidrBlock,default:IsDefault}' --output table
aws ec2 describe-instances --query 'Reservations[].Instances[].InstanceId'
aws budgets describe-budgets --account-id $(aws sts get-caller-identity --query Account --output text) --query 'Budgets[].BudgetName'
```

| Command | Expect | Shows |
|---|---|---|
| `describe-availability-zones` | `us-east-1a` to `us-east-1f` | The zones available to this account |
| `describe-vpcs` | One VPC, `172.31.0.0/16`, default `True` | The default VPC every account gets. It is left alone; block 3 builds a separate one |
| `describe-instances` | `[]` | Nothing is running, nothing is costing money |
| `budgets describe-budgets` | The budget's name | The alarm exists |

`--query` filters the JSON reply with a small language called JMESPath, so only the wanted fields are printed. `$(...)` runs a command and inserts its output, here the account number.

---

## 4. Done when

- [x] Root has MFA and no access keys.
- [ ] IAM access to billing is activated.
- [x] Credit amount, expiry and plan type are noted.
- [ ] A 25 USD monthly budget exists with credits excluded and three email alerts.
- [x] `arsham-admin` exists with `AdministratorAccess` and MFA.
- [ ] You are signed in as `arsham-admin`, region US East (N. Virginia).
- [x] On ops-01, `aws sts get-caller-identity` shows `user/arsham-admin`.
- [x] `describe-instances` returns an empty list.

## 5. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Unable to locate credentials` | Profile not selected | `echo $AWS_PROFILE`; `aws configure list` |
| `InvalidClientTokenId` or `SignatureDoesNotMatch` | Key ID or secret mistyped or cut short | Run `aws configure --profile forge` again |
| `Arn` ends in `:root` | The key belongs to root | Delete it in the console, create one on `arsham-admin` |
| `AccessDenied` on billing pages as `arsham-admin` | B2.3 not done | Activate it as root |
| `AuthFailure` with correct keys | Clock on ops-01 is wrong; requests are time-signed | `timedatectl`; it should show synchronized |
| Console shows nothing after signing in | Wrong region selected | Region selector → US East (N. Virginia) |
| Lost the secret before saving it | It is shown once | Delete that key, create a new one |
| Budget never alerts | Credits included | Edit the budget, exclude credits |
| A key was pasted somewhere by mistake | It is compromised | IAM → the user → deactivate and delete the key immediately, then create a new one |

## 6. Result log

**2026-10-12, in progress.**

Decisions changed from the first plan:

- Region is **`us-east-1`** (N. Virginia), not `ca-central-1`. My choice.
- The budget was first created at 10 USD and named `10 dollars`; it goes back to 25 USD so that a server running all month does not trip the 100 % alert.

Seen on ops-01:

| Check | Result |
|---|---|
| `aws configure list` | profile `forge` from the `AWS_PROFILE` variable; key and secret from the shared credentials file; region `us-east-1` from `~/.aws/config` |
| `describe-availability-zones` | `us-east-1a` to `us-east-1f`, six zones |
| `describe-vpcs` | one default VPC, `172.31.0.0/16` |
| `describe-instances` | `[]` |
| `budgets describe-budgets` | `10 dollars` |

| `aws sts get-caller-identity` | `Arn` ends in `user/arsham-admin`; `UserId` starts with `AIDA`, the prefix of an IAM user |

The account ID is not written in this file: it is not a secret, but it has no reason to be public.

Account: 100 USD of promotional credit, **free plan**, six months. A free-plan account closes when the credit is used up or the six months end, whichever is first, unless it is upgraded to the paid plan. Check the end date under Billing before relying on the public site.

Confirmed 2026-10-12: root has MFA and no access keys; `arsham-admin` has MFA; budget alerts are at 50, 80 and 100 %.

Still open: the budget amount back to 25 USD with **Credits** excluded (check: `IncludeCredit` is `false` in `aws budgets describe-budgets`); B2.3, billing pages open as `arsham-admin`; B2.8, console signed in as `arsham-admin` in US East (N. Virginia).
