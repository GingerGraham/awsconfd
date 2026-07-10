# Validation rules

Two commands surface validation: `awsconfd doctor` runs everything below and
reports it verbosely. `awsconfd build` runs the **blocking** rules only,
silently, before assembling - warnings never appear on a plain `build`, only
on `doctor`. This is deliberate: `build` is what the watcher calls on every
login and every fragment change, and a wall of advisory text on every login
would train you to ignore it.

Every blocking rule reports **all** violations before exiting, not just the
first, and names the offending file and line.

If you need help choosing between `source_profile`, `credential_source`, and
`credential_process`, see [`docs/auth-paths.md`](auth-paths.md).

## Auto-fixable - `doctor --fix`

`build` never performs these (constraint 2.4: build must never write inside
`config.d`). Only `doctor --fix` does.

| #   | Condition                          | Fix           |
| --- | ---------------------------------- | ------------- |
| F1  | Fragment lacks a trailing newline  | Append one    |
| F2  | Fragment has CRLF line endings     | Rewrite as LF |
| F3  | Fragment mode is not `0600`        | `chmod 0600`  |
| F4  | `config.d` mode is not `0700`      | `chmod 0700`  |
| F5  | `~/.aws/config` mode is not `0600` | `chmod 0600`  |

F1 is compensated for at assembly time regardless (a missing trailing
newline never breaks a build), so an unfixed F1 is cosmetic only.

## Blocking - `build` refuses, exit 3

| #   | Condition                                                                                                                                 | Message includes                                                             |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| B1  | Duplicate `[default]` across fragments                                                                                                    | both filenames                                                               |
| B2  | Duplicate `[profile x]` across fragments                                                                                                  | profile name, both filenames                                                 |
| B3  | Duplicate `[sso-session y]` across fragments                                                                                              | session name, both filenames                                                 |
| B4  | `sso_session = y` where `[sso-session y]` is defined nowhere                                                                              | suggests `awsconfd add-sso y`                                                |
| B5  | A profile has `sso_session` but lacks `sso_account_id` or `sso_role_name`                                                                 | which key is missing                                                         |
| B6  | A profile has both `sso_session` and `sso_start_url`                                                                                      | mutually exclusive - remove one                                              |
| B7  | A profile has `role_arn` but neither `source_profile` nor `credential_source`                                                             | both alternatives named                                                      |
| B8  | `source_profile = z` where `z` is undefined in both config.d and the shared credentials file (or `[default]` is undefined in both places) | the undefined name                                                           |
| B9  | `scheme.conf` declares overlapping ranges                                                                                                 | both entries                                                                 |
| B10 | `--strict` (or `strict = true` in scheme.conf) and a fragment's prefix falls outside every declared range                                 | the prefix, since there's no single "nearest" range in an arbitrary manifest |
| B11 | A profile has `credential_source` set to anything other than `Environment`, `Ec2InstanceMetadata`, or `EcsContainer`                      | the invalid value                                                            |

`--strict` with no `scheme.conf` at all is a **usage error** (exit 2), not a
validation failure - there's nothing to enforce.

## Advisory - warn, exit 0

| #   | Condition                                                                                                |
| --- | -------------------------------------------------------------------------------------------------------- |
| W1  | Filename doesn't match `^[0-9]{2}-[a-z0-9][a-z0-9._-]*\.conf$`                                           |
| W2  | Fragment prefix outside every declared range (non-strict only - see B10)                                 |
| W3  | No `region` resolvable for a profile (neither the profile nor `[default]`; env vars may still supply it) |
| W4  | Unknown section type - anything other than `default`/`profile`/`sso-session`/`services`                  |
| W5  | A `[sso-session]` is defined but referenced by no profile                                                |
| W6  | `sso_registration_scopes` absent from an `[sso-session]`                                                 |
| W7  | `config.d` contains a file that is neither `*.conf` nor `*.conf.disabled`                                |

## `credential_process` notes

`credential_process` profiles are supported as first-class `[profile ...]`
fragments. `awsconfd` validates their normal profile shape and region
resolution, but it does **not** execute the command during `build` or
`doctor`. If the command is malformed, missing from `PATH`, or returns bad
JSON at runtime, the AWS CLI will report that when the profile is used.

Because fragments are plain text, treat `credential_process` command strings
as configuration, not a secret store. `awsconfd` keeps fragments mode `0600`,
but they are not encrypted. If a command line embeds credentials or other
sensitive material directly, that risk is yours to manage.

## Post-build cross-check - non-fatal

If `aws` is on `PATH`, `build` compares the profile set `awsconfd` parsed
against `aws configure list-profiles`, including any profile names it can see
read-only in the shared credentials file. Any mismatch prints a loud warning
(our parser and AWS's disagree - almost certainly a bug in this tool, please
report it) but never blocks. If `aws` is absent, nothing is printed.

## A known, documented simplification

`add-sso`/`add-profile` merge new values with an existing section's
hand-added extra keys (§B1.3's "keys not in the canonical list survive an
update") for **top-level keys only**. If you've hand-added an indented
nested block (an `s3 =` sub-block) to a profile and then run `add-profile`
against that same profile to change something else, the nested block is not
preserved in the merge - only literal `key = value` top-level pairs are
carried forward. A plain `build` always passes nested blocks through
untouched; this limitation only applies to the add-sso/add-profile wizards'
merge step. If this bites you in practice, open an issue - it's a
solvable gap, just not done here.
