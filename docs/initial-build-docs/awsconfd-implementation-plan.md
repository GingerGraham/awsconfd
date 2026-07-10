# `awsconfd` — Implementation Plan

**Audience:** an implementing model (e.g. Claude Haiku) or engineer.
**Deliverables:** `install.sh`, `awsconfd`, `README.md`, `docs/`, `examples/`, `tests/`.
**Status:** design finalised. Write the code to this spec. Where the spec is silent, prefer the simplest behaviour and note the assumption in a comment.

---

## 1. Purpose

AWS CLI has no native `include` or `config.d` support ([aws-cli#9036](https://github.com/aws/aws-cli/issues/9036), open since 2022, not on the roadmap). `~/.aws/config` must be a single file.

`awsconfd` gives that file a `config.d`-style source of truth: a directory of numbered INI fragments that are concatenated, validated, and installed as `~/.aws/config`, with a file watcher that rebuilds on change.

It solves three problems:

1. **Separation.** Organisation-level SSO configuration lives apart from per-identity, per-role profile configuration.
2. **Scale.** A user with twenty client organisations can give each its own file(s) under a numbering scheme they define.
3. **Safety.** The generated file is marked as generated; the fragments are never silently rewritten; hand-added fragments are tolerated as first-class inputs.

---

## 2. Hard constraints

These are not negotiable. Violating any of them is a bug.

### 2.1 Zero runtime dependencies

Beyond a POSIX userland and bash, the script may rely only on: `curl` **or** `wget` (install-time only), `sha256sum` **or** `shasum -a 256` (install-time only), and coreutils that exist on both GNU and BSD systems.

**Explicitly forbidden:** `jq`, `yq`, `python`, `awk` gawk-isms, `sed -i` (incompatible between GNU and BSD — always write to a temp file and `mv`), `readlink -f` (absent on stock macOS), `stat` with format flags (`-c` vs `-f`), `date -d` / `date -r` (GNU vs BSD), `realpath` (not on stock macOS), `mktemp -d --tmpdir`, `sort -V`, `grep -P`, `find -printf`.

Note that `[[ fileA -nt fileB ]]` is a bash builtin and needs no `stat`. Use it.

### 2.2 bash 3.2 floor

macOS ships GNU bash 3.2.57. Target it.

Forbidden: `declare -A` / associative arrays, `mapfile` / `readarray`, `${var,,}` and `${var^^}` (use `tr '[:upper:]' '[:lower:]'`), `local -n` / nameref, `${!array[@]}` on non-sparse assumption, `&>>`, `shopt -s globstar` / `**`, `printf '%(%s)T'`, `wait -n`, negative array indices.

Permitted and encouraged: `shopt -s nullglob`, `printf -v`, `local`, `[[ ]]`, `$(...)`, arrays, `set -euo pipefail`.

### 2.3 Determinism

`awsconfd build` must produce byte-identical output for identical input. **No timestamps, no hostnames, no PIDs, no `$RANDOM` in the generated file.** This is what makes the no-op path work (§6.4).

### 2.4 Never write into the watched directory during a build

The build reads `~/.aws/config.d/` and writes `~/.aws/config`. It must never create, touch, or `chmod` anything inside `config.d/` as part of `build`. (Permission repair happens in `doctor --fix`, which is never invoked by the watcher.) Otherwise the path unit re-triggers itself.

### 2.5 Secrets

`awsconfd` never reads, writes, parses, or backs up `~/.aws/credentials`. It never prompts for an access key or secret key. Static-credential profiles are configured by _referencing_ a credentials-file profile name, nothing more.

---

## 3. Naming

Binary: `awsconfd`. Repo: `awsconfd`. Config namespace: `awsconfd`.

If the name is changed later, it appears in: the two filenames, the unit/agent names, the `AWSCONFD_*` env prefix, the manifest path, and the `[awsconfd]` spec section. Keep it greppable — define `readonly PROG="awsconfd"` at the top of the script and use `${PROG}` everywhere in output strings.

---

## 4. Repository layout

```
awsconfd/
├── install.sh                       # curl|bash entry point. Downloads + installs awsconfd.
├── awsconfd                         # The script. Everything lives here.
├── awsconfd.sha256                  # Regenerated on release; verified by install.sh
├── README.md
├── LICENSE
├── docs/
│   ├── spec-file.md                 # The --spec format, in full
│   ├── numbering.md                 # Scheme manifest, ranges, --strict
│   ├── watcher.md                   # Layers 1-4, systemd + launchd, troubleshooting
│   └── validation.md                # Every rule, its exit code, and its fix
├── examples/
│   ├── single-org.spec.ini
│   ├── multi-customer.spec.ini
│   ├── assume-role.spec.ini
│   └── config.d/                    # An example populated config.d for reference
│       ├── 00-defaults.conf
│       ├── 10-sso.conf
│       ├── 20-personal-admin.conf
│       └── 30-customer-a-audit.conf
└── tests/
    ├── run-tests.sh                 # Plain bash. No bats, no deps.
    └── fixtures/
```

---

## 5. On-disk layout produced by the tool

```
~/.aws/config                        # GENERATED. Mode 0600.
~/.aws/config.d/                     # Mode 0700. Source of truth.
│   ├── 00-defaults.conf             # [default] — usually near-empty
│   ├── 10-sso.conf                  # [sso-session ...] blocks. Org-level.
│   ├── 20-personal-admin.conf       # [profile ...] blocks. Identity-level.
│   ├── 21-personal-readonly.conf
│   ├── 30-customer-a-audit.conf
│   └── 99-imported.conf             # Migrated from a pre-existing ~/.aws/config
~/.aws/config.awsconfd-backup.<n>    # Numbered backups. Never overwritten.
~/.config/awsconfd/scheme.conf       # Numbering manifest. Not AWS INI. See §8.
```

`~/.aws/config.d/` contains **only** valid AWS INI. Nothing else. `awsconfd`'s own state lives under `${XDG_CONFIG_HOME:-$HOME/.config}/awsconfd/`.

### 5.1 The central / individual split

This falls directly out of AWS's own data model and should be explained to the user in exactly these terms:

| Belongs to the organisation | Belongs to the identity           |
| --------------------------- | --------------------------------- |
| `[sso-session <name>]`      | `[profile <name>]`                |
| `sso_start_url`             | `sso_session` (a reference)       |
| `sso_region`                | `sso_account_id`                  |
| `sso_registration_scopes`   | `sso_role_name`                   |
|                             | `region`, `output`, `role_arn`, … |

One `sso-session` is shared by every profile for that org. Adding a new role in an existing org touches only a profile fragment.

Section order in the built file is irrelevant to the AWS INI parser, so fragments are concatenated in `LC_ALL=C` lexical filename order and nothing more clever is required.

### 5.2 Fragment discovery

```bash
shopt -s nullglob
LC_ALL=C
for f in "${CONFIG_D}"/*.conf; do ...; done
```

- Only `*.conf` is read. `*.conf.disabled`, `*.conf.bak`, editor swap files, and dotfiles are ignored — this is the documented way to temporarily disable a fragment.
- Filenames should match `^[0-9]{2}-[a-z0-9][a-z0-9._-]*\.conf$`. A non-matching name is a **warning**, not an error (it still gets included), because tolerating hand-added files is a design goal.
- Symlinks are followed. Directories under `config.d/` are ignored.

---

## 6. `build` — the core algorithm

`awsconfd build` is the only thing that writes `~/.aws/config`. It must be safe to run at any moment, concurrently-ish, and from a systemd unit.

### 6.1 Output path resolution

```
${AWSCONFD_CONFIG_FILE:-${AWS_CONFIG_FILE:-$HOME/.aws/config}}
```

`AWS_CONFIG_FILE` is respected because it is AWS's own variable; `AWSCONFD_CONFIG_FILE` overrides it and exists for tests. Similarly `${AWSCONFD_CONFIG_DIR:-<dirname of output>/config.d}`.

### 6.2 Steps

1. **Discover** fragments (§5.2). If `config.d` does not exist → exit 1 with "run `awsconfd init` first".
2. **Parse** every fragment for section headers only (§7). Collect `(section_type, section_name, source_file, line_no)`.
3. **Validate** (§9). If any blocking rule fails → print all failures, exit 3, **do not touch the output file**.
4. **Assemble** into a temp file (§6.3).
5. **Compare.** If the temp file is byte-identical to the existing output (`cmp -s`), delete the temp file and exit 0 with no message at `--quiet`, or `"config is up to date"` otherwise. **Do not touch the output file's mtime.**
6. **Back up** the existing output, once, if this is the first build over a file that lacks the generated-file banner (§6.5).
7. **Install:** `chmod 0600` the temp file, then `mv` it over the output. `mv` within the same filesystem is atomic. If `TMPDIR` is on a different filesystem the `mv` degrades to copy+unlink, so create the temp file **in the same directory as the output**: `mktemp "${output_dir}/.awsconfd.XXXXXX"`. Trap `EXIT`/`INT`/`TERM` to remove it.
8. **Post-check** (§9.4), non-fatal.

### 6.3 Assembled file structure

```
# ==============================================================================
#  GENERATED FILE - DO NOT EDIT
#
#  This file is assembled by awsconfd from the fragments in:
#      ~/.aws/config.d/*.conf
#
#  Any edit made here will be silently lost the next time the file is rebuilt.
#  Edit the fragments instead, then run:
#      awsconfd build
#
#  fragments-digest: 3f9c1a...   (sha256 of the concatenated fragment bodies)
# ==============================================================================

# ------------------------------------------------------------------ 00-defaults.conf
[default]
region = eu-west-2
output = json

# ------------------------------------------------------------------ 10-sso.conf
[sso-session personal]
sso_start_url = https://d-1234567890.awsapps.com/start
...
```

Rules:

- The banner is **static text plus a digest**. The digest is a sha256 of the concatenated fragment bodies (not the banner), computed by `sha256sum` or `shasum -a 256`, whichever exists. If neither exists, omit the `fragments-digest` line entirely — do not substitute anything non-deterministic. The path shown in the banner is the literal resolved `CONFIG_D`, with `$HOME` collapsed to `~`.
- Provenance comments (`# ---- <basename>`) precede each fragment. Suppressible with `--no-provenance` for users who find them noisy; the flag is recorded nowhere, so it must be passed to every build (document this).
- Each fragment body is emitted verbatim. A missing trailing newline is compensated for at assembly time (emit one) — **without modifying the fragment**.
- Exactly one blank line separates fragments.

### 6.4 The no-op guarantee

Step 5 is load-bearing. Because `build` runs at login (watcher Layer 2) and on every fragment change (Layer 1), a build that rewrites an unchanged file would churn the mtime on every login and could, if anything ever watched the output, loop. Determinism (§2.3) plus `cmp -s` gives a true no-op.

Consequence: the fragments-digest line must change **only** when fragment content changes. It does. Do not add a version string to the banner unless you accept a rewrite on every upgrade (acceptable, but must be a deliberate choice — the spec says: **no version string in the banner**; `awsconfd --version` reports it instead).

### 6.5 Backups

Backups are taken by `init` (§10.1) and by `build` only in the one case where it is about to overwrite a file that does _not_ carry the generated banner — i.e. a config that a human wrote.

Naming: `~/.aws/config.awsconfd-backup.1`, `.2`, … Find the lowest unused integer. Never overwrite. Never delete. `awsconfd status` reports how many exist.

---

## 7. INI parsing

The parser is deliberately shallow. It identifies section headers and passes everything else through untouched.

**A section header** is a line matching `^[[:space:]]*\[(.+)\][[:space:]]*$`. Recognised types:

| Raw header          | type          | name      |
| ------------------- | ------------- | --------- |
| `[default]`         | `default`     | `default` |
| `[profile foo]`     | `profile`     | `foo`     |
| `[sso-session bar]` | `sso-session` | `bar`     |
| `[services baz]`    | `services`    | `baz`     |
| anything else       | `unknown`     | _raw_     |

`unknown` sections produce a warning and are passed through. (AWS may add section types; do not hard-fail on the future.)

**Comments** are lines whose first non-whitespace character is `#` or `;`.

**Keys** are `^[[:space:]]*([A-Za-z0-9_-]+)[[:space:]]*=(.*)$`.

**Critical:** AWS config supports _nested_ settings via indentation:

```ini
[profile foo]
s3 =
    max_concurrent_requests = 20
    max_queue_size = 10000
```

An indented `key = value` line is a **child** of the preceding top-level key, not a new setting. The parser must not confuse these. Since we only extract section headers and, for validation, top-level keys within a section, the rule is: **a key line only counts as a top-level key if it has no leading whitespace.** Indented lines are opaque body content.

Trailing inline comments after a value (` # foo`) are legal in AWS INI. Strip them for validation purposes only; never rewrite the fragment.

---

## 8. The numbering scheme manifest

Path: `${XDG_CONFIG_HOME:-$HOME/.config}/awsconfd/scheme.conf`.

This file exists so that filenames carry meaning that the tool can check and explain. **The example prefixes below are examples. Every label and every range is user-defined. There are no built-in reserved ranges except that `init` seeds `00` and `10` and documents them as conventional, not mandatory.**

```ini
# ~/.config/awsconfd/scheme.conf
[awsconfd]
version = 1
strict  = false

[scheme]
00    = defaults
10    = sso-sessions
2x    = personal
30-39 = customer-a
40-49 = customer-b
55    = one-off-audit-account
```

### 8.1 Range syntax

| Form    | Meaning                     |
| ------- | --------------------------- |
| `NN`    | exactly that prefix         |
| `Nx`    | the decade `N0`–`N9`        |
| `NN-MM` | inclusive range, `NN <= MM` |

Overlapping ranges in the manifest are a hard error on load — report both entries.

### 8.2 Behaviour

- **Default (`strict = false`):** creating a fragment whose numeric prefix falls outside every declared range, or inside a range whose label does not match the fragment's evident purpose, emits a **warning** naming the range that _would_ have fitted, and proceeds. This is the "20+ customers, I need most of 00–99" case — the user is never blocked.
- **`strict = true` or `--strict`:** the same condition is an error. `build` refuses (exit 3); `add-profile` refuses (exit 2) and prints the next free number inside the appropriate range.
- Fragments with no manifest entry covering them are always permitted when not strict.
- A manifest that does not exist means "no scheme declared" — every number is acceptable, no warnings. `--strict` with no manifest is a usage error.

### 8.3 Next-number allocation

`add-profile --label customer-a` finds the range for `customer-a`, lists existing fragments in it, and picks the lowest unused prefix. If the range is full: error, naming the range and suggesting the manifest be widened. If the label is unknown and not strict: prompt for a prefix, defaulting to the lowest unused prefix overall.

---

## 9. Validation

Two commands surface this: `awsconfd doctor` (standalone, verbose, exit 3 on failure, `--fix` for the auto-fixable) and `awsconfd build` (runs the blocking rules only, silently, before assembling).

### 9.1 Auto-fixable — `doctor --fix`

Never performed by `build` (§2.4).

| #   | Condition                          | Fix           |
| --- | ---------------------------------- | ------------- |
| F1  | Fragment lacks a trailing newline  | Append one    |
| F2  | Fragment has CRLF line endings     | Rewrite as LF |
| F3  | Fragment mode is not `0600`        | `chmod 0600`  |
| F4  | `config.d` mode is not `0700`      | `chmod 0700`  |
| F5  | `~/.aws/config` mode is not `0600` | `chmod 0600`  |

F1 is compensated for at assembly time regardless, so an unfixed F1 never breaks a build.

### 9.2 Blocking — build refuses, exit 3

Report **all** violations before exiting, not just the first. Each message names the offending file and line number.

| #   | Condition                                                                                  | Message must include          |
| --- | ------------------------------------------------------------------------------------------ | ----------------------------- |
| B1  | Duplicate `[default]` across fragments                                                     | Both filenames                |
| B2  | Duplicate `[profile x]` across fragments                                                   | Profile name, both filenames  |
| B3  | Duplicate `[sso-session y]` across fragments                                               | Session name, both filenames  |
| B4  | `sso_session = y` where `[sso-session y]` is defined nowhere                               | Suggest `awsconfd add-sso y`  |
| B5  | A profile has `sso_session` but lacks `sso_account_id` or `sso_role_name`                  | Which key is missing          |
| B6  | A profile has both `sso_session` and `sso_start_url` (legacy + modern, mutually exclusive) | Which to remove               |
| B7  | A profile has `role_arn` but neither `source_profile` nor `credential_source`              | Both alternatives             |
| B8  | `source_profile = z` where `[profile z]` (or `[default]`, when `z = default`) is undefined | The undefined name            |
| B9  | Manifest declares overlapping ranges                                                       | Both entries                  |
| B10 | `--strict` and a fragment prefix falls outside all declared ranges                         | The prefix, the nearest range |

### 9.3 Advisory — warn, exit 0

| #   | Condition                                                                                              |
| --- | ------------------------------------------------------------------------------------------------------ |
| W1  | Filename does not match `^[0-9]{2}-[a-z0-9][a-z0-9._-]*\.conf$`                                        |
| W2  | Fragment prefix outside all declared ranges (non-strict)                                               |
| W3  | No `region` resolvable for a profile (neither in the profile nor `[default]`) — env vars may supply it |
| W4  | Unknown section type (§7)                                                                              |
| W5  | A `[sso-session]` is defined but referenced by no profile                                              |
| W6  | `sso_registration_scopes` absent from an `sso-session` (AWS defaults it, but being explicit is better) |
| W7  | `config.d` contains a file that is not `*.conf` and not `*.conf.disabled`                              |

### 9.4 Post-build cross-check — non-fatal

If `aws` is on `PATH`:

```bash
aws configure list-profiles
```

Compare the returned set against the set `awsconfd` parsed. Any asymmetry means our parser and AWS's disagree — print both sets and a loud warning, but exit 0. This is the canary for parser bugs and must never block the user.

If `aws` is absent, say nothing.

---

## 10. Subcommands

Global flags, accepted before or after the subcommand: `--help/-h`, `--version/-V`, `--quiet/-q`, `--verbose/-v`, `--dry-run`, `--yes/-y` (assume yes), `--strict`, `--config-dir <path>`, `--config-file <path>`, `--no-color`.

Colour: only when `stdout` is a TTY, `NO_COLOR` is unset, and `--no-color` was not passed.

Interactivity: **all prompts read from `/dev/tty`, never stdin.** This is what makes the wizard work under `curl … | bash`. If `/dev/tty` cannot be opened and the command needs input, exit 2 with a message directing the user to `--spec` or `--non-interactive`.

Exit codes: `0` success · `1` runtime error · `2` usage error · `3` validation failure · `4` `status --check` found the config stale.

### 10.1 `init`

The first-run command. Idempotent; safe to re-run.

1. Create `~/.aws` (0700), `~/.aws/config.d` (0700), `~/.config/awsconfd` (0700).
2. If `~/.aws/config` exists **and** does not carry the generated banner:
   - Take a numbered backup (§6.5).
   - Unless `--no-import`: copy it verbatim to `config.d/99-imported.conf`, mode 0600, prepending a comment block explaining where it came from and that it may be split up freely.
   - With `--no-import`: leave the original in place on disk as the backup only; `config.d` starts empty and the first `build` will replace `~/.aws/config` with a near-empty file. Warn loudly and require `--yes` or confirmation.
3. If `config.d` is empty, seed `00-defaults.conf` containing a commented-out `[default]` stanza. Realistically there is little to put here — region and output are usually better set per-org in the profile or per-session — so the seed is comments, not live keys.
4. If `scheme.conf` does not exist, write the version-1 manifest with `00 = defaults` and `10 = sso-sessions` and a commented block showing how to add ranges.
5. Never overwrite an existing `00-defaults.conf`, `99-imported.conf`, or `scheme.conf`.
6. Run `build`.
7. Print a "what next" block: `add-sso`, `add-profile`, `watch --install`.

Flags: `--no-import`, `--yes`.

### 10.2 `add-sso [<name>]`

Wizard. Writes `[sso-session <name>]` into the fragment mapped to the `sso-sessions` label (default `10-sso.conf`), creating it if absent, **appending** if present.

Prompts: session name, `sso_start_url`, `sso_region`, `sso_registration_scopes` (default `sso:account:access`).

If `[sso-session <name>]` already exists: show the current values, offer update-in-place (rewrite only that section, preserving the rest of the file byte-for-byte outside the section) or abort. Never silently overwrite.

Then `build`.

### 10.3 `add-profile [<name>]`

Wizard. Four types, prompted in this order, SSO first and default:

1. **SSO** — pick from the defined `sso-session`s (or offer to run `add-sso`), then `sso_account_id`, `sso_role_name`, `region`, `output`.
2. **Assumed role** — `role_arn`, then `source_profile` (picked from defined profiles) _or_ `credential_source` (`Environment` | `Ec2InstanceMetadata` | `EcsContainer`), optional `mfa_serial`, `external_id`, `duration_seconds`, `region`.
3. **Static IAM** — prompts for the _name of a profile in `~/.aws/credentials`_ and writes only the non-secret config keys (`region`, `output`). Explains that credentials themselves live in `~/.aws/credentials`, which `awsconfd` does not manage. **Never prompts for a key.**
4. **`credential_process`** — the command string, `region`, `output`.

Placement: `--file <name>` to target a fragment explicitly, or `--label <label>` to allocate a number from that scheme range (§8.3), or interactively pick. Appends to an existing fragment; creates with mode 0600 if new.

Existing `[profile <name>]` → same update-or-abort behaviour as `add-sso`.

Then `build`.

### 10.4 `build`

§6. Flags: `--no-provenance`, `--dry-run` (print the assembled file to stdout, write nothing), `--strict`.

### 10.5 `apply --spec <file>`

Non-interactive. Explodes a spec file (§11) into `config.d/`, then builds.

- Sections are written to the file named in `[awsconfd:layout]`.
- A section with no layout entry is placed by the scheme (§8.3) with a warning.
- Existing sections: **not** overwritten unless `--force`. Report each skip.
- `--dry-run` prints the fragment-to-content plan and writes nothing.

### 10.6 `watch --install | --uninstall | --status`

§12. Flags: `--with-timer`, `--interval <systemd OnCalendar or launchd seconds>`.

### 10.7 `hook <bash|zsh>`

Prints shell code to stdout for `eval "$(awsconfd hook bash)"`. §12.3.

### 10.8 `status`

Prints:

- Resolved config dir, config file, manifest path.
- Fragment table: filename, prefix, scheme label (or `—`), section count, section names.
- Whether the live config carries the generated banner.
- **Staleness:** live config older than any fragment, or older than `config.d` itself. Pure bash: `[[ "$f" -nt "$out" ]]` and `[[ "$CONFIG_D" -nt "$out" ]]` (the directory mtime catches deletions and renames).
- Watcher state per layer: installed? enabled? running? `ExecStart` path still valid?
- Backup count.

`--check` suppresses output and exits `4` if stale, `0` if current. For scripts and for the shell hook.

### 10.9 `doctor [--fix]`

§9. `--fix` performs F1–F5 only.

### 10.10 `list`

`list profiles` | `list sso-sessions` | `list fragments`. Machine-readable with `--porcelain` (tab-separated, no headers, no colour).

### 10.11 `edit <fragment>`

Opens `$VISUAL`/`$EDITOR` on the fragment (resolving a bare `20` or `20-personal` to the full filename), then builds on exit. Refuses to open `~/.aws/config`.

### 10.12 `disable <fragment>` / `enable <fragment>`

`mv` to/from `.conf.disabled`. Then build.

### 10.13 `self-update`

Re-runs the install logic against the latest release, verifying the checksum. Refuses if the running script is not the installed one (compare resolved paths without `readlink -f` — use a `cd "$(dirname "$0")" && pwd -P` idiom).

### 10.14 `uninstall [--purge]`

Removes the watcher units/agents. Prints, but does not run, the command to remove the binary. `--purge` additionally offers to restore the newest backup over `~/.aws/config` and to remove `config.d/` and the manifest — each confirmed separately, never under `--yes` alone without an explicit `--purge`.

---

## 11. The spec file format

**INI, not YAML, not JSON.** Rationale: `yq` is inconsistently packaged (Ubuntu ships the unrelated Python `yq` 3.x; mikefarah's v4 is a separate binary), `jq` is not ubiquitous, and installing packages is out of scope. INI needs no parser beyond the one already written for fragments.

A spec file is a valid AWS config file plus two `awsconfd:`-namespaced sections. This means it can be linted by eye, and an existing `~/.aws/config` is _almost_ a valid spec already.

```ini
# examples/multi-customer.spec.ini

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
profile personal-ro      = 21-personal-readonly.conf
profile customer-a-audit = 30-customer-a-audit.conf

# ---- everything below is verbatim AWS config INI ----

[default]
output = json

[sso-session personal]
sso_start_url           = https://d-1234567890.awsapps.com/start
sso_region              = eu-west-2
sso_registration_scopes = sso:account:access

[sso-session customer-a]
sso_start_url           = https://d-abcdef0123.awsapps.com/start
sso_region              = us-east-1
sso_registration_scopes = sso:account:access

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

Layout keys are the raw section header contents (`profile foo`, `sso-session bar`, `default`). `[awsconfd:scheme]` is written to `scheme.conf` if that file does not exist; if it does, differences are reported and the existing file wins unless `--force`.

`awsconfd apply --spec -` reads from stdin.

Provide all three examples listed in §4, each with a header comment explaining what it demonstrates.

---

## 12. The watcher — four layers

The watcher is a **latency optimisation**. The staleness check is the **correctness backstop**. `build` is always available manually. Nothing is ever load-bearing on the watcher.

### 12.1 Linux (systemd user units)

Installed to `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/`.

**`awsconfd-build.service`**

```ini
[Unit]
Description=Rebuild ~/.aws/config from ~/.aws/config.d
Documentation=https://github.com/GingerGraham/awsconfd

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 0.5
ExecStart=%h/.local/bin/awsconfd build --quiet
Nice=10

[Install]
WantedBy=default.target
```

`ExecStart` is the **absolute resolved install path**, substituted at `watch --install` time — `systemd --user` provides a minimal `PATH` and `%h/.local/bin` is not necessarily on it. Write the literal path, not `%h/...`, unless the install prefix genuinely is under `$HOME` (in which case `%h` is fine and nicer). The `sleep 0.5` is a debounce: editors emit several inotify events per save, and a path unit does not re-arm until the triggered service has exited, so without it the _last_ event of a burst can be dropped.

`WantedBy=default.target` is **Layer 2** — the service runs once at session start. Because `build` is a genuine no-op on unchanged input (§6.4), this is free, and it repairs every case the watcher structurally cannot see: the machine was off, the unit was masked, the fragments arrived via `git pull` while logged out.

**`awsconfd-build.path`**

```ini
[Unit]
Description=Watch ~/.aws/config.d for changes
Documentation=https://github.com/GingerGraham/awsconfd

[Path]
PathChanged=%h/.aws/config.d
Unit=awsconfd-build.service

[Install]
WantedBy=default.target
```

`PathChanged` on a directory places an inotify watch on the directory, and inotify directory watches report `IN_CLOSE_WRITE` for direct children — so in-place edits to a fragment _do_ fire, as do creates, deletes, and renames. **Verify this on a real system** (`echo "" >> ~/.aws/config.d/00-defaults.conf` then `systemctl --user status awsconfd-build.service`) rather than trusting this paragraph; if it does not fire, Layers 2 and 3 already cover it and the path unit is simply less useful than hoped.

Enable: `systemctl --user daemon-reload && systemctl --user enable --now awsconfd-build.path awsconfd-build.service`.

Non-systemd Linux (containers, WSL1, minimal servers): detect the absence of `systemctl` **and** a running user manager (`systemctl --user is-system-running` or `$XDG_RUNTIME_DIR/systemd`), and fall back to recommending Layer 3 with a clear message. Do not fail.

Headless / never-logged-in hosts need `loginctl enable-linger $USER` — mention it in `docs/watcher.md` and in `watch --install` output when `--with-timer` is passed.

### 12.2 macOS (launchd user agent)

`~/Library/LaunchAgents/com.GingerGraham.awsconfd.plist`:

```xml
<key>Label</key>            <string>com.GingerGraham.awsconfd</string>
<key>ProgramArguments</key> <array>
                              <string>/Users/<user>/.local/bin/awsconfd</string>
                              <string>build</string>
                              <string>--quiet</string>
                            </array>
<key>WatchPaths</key>       <array><string>/Users/<user>/.aws/config.d</string></array>
<key>RunAtLoad</key>        <true/>
```

`RunAtLoad` is Layer 2. `launchctl bootstrap gui/$(id -u) <plist>` (modern) with a fallback to `launchctl load -w` on older systems.

**Known limitation, must be documented:** `WatchPaths` on a _directory_ fires reliably on directory-mtime changes — file creation, deletion, rename — but an in-place append (`echo >> file`) may not change the directory mtime and may therefore not fire. Editors that save via write-temp-then-rename (vim, VS Code, most GUI editors) do change it and work fine. This is precisely the gap Layer 3 closes, so `watch --install` on macOS **prints a recommendation to also install the shell hook.**

### 12.3 Layer 3 — the shell hook (opt-in)

```bash
eval "$(awsconfd hook bash)"   # or: eval "$(awsconfd hook zsh)"
```

Emits a function that runs the staleness check — `[[ fragment -nt config ]]` for each fragment plus the directory, all bash builtins, **no subprocess, no fork** — and calls `awsconfd build --quiet` only when stale. Registered on `PROMPT_COMMAND` (bash, appended safely, not clobbered) or `precmd_functions` (zsh).

Guard it: skip entirely if `AWSCONFD_HOOK_DISABLE` is set, and no-op if `config.d` does not exist.

This is the only layer that closes the macOS in-place-append gap, and the only one that works with no init system at all. It is deliberately not installed automatically — printing the line for the user to add is the whole interface.

### 12.4 Layer 4 — safety-net timer (opt-in, `--with-timer`)

`awsconfd-build.timer` with `OnCalendar=hourly` and `Persistent=true`; launchd `StartInterval`. Only meaningful on headless hosts where nobody ever opens a shell and nothing ever triggers Layer 2. Redundant otherwise, hence off by default.

---

## 13. `install.sh`

Small. Stateless. Does one thing.

1. `set -euo pipefail`. Detect `curl` or `wget`; error clearly if neither.
2. Resolve version: `--version <tag>` or default to `latest` via the GitHub releases redirect (**no `jq`** — use the `/releases/latest/download/<asset>` URL form, which redirects without needing the API).
3. Download `awsconfd` and `awsconfd.sha256` to a temp dir. Verify with `sha256sum -c` or `shasum -a 256 -c`. If neither exists, warn and continue only with `--no-verify`; otherwise abort.
4. Install to `${AWSCONFD_PREFIX:-${XDG_BIN_HOME:-$HOME/.local/bin}}`, `chmod 0755`. Create the directory if needed.
5. **PATH:** if the prefix is not on `PATH`, print the exact `export PATH="…:$PATH"` line to add and which file to add it to. Append to an rc file **only** under `--modify-path`, and then only to one file, chosen by `$SHELL`, and only after checking the line is not already present.
6. Unless `--no-init`, `exec` the installed binary with `init`. Because `init`'s prompts read `/dev/tty`, this works under `curl … | bash`.

Flags: `--version <tag>`, `--prefix <dir>`, `--local` (copy `./awsconfd` from the working tree instead of downloading — for `git clone` users), `--no-init`, `--no-verify`, `--modify-path`, `--help`.

Usage in README:

```bash
curl -fsSL https://raw.githubusercontent.com/GingerGraham/awsconfd/main/install.sh | bash
```

and

```bash
git clone https://github.com/GingerGraham/awsconfd && cd awsconfd && ./install.sh --local
```

---

## 14. `--help` output

`awsconfd --help` prints exactly this shape. Each subcommand additionally supports `awsconfd <cmd> --help` with its own flags and one worked example.

```
awsconfd - manage ~/.aws/config as a config.d directory

USAGE
    awsconfd <command> [options]

DESCRIPTION
    AWS CLI has no native support for including multiple config files.
    awsconfd keeps the real configuration as numbered INI fragments in
    ~/.aws/config.d/ and assembles them into ~/.aws/config, optionally
    rebuilding automatically whenever a fragment changes.

    Organisation-level SSO settings live in [sso-session] blocks, shared
    by every profile for that organisation. Identity- and role-level
    settings live in [profile] blocks. Splitting them across files is the
    point of the tool.

    awsconfd never reads or writes ~/.aws/credentials.

COMMANDS
    init                 Create config.d, import any existing config, build
    add-sso [NAME]       Add or update an [sso-session] block
    add-profile [NAME]   Add or update a [profile] block
    apply --spec FILE    Create fragments from a spec file, then build
    build                Assemble ~/.aws/config from the fragments
    status               Show fragments, staleness, and watcher state
    doctor [--fix]       Validate the fragments; optionally repair
    list SUBJECT         List profiles | sso-sessions | fragments
    edit FRAGMENT        Edit a fragment in $EDITOR, then build
    enable  FRAGMENT     Re-enable a disabled fragment
    disable FRAGMENT     Exclude a fragment from the build
    watch --install      Install the file watcher (systemd or launchd)
    hook bash|zsh        Print shell integration for eval
    self-update          Update awsconfd in place
    uninstall            Remove the watcher; optionally restore a backup

GLOBAL OPTIONS
    -h, --help           Show this help, or help for a command
    -V, --version        Print the version
    -q, --quiet          Suppress informational output
    -v, --verbose        Show what is being read and written
    -y, --yes            Assume yes to confirmations
        --dry-run        Show what would change; write nothing
        --strict         Enforce the numbering scheme in scheme.conf
        --config-dir DIR Override ~/.aws/config.d
        --config-file F  Override ~/.aws/config
        --no-color       Disable coloured output

FILES
    ~/.aws/config             Generated. Do not edit.
    ~/.aws/config.d/*.conf    The source of truth.
    ~/.config/awsconfd/scheme.conf   Your numbering scheme.

EXIT STATUS
    0  success
    1  runtime error
    2  usage error
    3  validation failure
    4  status --check: the config is stale

EXAMPLES
    # First run
    awsconfd init
    awsconfd add-sso personal
    awsconfd add-profile personal-admin
    awsconfd watch --install

    # Reproduce a setup on a new machine
    awsconfd apply --spec ~/dotfiles/aws/multi-customer.spec.ini

    # Check before a rebuild
    awsconfd doctor && awsconfd build

See https://github.com/GingerGraham/awsconfd for full documentation.
```

---

## 15. README outline

1. **What and why** — the missing `include`, in three sentences, with the upstream issue linked.
2. **Install** — the `curl | bash` line and the clone line. State plainly that the script is downloaded, checksum-verified, and left at `~/.local/bin/awsconfd`; that PATH is not modified without `--modify-path`; and that `curl | bash` is inspectable at the linked raw URL.
3. **Quick start** — `init`, `add-sso`, `add-profile`, `watch --install`, in a single fenced block with the real output shown.
4. **How it works** — the config.d → build → config pipeline, one diagram, the banner, the no-op guarantee.
5. **Organising your config** — the central/individual table from §5.1. The numbering scheme, with the explicit statement that `2x = personal` is an _example_ and that every label and range is user-defined. The 20-customer case.
6. **The watcher** — the four layers, what each covers, why Layer 2 is the one that matters, the macOS `WatchPaths` limitation stated plainly, and how to verify with `awsconfd status`.
7. **Spec files** — round-tripping a setup between machines.
8. **Validation** — the table from §9, with the fix for each.
9. **Hand-edited fragments** — the tool tolerates them; it only rewrites sections it is explicitly asked to update; `*.conf.disabled` is the off switch.
10. **What it does not do** — credentials, package installation, `aws sso login`, IAM policy.
11. **Uninstall.**
12. **Troubleshooting** — path unit not firing, `PATH` in systemd units, linger for headless hosts, `aws configure list-profiles` mismatch.

Every code block must be copy-pasteable and correct. No placeholder `<your-thing-here>` inside a command the reader is meant to run without editing.

---

## 16. Tests — `tests/run-tests.sh`

Plain bash, no framework, no dependencies. Exit 0 on pass. Each test runs in a fresh temp `HOME`-alike via `AWSCONFD_CONFIG_DIR` / `AWSCONFD_CONFIG_FILE` / `XDG_CONFIG_HOME`.

Required cases:

**Build**

- Empty `config.d` → config contains only the banner; exit 0.
- Two fragments → both present, in `LC_ALL=C` filename order, with provenance comments.
- `--no-provenance` → no `# ----` lines.
- Fragment without a trailing newline → assembled file does not run two sections together; the fragment on disk is unchanged.
- **Idempotency:** run `build` twice; the second run must not change the output file's mtime.
- **Determinism:** two builds from the same input produce byte-identical files.
- Fragment with nested indented settings (`s3 =` block) → passed through verbatim, not misparsed.
- `*.conf.disabled` and dotfiles are excluded.
- `--dry-run` writes nothing.
- Temp file is created beside the output, and is removed on `SIGINT`.

**Validation** — one test per rule B1–B10 asserting exit 3 and the presence of the required substrings in the message; one per W1–W7 asserting exit 0 and a warning.

- Blocking failure leaves the pre-existing `~/.aws/config` byte-for-byte unchanged.

**Init**

- Pre-existing hand-written config → backed up, imported to `99-imported.conf`, and the newly built config is semantically equivalent (same section set).
- `--no-import` → backup taken, no `99-imported.conf`.
- Re-running `init` overwrites nothing.
- Backup numbering: three inits over three hand-written configs give `.1`, `.2`, `.3`.

**Scheme**

- `2x`, `30-39`, `55` range forms all parse.
- Overlapping ranges → exit 3.
- Out-of-range fragment: warns non-strict, fails strict.
- `add-profile --label customer-a` allocates the lowest free number in the range.
- Full range → clear error.

**Spec**

- `apply --spec` on an empty `config.d` reproduces the fragments named in `[awsconfd:layout]`.
- Re-applying skips existing sections and reports them; `--force` overwrites.
- A section with no layout entry is placed by scheme and warned about.
- `--spec -` reads stdin.

**Watcher**

- `watch --install` on a host without `systemctl` and without `launchctl` → exits 0 with a Layer-3 recommendation, installs nothing.
- Generated unit files contain an absolute `ExecStart` that exists and is executable.
- `watch --uninstall` removes exactly what `--install` created.

**Status**

- `status --check` exits 4 after `touch`ing a fragment, 0 after `build`.
- Deleting a fragment (directory mtime changes, no fragment is newer) is still detected as stale.

**Portability**

- `grep -rn` over `awsconfd` and `install.sh` finds none of: `declare -A`, `mapfile`, `readarray`, `sed -i`, `readlink -f`, `realpath`, `local -n`, `${.*,,}`, `${.*^^}`, `jq `, `yq `, `stat -c`, `stat -f`, `grep -P`, `sort -V`. This is a real test, not a comment.
- `bash --posix`-hostile constructs aside, the script must pass `bash -n` and, if `shellcheck` is present, `shellcheck -s bash` with no errors (warnings may be suppressed with justification).

---

## 17. Non-goals

Do not implement, and say so in the README:

- Any handling of `~/.aws/credentials`.
- Installing or updating the AWS CLI.
- Wrapping `aws sso login` or token cache management.
- Managing IAM policies, accounts, or Identity Center itself.
- Encryption of fragments. They contain no secrets; if a `credential_process` command embeds one, that is the user's problem and the README says so.
- Windows / PowerShell. WSL is Linux and is covered when systemd is present; without it, Layer 3.
- Any dependency on, or knowledge of, an external dotfiles repository. Integration hooks are a separate future concern.

---

## 18. Implementation order

1. `awsconfd` skeleton: arg parsing, `PROG`, colour, logging (`_info`/`_warn`/`_err` to stderr), exit codes, `/dev/tty` prompt helper, temp-file trap helper.
2. INI parser (§7) and fragment discovery (§5.2). Test it against the nested-settings fixture first.
3. `build` (§6), including the no-op path. Test determinism and idempotency before anything else is built on top.
4. Validation (§9) and `doctor`.
5. `init`, backups, import.
6. Scheme manifest (§8), `status`, `list`.
7. `add-sso`, `add-profile` — the section-update-in-place logic is the fiddliest part; do it after `build` is proven.
8. `apply --spec`.
9. `watch`, `hook`.
10. `install.sh`, `self-update`, `uninstall`.
11. `README.md`, `docs/`, `examples/`.

Write `tests/run-tests.sh` alongside, not afterwards. Step 3's tests are the ones that catch the design-breaking bugs.
