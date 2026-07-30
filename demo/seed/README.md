# Folio demo role seed

`roles.rb` creates one idempotent demo tenant and one verified user for each RBAC
preset. Supply the password at runtime so demo credentials are never committed:

```sh
FOLIO_DEMO_PASSWORD='choose-a-local-password' bin/rails runner demo/seed/roles.rb
```

The generated users are:

| Role | Email |
| --- | --- |
| Owner | `demo-owner@folio.invalid` |
| Accountant | `demo-accountant@folio.invalid` |
| Operator | `demo-operator@folio.invalid` |
| CA/Auditor | `demo-ca-auditor@folio.invalid` |
| Viewer | `demo-viewer@folio.invalid` |

The seed is intended for local walkthroughs and non-production demo
environments. It resets these five users' passwords to the supplied runtime
value on every run.
