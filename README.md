# awsconfd - AWS CLI config.d fragment manager

AWS CLI has no native `include` or `config.d` support
([aws-cli#9036](https://github.com/aws/aws-cli/issues/9036), open since
2022). `~/.aws/config` has to be a single file.

`awsconfd` gives that file a `config.d`-style source of truth: a directory
of numbered INI fragments that get concatenated, validated, and installed
as `~/.aws/config`, with an optional file watcher that rebuilds on change.

It solves three problems:

1. **Separation.** Organisation-level SSO configuration lives apart from
   per-identity, per-role profile configuration.
2. **Scale.** Managing twenty client organisations means giving each its
   own file(s) under a numbering scheme you define, not one file with
   twenty merge conflicts.
3. **Safety.** The generated file is marked as generated; fragments are
   never silently rewritten; hand-added fragments are tolerated as
   first-class input, not something the tool fights you over.

No dependencies beyond a POSIX userland, bash 3.2+, and `curl`/`wget` +
`sha256sum`/`shasum` at install time. Runs on Fedora/RHEL, Ubuntu/Debian,
openSUSE, Arch, macOS, and WSL2 (systemd assumed).

## Install

```bash
curl -fsSL https://github.com/GingerGraham/awsconfd/raw/main/install.sh | bash
```

The script downloads `awsconfd`, verifies its checksum against
`awsconfd.sha256`, and leaves it at `~/.local/bin/awsconfd`. Your `PATH`
isn't touched without `--modify-path`. Read it before running it - that's
the whole point of `curl | bash` being inspectable at the URL above.

Or from a clone:

```bash
git clone https://github.com/GingerGraham/awsconfd && cd awsconfd && ./install.sh --local
```

## Quick start

```bash
awsconfd init
awsconfd add-sso personal --start-url https://d-1234567890.awsapps.com/start --sso-region eu-west-2
awsconfd add-profile personal-admin --sso-session personal --sso-account-id 111122223333 --sso-role-name AdministratorAccess --region eu-west-2 --file 20-personal-admin.conf
awsconfd watch --install

# verify
awsconfd list profiles
aws configure list-profiles
```

`init` creates `~/.aws/config.d/`, imports any existing hand-written
`~/.aws/config` (backed up first, split into `99-imported.conf`, never
touched again unless you explicitly ask `awsconfd` to update a section in
it), and does a first build. `add-sso`/`add-profile` are small wizards that
write or update one `[section]` block at a time - run with no flags and
they'll prompt; pass flags for scripted, non-interactive use.

## How it works

```
~/.aws/config.d/
├── 00-defaults.conf       # [default]
├── 10-sso.conf            # [sso-session ...] blocks
├── 20-personal-admin.conf # [profile ...] blocks
└── 30-customer-a-audit.conf
         |
    awsconfd build
         |
~/.aws/config             # GENERATED. Do not edit by hand.
```

`build` discovers every `*.conf` fragment in `LC_ALL=C` filename order,
validates it (see [validation](#validation) below), and concatenates it
into `~/.aws/config` behind a banner that names where it came from and a
sha256 digest of the fragment contents. Running `build` twice with
unchanged fragments is a true no-op: byte-identical output, and the output
file's mtime isn't touched. `*.conf.disabled` files, dotfiles, and anything
that isn't `*.conf` are skipped - `enable`/`disable` toggle a fragment by
renaming it, then rebuild.

## Organising your config

This falls directly out of AWS's own data model:

| Belongs to the organisation | Belongs to the identity                              |
| --------------------------- | ---------------------------------------------------- |
| `[sso-session <name>]`      | `[profile <name>]`                                   |
| `sso_start_url`             | `sso_session` (a reference)                          |
| `sso_region`                | `sso_account_id`                                     |
| `sso_registration_scopes`   | `sso_role_name`, `region`, `output`, `role_arn`, ... |

One `sso-session` is shared by every profile for that org. Adding a new
role in an existing org touches only a profile fragment - never the
session, never anyone else's fragment.

### Numbering scheme

Fragment filenames follow `NN-name.conf`. What each `NN` prefix _means_ is
entirely up to you, declared in
`~/.config/awsconfd/scheme.conf` (`awsconfd init` seeds `00 = defaults` and
`10 = sso-sessions` as a starting convention, nothing more):

```ini
[scheme]
00    = defaults
10    = sso-sessions
2x    = personal
30-39 = customer-a
40-49 = customer-b
```

`2x` means the whole `20`-`29` decade; `30-39` is an explicit inclusive
range; `55` alone would mean exactly that prefix. By default
(`strict = false`), a fragment whose prefix falls outside every declared
range just gets a warning from `doctor` - you're never blocked, which
matters once you're managing twenty-plus client orgs and the manifest
hasn't caught up yet. Pass `--strict` (or set `strict = true`) to make that
warning block instead. Full details: [`docs/numbering.md`](docs/numbering.md).

## The watcher

```bash
awsconfd watch --install
```

Installs a systemd user path unit (Linux/WSL2) or a launchd agent (macOS)
that rebuilds `~/.aws/config` when `config.d` changes, plus a build at
login that repairs anything the watcher structurally can't see (machine was
off, `git pull` happened while logged out). On a host with neither -
containers, minimal servers, WSL without systemd - `watch --install` isn't
an error: it exits 0, installs nothing, and recommends the shell hook
instead:

```bash
eval "$(awsconfd hook bash)"   # or: hook zsh, in your .bashrc/.zshrc
```

This runs a zero-fork staleness check on every prompt and only ever calls
`awsconfd build --quiet` when something's actually stale. It's the only
layer that works everywhere, and the only one that closes a real gap on
macOS (`launchd`'s `WatchPaths` fires on directory-mtime changes -
create/delete/rename - but not always on an in-place append). Check
everything with `awsconfd status`. Full details:
[`docs/watcher.md`](docs/watcher.md).

## Spec files - reproducing a setup

```bash
awsconfd apply --spec examples/multi-customer.spec.ini
```

A spec file is a valid AWS config file plus two `awsconfd:`-namespaced
control sections (`[awsconfd:scheme]`, `[awsconfd:layout]`) that say which
fragment each section belongs in. Applying one is transactional - staged,
validated, and only committed if the result is clean - and never overwrites
an existing section unless you pass `--force`. See
[`docs/spec-file.md`](docs/spec-file.md) and the three worked examples in
[`examples/`](examples/).

## Validation

`awsconfd doctor` checks everything and reports it verbosely, with
`--fix` for the auto-fixable (trailing newlines, CRLF, file permissions).
`awsconfd build` runs the blocking rules only, silently, before assembling

- a violation prints every failure found and refuses to touch the output
  file. Full rule table: [`docs/validation.md`](docs/validation.md).

## Hand-edited fragments

Fully tolerated. `awsconfd` only ever rewrites a section you explicitly ask
it to update, via `add-sso`, `add-profile`, or `apply --spec`, and even
then only that one `[section]` block - every other byte of the fragment is
untouched. To temporarily disable a fragment without deleting it:

```bash
awsconfd disable 30-customer-a-audit
# ...
awsconfd enable 30-customer-a-audit
```

(Any of `30`, `30-customer-a-audit`, or `30-customer-a-audit.conf` works.)

## What it does **not** do

- **Credentials.** Never reads, writes, parses, or backs up
  `~/.aws/credentials`. Never prompts for an access key or secret key.
  Static-credential profiles reference a name in that file; the file itself
  is entirely yours.
- **AWS CLI installation or `aws sso login`.** Out of scope - use the AWS
  CLI itself for those.
- **IAM policy, accounts, or Identity Center management.**
- **Encryption.** Fragments contain no secrets by design; if a
  `credential_process` command embeds one, that's on you (the fragment is
  mode `0600`, not encrypted).
- **Windows/PowerShell.** WSL2 is supported when systemd is present;
  without it, the shell hook (Layer 3) still works everywhere.

## Uninstall

```bash
awsconfd watch --uninstall     # removes the systemd/launchd units it wrote
rm ~/.local/bin/awsconfd       # awsconfd uninstall prints this; doesn't run it for you
```

## Troubleshooting

**Path unit not firing (systemd):** check
`systemctl --user status awsconfd-build.path`; headless hosts need
`loginctl enable-linger $USER` for the login-time build to have anything to
trigger on. Manual rebuild always works: `awsconfd build`.

**`awsconfd list profiles` and `aws configure list-profiles` disagree:**
run `awsconfd status --check` - if it reports stale, `awsconfd build` and
recheck. If they still disagree after a fresh build, that's almost
certainly a bug in this tool's parser, not your config - `build` prints a
loud (non-fatal) warning exactly for this case when `aws` is on `PATH`.

**A build refuses with a validation error:** the message names the
offending file, line, and rule (`docs/validation.md` has the fix for each).
The existing output file is never touched by a failed build.

## Known limitations

`add-sso`/`add-profile`'s update-in-place merge preserves hand-added
**top-level** keys but not hand-added nested/indented sub-blocks (an
`s3 =` block under a profile). A plain `build` always passes nested blocks
through untouched regardless; this only affects the wizards' merge step.
See [`docs/validation.md`](docs/validation.md) for detail.

`self-update` isn't implemented yet (needs release infrastructure this
repo doesn't have set up). Re-run `install.sh`, or `git pull` +
`./install.sh --local` from a clone, in the meantime.

## Contributing / running the tests

```bash
make dev-setup
bash tests/run-tests.sh
```

Plain bash, no framework, no external dependencies. Every test runs against
a throwaway `HOME`/`XDG_CONFIG_HOME`, never your real `~/.aws`.

`setup-pre-commit.sh` installs `pre-commit` if needed (via `pipx` when
available, otherwise `python3 -m pip --user`) and installs the repo's git
hook so ShellCheck runs before each commit.

`make dev-setup` is a convenience wrapper around that script for onboarding.

## See also

- [AWS CLI config file docs](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html)
- [`docs/spec-file.md`](docs/spec-file.md) - the `apply --spec` format in full
- [`docs/numbering.md`](docs/numbering.md) - the scheme manifest
- [`docs/watcher.md`](docs/watcher.md) - all four watcher layers
- [`docs/validation.md`](docs/validation.md) - every rule and its fix

## License

MIT
