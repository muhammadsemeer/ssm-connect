# SSM Connect

A lightweight CLI wrapper around AWS Systems Manager for connecting to EC2 instances, managing aliases, and copying files — without opening SSH ports.

> Version **2.0.0** introduces SSO-based AWS authentication and `scp`-compatible file transfer syntax. See [Migrating from 1.x](#migrating-from-1x) if upgrading.

---

## Install

**Linux**
```bash
curl -fsSL https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/refs/heads/master/install.sh | sudo bash
```

**macOS**
```bash
curl -fsSL https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/refs/heads/master/install.sh | bash
```

Verify:
```bash
ssm-connect --help
```

---

## First-time setup (AWS SSO)

On the first run, `ssm-connect` auto-launches the AWS SSO setup flow:

```bash
ssm-connect
[INFO] AWS profile 'ssm-session-manager' not found. Starting SSO setup...
[⚠️ ] When prompted for a role, choose: ssm-session-<your-name>

SSO session name (Recommended): ssm
SSO start URL [None]: https://<your-org>.awsapps.com/start
SSO region [None]: ap-south-1
SSO registration scopes [sso:account:access]: [Press ENTER]
...
```

You'll be redirected to your browser to authenticate. After authentication:

- **When prompted for a role**, choose the permission set matching **`ssm-session-<your-name>`** — this is the role that has SSM/Session-Manager access.
- **Default region**: `ap-south-1`
- **Output format**: `json`
- **Profile name**: leave as default (will be `ssm-session-manager`)

### Subsequent runs

Every command checks your SSO session. If it's expired, `ssm-connect` automatically runs `aws sso login` for you — no manual re-auth needed.

```bash
ssm-connect addons
[🔐] SSO session expired or not signed in. Launching 'aws sso login'...
# browser opens, you sign in, then the command proceeds
```

> ⚠️ Legacy key-based profiles (`aws_access_key_id` / `aws_secret_access_key` in `~/.aws/credentials`) from older versions are automatically detected and removed on first run of 2.0.0.

---

## Aliases

Map short names to EC2 instance IDs so you never have to type them:

```bash
# add / update
ssm-connect -a webserver i-67849xxxx

# list
ssm-connect -l

# remove
ssm-connect -r webserver
```

Aliases are stored in `~/.ssm-connect/aliases`.

---

## Connect to an instance

**Interactive selector** (fuzzy search, sorted by recent usage):
```bash
ssm-connect
```

**Direct connect by alias:**
```bash
ssm-connect addons
```

---

## Copy files (scp)

Version 2.0.0 replaces the old `--scp <alias> <src> <dest>` syntax with native `scp`-style `alias:path` notation.

### Upload (local → remote)

```bash
# explicit destination filename
ssm-connect --scp ./config.yaml addons:/home/ubuntu/config.yaml

# trailing slash preserves original filename
ssm-connect --scp ./config.yaml addons:/home/ubuntu/
# → /home/ubuntu/config.yaml
```

### Download (remote → local)

```bash
# explicit destination filename
ssm-connect --scp addons:/var/log/app.log ./app.log

# directory / trailing slash preserves original filename
ssm-connect --scp addons:/var/log/app.log ./
# → ./app.log
```

### How it works

Transfers go through an S3 bucket (`ssm-scp`) as an intermediary:

1. **Upload**: local file → S3 → SSM command pulls it to the instance → S3 cleanup
2. **Download**: SSM command pushes instance file → S3 → local download → S3 cleanup

Requirements on the instance:
- AWS CLI installed (used as user `ubuntu`)
- An AWS profile named `ssm` with access to the `ssm-scp` bucket, **or** an attached IAM role with equivalent permissions

---

## Updates

```bash
# see what version you're on
ssm-connect --version

# check for a new version
ssm-connect --check-update

# upgrade
ssm-connect --update

# release notes for the installed version
ssm-connect --whats-new
```

The script also runs a background version check once per day and shows an update hint at the top of any command when a new release is available.

---

## Uninstall

```bash
ssm-connect --uninstall
```

Removes the CLI, `~/.ssm-connect/`, and the SSO profile block from `~/.aws/config` and `~/.aws/credentials`.

---

## Migrating from 1.x

| 1.x | 2.0.0 |
| --- | --- |
| Access keys via `aws configure` | AWS SSO via `aws configure sso` |
| `ssm-connect --scp <alias> <src> <dest>` | `ssm-connect --scp <src> <dest>` with `alias:path` colon notation |
| Manual re-auth on expiry | Automatic `aws sso login` refresh |

On first run after upgrade, the legacy key-based profile is detected and removed, and you'll be walked through SSO setup.

---

## Troubleshooting

**`ForbiddenException: No access` when calling `GetRoleCredentials`**
The role pinned in your profile doesn't have access to the SSO account. Fix:
```bash
aws configure sso --profile ssm-session-manager    # reconfigure and pick the correct role
# or patch in place:
aws configure set sso_role_name "<correct-role>" --profile ssm-session-manager
```

**SSM command fails during scp**
- Instance must have AWS CLI installed under user `ubuntu`
- Instance must have access (via IAM role or a local `ssm` profile) to the `ssm-scp` S3 bucket

**More help**
```bash
ssm-connect --help
```

> ⚠️ Ensure you have the required IAM permissions for Systems Manager / Session Manager. See the [AWS docs](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-getting-started.html) for details. Avoid granting admin-level permission sets to the `ssm-session-*` role.
