# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module EwayBill
        # Concludes the EWB side of a combined IRP acknowledgement without copying credentials or
        # signed invoice artifacts into domain events.
        module Acknowledge
          module_function

          def call(submission:, evidence:, provider:, raw_response:, actor:, actor_user_id:)
            response_digest = EwayBill.canonical_digest(raw_response)
            submission.with_lock do
              return submission if submission.generated?

              submission.update!(
                provider: provider,
                status: "generated",
                eway_bill_number: evidence.eway_bill_number.to_s,
                generated_at: evidence.generated_at,
                valid_until: evidence.valid_until,
                provider_response: raw_response,
                provider_response_sha256: response_digest
              )
              DomainEvents::Record.call(
                tenant_id: submission.tenant_id,
                kind: "eway_bill.generated",
                actor: actor,
                actor_user_id: actor_user_id,
                ref: submission.document.document_number,
                office_id: submission.document.office_id,
                payload: {
                  "submissionId" => submission.id,
                  "documentId" => submission.document_id,
                  "provider" => submission.provider,
                  "ewayBillNumber" => submission.eway_bill_number,
                  "generatedAt" => submission.generated_at.iso8601,
                  "validUntil" => submission.valid_until.iso8601,
                  "responseSha256" => submission.provider_response_sha256
                }
              )
            end
            submission
          rescue ActiveRecord::RecordNotUnique
            raise InvalidPayload, "the IRP returned an e-way bill number already stored for this company"
          end
        end
      end
    end
  end
end
