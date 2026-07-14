# awsconfd Modern Layout Decisions (2026-07)

This note records the post-review decisions that supersede the two-digit
layout assumptions in the earlier design documents in this directory.

It is intentionally short and operational: the point is to capture the final
override and compatibility rules that shaped the implemented behavior.

## Layout model

1. New managed output uses a three-digit layout by default.
2. `000-defaults.conf` is the managed default-profile fragment.
3. `010-sso.conf` is the managed org-level `sso-session` fragment.
4. `990-999` is reserved for imported or migrated material, with
   `990-imported.conf` as the conventional first import target.
5. Existing two-digit trees remain readable during migration.

## Scheme semantics

1. New three-digit ranges use explicit forms such as `200` and `200-209`.
2. Existing two-digit forms such as `2x` and `30-39` are still read for
   compatibility and migration.
3. New shorthand reinterpretations were rejected; three-digit ranges stay
   explicit.

## Session-owned profile ranges

1. Each new `sso-session` owns its own ten-prefix profile range.
2. Allocation starts at `200-209` and advances upward in blocks of ten.
3. Example: adding session `personal` yields `200-209 = personal`, then
   adding `customer-a` yields `210-219 = customer-a`.
4. `add-profile --type sso` auto-places by `sso_session` instead of asking
   for a prefix.

## Override policy

1. Explicit `--file` overrides remain supported.
2. For SSO-backed profiles, an override outside the declared session range:
   - warns in non-strict mode
   - fails in strict mode
3. Non-SSO profiles may still be placed explicitly or by label.

## Ambiguity policy

1. Ambiguous shorthand fragment references are rejected.
2. Example: if both `20-a.conf` and `200-b.conf` exist, `disable 20` must
   fail and print candidates rather than guessing.

## Spec modernization policy

1. Legacy explicit two-digit layout entries are preserved only when applying
   into an unmigrated tree.
2. In a modern three-digit-managed tree, those explicit legacy layout names
   are rejected by default.
3. `apply --force-modern-layout` is the explicit modernization path: ignore
   the legacy explicit filenames and re-place sections according to the
   modern scheme.
4. SSO-backed profiles modernized this way are placed by their session-owned
   range.

## Migration policy

1. `migrate` is the one-shot conversion path for managed legacy trees.
2. It renames managed fragments, rewrites `scheme.conf`, preserves backups,
   and rebuilds.
3. It does not attempt to rename arbitrary unmanaged oddities.
4. Unmanaged odd fragments are left in place and remain subject to normal
   validation and operator review.

## Operational consequence

The current model is:

- backward-compatible for reading legacy trees
- opinionated for new managed output
- explicit about when modernization is automatic and when it must be opted in

That is the intended steady state for the current phase.
