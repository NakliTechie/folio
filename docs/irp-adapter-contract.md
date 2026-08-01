# IRP/GSP adapter activation contract

Folio's default provider remains `Providers::Disabled`. Offline INV-01 preparation is available,
but production network calls require an explicitly selected and reviewed adapter. Credentials and
tokens must remain in the deployment secret store and may never be persisted in submission,
cancellation, domain-event, or log payloads.

## Adapter operations

A concrete adapter implements the normalized provider contract:

- `generate_irn(payload:, request_id:)` → a signature-verified `Acknowledgement`;
- `fetch_by_document(...)` → reconciliation after an ambiguous generation attempt;
- `cancel_irn(irn:, reason_code:, remarks:, request_id:)` → a `CancellationAcknowledgement`;
- `fetch_by_irn(irn:)` → an `IrnStatus` of `active` or `cancelled` after an ambiguous cancellation.

Transport failures are never automatic retries. A generation timeout must reconcile by statutory
document identity; a cancellation timeout must reconcile by IRN. Only a conclusive `active` result
makes the same frozen cancellation request safely retryable.

## Cancellation policy

The IRIS IRP documentation says cancellation reason and remarks are mandatory and only an active IRN
generated in the previous 24 hours can be cancelled. Its general master currently lists reason `1`
(`Duplicate`) and `2` (`Data Entry Mistake`). Folio enforces that narrow set, a 100-character remark,
`documents.reverse` authority, and the 24-hour deadline before an adapter is called.

- Official workflow: <https://einvoice6.gst.gov.in/content/kb/cancelling-e-invoice/>
- Official reason master: <https://einvoice6.gst.gov.in/content/general-master/>
- Official core API list: <https://einvoice6.gst.gov.in/content/kbtopic/core-apis/>

IRP cancellation does not silently rewrite the ledger. Once cancellation is conclusive, Folio makes
an otherwise-unsettled invoice eligible for the ordinary compensating accounting reversal. After the
24-hour window, the service directs the operator to the governed credit-note/return-adjustment path.

## Activation checklist

Before selecting the adapter in production:

1. Approve the GSP/IRP, commercial terms, data-processing terms, sandbox, and production endpoints.
2. Confirm taxpayer authorization, seller GSTIN mapping, credential rotation, clock synchronization,
   TLS verification, response-signature verification, timeouts, and redacted logs.
3. Pass contract tests for acknowledgement validation, duplicate requests, rejection mapping,
   timeout-before/after-send ambiguity, get-by-document, cancellation, get-by-IRN, and key rotation.
4. Run a sandbox generation/cancellation and preserve request/response digests without secrets.
5. Add monitored operator actions for submit, reconcile, cancel, and cancellation reconcile; do not
   expose a blind retry button.
6. Approve the incident runbook for provider outage, indeterminate state, the 24-hour deadline, and
   the separate accounting reversal.

No live adapter, credentials, endpoint, or billable provider resource is configured in this batch.
