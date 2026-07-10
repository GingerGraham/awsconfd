# Choosing an authentication path

`awsconfd` supports all common AWS CLI profile styles. This guide helps you
choose the right shape for each profile and avoid mixing concerns.

## At a glance

| Path                                     | Core keys                                                                | Best for                                                   | Notes                                                                                   |
| ---------------------------------------- | ------------------------------------------------------------------------ | ---------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| SSO                                      | `sso_session`, `sso_account_id`, `sso_role_name`                         | Identity Center estates                                    | Pair with one shared `[sso-session ...]` per organisation                               |
| Assume-role via profile                  | `role_arn` + `source_profile`                                            | Cross-account access rooted in another profile             | `source_profile` can be in config.d or `~/.aws/credentials`                             |
| Assume-role via environment/metadata     | `role_arn` + `credential_source`                                         | EC2/ECS/CI runners with ambient credentials                | `credential_source` must be one of `Environment`, `Ec2InstanceMetadata`, `EcsContainer` |
| Static credentials profile               | profile in `~/.aws/credentials` + optional `region`/`output` in config.d | Legacy IAM users                                           | `awsconfd` does not manage credential secrets                                           |
| External provider (`credential_process`) | `credential_process` + optional `region`/`output`                        | aws-vault / brokered credentials / custom identity tooling | Command is not executed by `awsconfd`; AWS CLI executes it at runtime                   |

## Recommendation order

1. Prefer SSO where available.
2. Use assume-role profiles for account-to-account access boundaries.
3. Use `credential_source` for workloads that already have ambient credentials.
4. Use `credential_process` when identity is delegated to external tooling.
5. Keep static credentials as a compatibility path, not the default design.

## `source_profile` vs `credential_source` vs `credential_process`

- Use `source_profile` when another named profile should mint credentials for
  this role chain.
- Use `credential_source` when credentials come from the host/runtime
  environment rather than another named profile.
- Use `credential_process` when credentials are issued by an external command
  that implements AWS CLI's expected JSON contract.

Do not configure both `source_profile` and `credential_source` on the same
profile.

## Diagnostics and ownership boundaries

- `awsconfd` is the source of truth for `~/.aws/config` via `config.d`.
- `~/.aws/credentials` remains user-managed.
- `awsconfd` may read `~/.aws/credentials` for validation/diagnostics but does
  not write, import, or back it up.
- `awsconfd list profiles --with-credentials-file` is a diagnostics view.
  It intentionally does not dedupe names that appear in both sources.

## Worked examples

- SSO and mixed org/profile layouts:
  [examples/single-org.spec.ini](../examples/single-org.spec.ini),
  [examples/multi-customer.spec.ini](../examples/multi-customer.spec.ini)
- Legacy IAM role chain:
  [examples/legacy-iam-assume-role.spec.ini](../examples/legacy-iam-assume-role.spec.ini)
- External `credential_process` profile:
  [examples/credential-process.spec.ini](../examples/credential-process.spec.ini)
