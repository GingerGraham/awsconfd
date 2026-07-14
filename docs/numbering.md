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
000 = defaults
010 = sso-sessions
990-999 = imported
```

`000` and `010` are a convention, not a requirement - `init` writes them
because `000-defaults.conf` and `010-sso.conf` are the managed defaults, and
`990-999` is reserved for imported or migrated material. Everything past that
is yours to define. A realistic manifest for
someone with a personal AWS org plus a couple of client orgs might look
like:

```ini
[scheme]
000     = defaults
010     = sso-sessions
200-209 = personal
210-219 = client-a
220-229 = client-b
350     = one-off-audit-account
990-999 = imported
```

## Range syntax

| Form      | Meaning                                 |
| --------- | --------------------------------------- |
| `NN`      | exactly that two-digit legacy prefix    |
| `Nx`      | the legacy decade `N0`-`N9`             |
| `NN-MM`   | inclusive legacy range, `NN <= MM`      |
| `NNN`     | exactly that three-digit prefix         |
| `NNN-MMM` | inclusive three-digit range, `NNN<=MMM` |

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
- `add-sso` now allocates a three-digit 10-prefix profile range for each new
  session label, starting at `200-209` and moving upward in blocks of ten.
- SSO-backed `add-profile` no longer prompts for a prefix by default; it places
  the profile into the range owned by its `sso_session`.
- `add-profile` still helps keep the manifest in sync for explicit overrides:
  when it writes a profile to a numeric prefix not currently covered by any
  declared range, and `scheme.conf` exists, it adds an exact mapping inferred
  from the target fragment name.
- **`strict = true`** (or `--strict` on the command line): the same
  condition is blocking (**B10**). `build --strict` refuses; `add-profile`
  under `--strict` refuses and prints the next free prefix in the
  appropriate range instead of guessing.

## Allocation

`awsconfd add-profile <name> --label <label>` looks up the range declared
for `<label>`, lists the fragments that already fall inside it, and picks
the lowest unused prefix in that range. If the range is full, it errors,
names the range, and tells you to widen it in `scheme.conf`. If the label
isn't declared at all, `add-profile --label` refuses with a clear error
rather than guessing where you meant it to go - use `--file` to place it
explicitly instead, or add the label to `scheme.conf` first.

`add-sso <name>` still writes the session block into the fragment owned by the
`sso-sessions` label, but it also ensures that the session name itself owns a
profile range such as `200-209 = personal`. Ambiguous shorthand operations such
as `enable 20` are rejected when they could match both legacy and modern names.
