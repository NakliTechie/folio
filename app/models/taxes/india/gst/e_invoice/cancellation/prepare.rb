# frozen_string_literal: true

require "securerandom"

module Taxes
  module India
    module Gst
      module EInvoice
        module Cancellation
          module Prepare
            module_function

            def call(submission:, reason_code:, remarks:, actor:, at: Time.current)
              submission.with_lock do
                validate_request!(submission, reason_code, remarks, actor, at)
                existing = submission.einvoice_cancellation
                return verify_existing!(existing, reason_code, remarks) if existing

                cancellation = EinvoiceCancellation.create!(
                  tenant_id: submission.tenant_id,
                  einvoice_submission: submission,
                  requested_by: actor,
                  provider: submission.provider,
                  status: "prepared",
                  request_id: SecureRandom.uuid,
                  reason_code: reason_code.to_s,
                  remarks: remarks.to_s.strip,
                  requested_at: at
                )
                record_event!(cancellation, "einvoice.cancellation_prepared", actor)
                cancellation
              end
            end

            def validate_request!(submission, reason_code, remarks, actor, at)
              raise NotReady, "only an acknowledged IRN can be cancelled" unless submission.acknowledged?
              if submission.document.state == "reversed"
                raise NotReady, "the accounting document is already reversed"
              end
              deadline = Cancellation.eligible_until(submission)
              if !deadline || at > deadline
                raise NotReady,
                  "the IRP 24-hour cancellation window has closed; use a governed credit note and return adjustment"
              end
              unless REASONS.key?(reason_code.to_s)
                raise NotReady, "choose IRP cancellation reason 1 (duplicate) or 2 (data entry mistake)"
              end
              normalized_remarks = remarks.to_s.strip
              if normalized_remarks.blank? || normalized_remarks.length > MAX_REMARKS_LENGTH
                raise NotReady, "cancellation remarks are required and may be no more than 100 characters"
              end

              validate_actor!(submission, actor)
            end

            def validate_actor!(submission, actor)
              return if actor && Authorization.permits?(
                user: actor, tenant_id: submission.tenant_id,
                office_id: submission.document.office_id, capability: "documents.reverse"
              )

              raise NotReady, "documents.reverse authority is required for IRN cancellation operations"
            end

            def verify_existing!(cancellation, reason_code, remarks)
              unless cancellation.reason_code == reason_code.to_s && cancellation.remarks == remarks.to_s.strip
                raise NotReady, "the existing IRN cancellation request is immutable"
              end
              cancellation
            end

            def record_event!(cancellation, kind, actor)
              DomainEvents::Record.call(
                tenant_id: cancellation.tenant_id,
                kind: kind,
                actor: "u:#{actor.id}",
                actor_user_id: actor.id,
                ref: cancellation.einvoice_submission.document.document_number,
                office_id: cancellation.einvoice_submission.document.office_id,
                payload: {
                  "cancellationId" => cancellation.id,
                  "submissionId" => cancellation.einvoice_submission_id,
                  "requestId" => cancellation.request_id,
                  "reasonCode" => cancellation.reason_code,
                  "remarks" => cancellation.remarks,
                  "status" => cancellation.status,
                  "provider" => cancellation.provider,
                  "attemptCount" => cancellation.attempt_count,
                  "cancelledAt" => cancellation.cancelled_at,
                  "responseSha256" => cancellation.provider_response_sha256,
                  "errorCode" => cancellation.error_code
                }.compact
              )
            end
          end
        end
      end
    end
  end
end
