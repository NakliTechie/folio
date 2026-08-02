# Folio demo seeds

## Canonical sample books

`sample_books.yml` is the committed catalogue and `sample_books.rb` is the shared loader for
`/demo-nt`, `/walkthrough-nt`, `/guide-nt`, tests, and manual product exploration. Each scenario
uses Folio's real domain services to create and post a fresh, balanced company book.

```sh
bin/rails sample_books:list
bin/rails "sample_books:seed[manufacturing,owner@manufacturing-demo.folio.invalid,choose-a-local-password]"
```

The available scenarios are `consulting`, `manufacturing`, and `pharma`. The loader refuses
production and requires the password at runtime; credentials are never committed. Each run needs
a fresh email address because it deliberately creates a fresh tenant.

## Role-permission seed

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
