# frozen_string_literal: true

require "securerandom"

module Taxes
  module India
    module Gst
      module EInvoice
        # Freezes one idempotent INV-01 request per posted sales document. Repeated calls return
        # the same envelope and never append duplicate lifecycle events.
        module Prepare
          module_function

          def call(document:, actor:, actor_user_id: nil)
            document.with_lock do
              payload = EInvoice.build(document)
              digest = EInvoice.canonical_digest(payload)
              existing = EinvoiceSubmission.find_by(
                tenant_id: document.tenant_id, document_id: document.id
              )
              return verify_existing!(existing, digest) if existing

              submission = EinvoiceSubmission.create!(
                tenant_id: document.tenant_id,
                document: document,
                tax_registration_id: document.tax_registration_id,
                provider: "offline_export",
                schema_version: SCHEMA_VERSION,
                request_id: SecureRandom.uuid,
                payload: payload,
                payload_sha256: digest
              )
              record_event!(submission, actor: actor, actor_user_id: actor_user_id)
              submission
            end
          end

          def verify_existing!(submission, digest)
            unless submission.schema_version == SCHEMA_VERSION && submission.payload_sha256 == digest
              raise InvalidPayload,
                "the stored e-invoice request does not match the posted document; do not submit it"
            end
            submission
          end

          def record_event!(submission, actor:, actor_user_id:)
            DomainEvents::Record.call(
              tenant_id: submission.tenant_id,
              kind: "einvoice.prepared",
              actor: actor,
              actor_user_id: actor_user_id,
              ref: submission.document.document_number,
              office_id: submission.document.office_id,
              payload: {
                "submissionId" => submission.id,
                "documentId" => submission.document_id,
                "documentNumber" => submission.document.document_number,
                "schemaVersion" => submission.schema_version,
                "payloadSha256" => submission.payload_sha256,
                "requestId" => submission.request_id,
                "mode" => "offline_export"
              }
            )
          end
        end
      end
    end
  end
end
