# frozen_string_literal: true

require "securerandom"

module Taxes
  module India
    module Gst
      module EwayBill
        # Freezes one idempotent EwbDtls object before INV-01 itself is frozen.
        module Prepare
          module_function

          def call(document:, attributes:, actor:, actor_user_id:)
            document.with_lock do
              payload = EwayBill.build(document, attributes)
              digest = EwayBill.canonical_digest(payload)
              existing = document.eway_bill_submission
              return verify_existing!(existing, digest) if existing
              if document.einvoice_submission
                raise NotReady, "the INV-01 request is already frozen; e-way transport details must be prepared first"
              end

              submission = EwayBillSubmission.create!(
                tenant_id: document.tenant_id,
                document: document,
                requested_by_id: actor_user_id,
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
              raise InvalidPayload, "the stored e-way bill request is immutable and uses different transport details"
            end
            submission
          end

          def record_event!(submission, actor:, actor_user_id:)
            DomainEvents::Record.call(
              tenant_id: submission.tenant_id,
              kind: "eway_bill.prepared",
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
                "mode" => "irn_combined"
              }
            )
          end
        end
      end
    end
  end
end
