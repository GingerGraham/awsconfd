# The numbering scheme manifest

Path: `${XDG_CONFIG_HOME:-$HOME/.config}/awsconfd/scheme.conf`.

This file exists purely so filenames carry meaning that `awsconfd` can check
and explain back to you. It is **not** AWS INI - it's `awsconfd`'s own
format, never read by the AWS CLI, never touched by `build`.

`awsconfd init` seeds it with two conventional entries:

```ini
[awsconfd]
version = 1
strict  = false

[scheme]
00 = defaults
10 = sso-sessions
```

`00` and `10` are a convention, not a requirement - `init` writes them
because `00-defaults.conf` and `10-sso.conf` are what it seeds `config.d`
with. Everything past that is yours to define. A realistic manifest for
someone with a personal AWS org plus a couple of client orgs might look
like:

```ini
[scheme]
00    = defaults
10    = sso-sessions
2x    = personal
30-39 = client-a
40-49 = client-b
55    = one-off-audit-account
```

## Range syntax

| Form | Meaning |
|---|---|
| `NN` | exactly that two-digit prefix |
| `Nx` | the decade `N0`-`N9` |
| `NN-MM` | inclusive range, `NN <= MM` |

Overlapping ranges are a hard validation error (**B9**) naming both
offending entries - `awsconfd doctor` catches this even before you try to
allocate anything.

## Behaviour

- **No `scheme.conf` at all** means "no scheme declared" - every prefix is
  acceptable, no warnings, ever. Passing `--strict` in this state is a
  **usage error** (exit 2): there's nothing to enforce.
- **`strict = false`** (the default): a fragment whose prefix falls outside
  every declared range gets a warning (**W2**) from `doctor` naming the
  situation, and the build proceeds anyway. This is deliberately permissive
  - if you manage twenty client orgs you may need most of `00`-`99` and
  don't want to be blocked while the manifest catches up.
- **`strict = true`** (or `--strict` on the command line): the same
  condition is blocking (**B10**). `build --strict` refuses; `add-profile`
  under `--strict` refuses and prints the next free prefix in the
  appropriate range instead of guessing.

## Allocation

`awsconfd add-profile <name> --label <label>` looks up the range declared
for `<label>`, lists the fragments that already fall inside it, and picks
the lowest unused two-digit prefix. If the range is full, it errors, names
the range, and tells you to widen it in `scheme.conf`. If the label isn't
declared at all, `add-profile --label` refuses with a clear error rather
than guessing where you meant it to go - use `--file` to place it
explicitly instead, or add the label to `scheme.conf` first.

`add-sso <name>` (no `--label` flag - a session belongs to the org-level
`sso-sessions` label implicitly) resolves the fragment the same way: if the
`sso-sessions` range already holds exactly one fragment, it's reused; if
none, `<lo>-sso.conf` is created; if several, you're asked which one.
