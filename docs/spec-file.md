# The spec file format

`awsconfd apply --spec <file>` reproduces a whole `config.d/` setup from a
single file - the point is round-tripping a configuration between machines
(check it into `dotfiles`, apply it on a fresh install) without depending on
`jq`, `yq`, or anything beyond the INI parser this tool already has.

A spec file is a valid AWS config file plus two `awsconfd:`-namespaced
control sections. This means an existing `~/.aws/config` is *almost* a
valid spec already, and the whole thing is legible without documentation.

```ini
# multi-customer.spec.ini

[awsconfd]
version = 1
strict  = false

[awsconfd:scheme]
00    = defaults
10    = sso-sessions
2x    = personal
30-39 = customer-a

[awsconfd:layout]
default                  = 00-defaults.conf
sso-session personal     = 10-sso.conf
sso-session customer-a   = 10-sso.conf
profile personal-admin   = 20-personal-admin.conf
profile customer-a-audit = 30-customer-a-audit.conf

# ---- everything below is verbatim AWS config INI ----

[default]
output = json

[sso-session personal]
sso_start_url = https://d-1234567890.awsapps.com/start
sso_region    = eu-west-2

[sso-session customer-a]
sso_start_url = https://d-abcdef0123.awsapps.com/start
sso_region    = us-east-1

[profile personal-admin]
sso_session    = personal
sso_account_id = 111122223333
sso_role_name  = AdministratorAccess
region         = eu-west-2

[profile customer-a-audit]
sso_session    = customer-a
sso_account_id = 444455556666
sso_role_name  = SecurityAudit
region         = us-east-1
```

## The three control sections

- **`[awsconfd]`** - `version` (must be `1`) and `strict`. Rejected with a
  usage error if `version` isn't `1`.
- **`[awsconfd:scheme]`** - the same `range = label` lines that go in
  `scheme.conf`. Written to `scheme.conf` **only if that file doesn't
  already exist**. If it exists and differs, the difference is reported and
  your existing file wins, unless you pass `--force` (which asks for
  confirmation before overwriting).
- **`[awsconfd:layout]`** - keys are **raw section headers** exactly as
  they appear below (`default`, `profile personal-admin`,
  `sso-session personal`), values are the fragment filename that section
  should live in. Several sections can share one filename (both
  `sso-session` lines above land in `10-sso.conf`).

## Applying

Every section below the control sections is a payload section, applied in
file order:

- If it has a layout entry, it's written there.
- If it doesn't, it's placed by the scheme (the label inferred from its
  section type: `sso-session` → the `sso-sessions` label, `profile` →
  asked interactively or, under `--non-interactive`, allocated the lowest
  free prefix with a **W2** warning). Placement-by-inference is always
  logged so you can see what happened.
- If the section **already exists** anywhere in `config.d` (checked across
  every fragment, not just the target), it's **skipped** and reported -
  never silently overwritten. `--force` upserts into the fragment it
  already lives in, not wherever the layout/scheme says it should go
  (moving sections between fragments is left as a manual operation).

Application is transactional: the whole operation runs against a staged
copy of `config.d` in a temp directory first, gets validated there, and
only commits (copies over the real `config.d`) if validation passes. A spec
that would leave you with a broken config.d is rejected before anything
real changes.

`--dry-run` prints the full plan (`CREATE 20-x.conf [profile x]` /
`SKIP ...` / `UPDATE ...`) and writes nothing, including `scheme.conf`.

`awsconfd apply --spec -` reads the spec from stdin.

See `examples/` for three worked specs: a single personal org with SSO, a
personal org plus two customer orgs, and a cross-account assume-role setup.
