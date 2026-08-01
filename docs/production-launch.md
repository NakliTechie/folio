# Production launch runbook

## Supported topology

Run the Folio image and its `bin/jobs` worker on an always-on container host with three distinct
PostgreSQL databases: `primary`, `queue`, and `cache`. Put a Cloudflare Tunnel in front of the web
port so the origin needs no public inbound socket. Cloudflare Workers Containers are not the launch
default: the worker and mail queue need an ordinary persistent process lifecycle, and enabling a
paid Workers plan is an operator decision.

The cache database is shared security state: Rails rate-limit counters for signup, verification,
invite acceptance, and password recovery must be consistent across every web process. Do not replace
Solid Cache with an in-process cache in a multi-process deployment.

## Required secrets and configuration

Provide one signing strategy (`RAILS_MASTER_KEY` or a 64+ character `SECRET_KEY_BASE`), a real host
and verified SMTP sender, and either:

- `DATABASE_URL`, `QUEUE_DATABASE_URL`, and `CACHE_DATABASE_URL`, each naming a different database; or
- `FOLIO_DATABASE_PASSWORD` for the three conventionally named databases in `config/database.yml`.

Also set `FOLIO_APP_HOST`, `FOLIO_MAIL_FROM`, `FOLIO_SMTP_ADDRESS`, `FOLIO_SMTP_USERNAME`, and
`FOLIO_SMTP_PASSWORD`. Optional host, port, authentication, and timeout settings are documented in
the README. Never place values in the image, repository, Tunnel YAML, or process logs.

## Deploy order

1. Build the image once and promote that digest; CI must run a container build.
2. Take a provider snapshot or run `bin/backup` to an encrypted, access-controlled volume.
3. Start one web task. Its entrypoint runs `db:prepare` for all three databases.
4. Run `bin/production-check` in that exact release image.
5. Start at least one separate worker with `bin/jobs` (or set `SOLID_QUEUE_IN_PUMA=1` only for a
   single-server installation).
6. Route the Tunnel to port 3000. Use `/up` for process liveness and `/ready` for database readiness.
7. Exercise signup, verification confirmation, invitation acceptance, password reset, a safe draft,
   and a worker restart. Confirm the reverse proxy redacts token query values.

Rollback means routing back to the previous immutable image. Do not roll database structure back
unless a tested migration-specific procedure says it is safe; forward-fix additive migrations.

## Backup and recovery policy

Use provider point-in-time recovery for the primary database where available. In addition, run
`FOLIO_BACKUP_DIR=/encrypted/folio RAILS_ENV=production bin/backup`; it creates permission-restricted
custom-format dumps plus a SHA-256 manifest. `bin/verify-backup PATH` checks every digest and asks
`pg_restore` to parse each archive without writing to a database.

Keep at least 7 daily, 5 weekly, and 12 monthly primary backups, subject to the business's retention
policy. Queue/cache archives aid incident diagnosis but primary is authoritative. Perform a real
restore into three isolated, disposable databases quarterly and before a migration-heavy release;
then run `bin/production-check`, the full test suite, event-chain verification, and a representative
trial balance. Record the restore duration and the latest recoverable timestamp. Backup existence is
not a recovery proof.

## Monitoring and alerting

Collect the JSON application logs by request ID and alert on sustained 5xx responses, `/ready`
failures, failed Solid Queue jobs, verification/mail delivery failures, database capacity, backup
age, and certificate/Tunnel health. Keep query strings out of access logs. A worker heartbeat and a
synthetic email round trip should be external monitors; the web readiness endpoint deliberately does
not declare the worker healthy.

## External activation gates

Do not activate live IRP/GSP calls until the provider contract, sandbox credentials, production
credentials, sender GSTIN authorization, and cancellation/reconciliation runbook are approved. Do
not create a paid Cloudflare resource without explicit operator confirmation.
