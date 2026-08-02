# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module EInvoice
        # Provider-independent state machine. It never auto-retries an ambiguous request: an
        # indeterminate/submitting row must be reconciled by statutory document identity first.
        module Submit
          module_function

          def call(submission:, actor:, provider:, actor_user_id: nil)
            attempted = false
            ensure_provider!(provider)
            return submission if submission.acknowledged?

            return submission unless mark_submitting!(submission, provider)
            attempted = true
            acknowledgement = provider.generate_irn(
              payload: submission.payload.deep_dup,
              request_id: submission.request_id
            )
            acknowledge!(
              submission, acknowledgement,
              actor: actor, actor_user_id: actor_user_id
            )
          rescue Provider::Rejection => e
            conclude_failure!(
              submission, status: "rejected", error: e,
              actor: actor, actor_user_id: actor_user_id
            )
            raise
          rescue Provider::TransportError => e
            conclude_failure!(
              submission, status: "indeterminate", error: e,
              actor: actor, actor_user_id: actor_user_id
            )
            raise
          rescue InvalidPayload => e
            error = Provider::TransportError.new(e.message)
            conclude_failure!(
              submission, status: "indeterminate", error: error,
              actor: actor, actor_user_id: actor_user_id
            )
            raise
          rescue StandardError => e
            if attempted
              error = Provider::TransportError.new(
                "IRP adapter failed without a conclusive response: #{e.class}"
              )
              conclude_failure!(
                submission, status: "indeterminate", error: error,
                actor: actor, actor_user_id: actor_user_id
              )
            end
            raise
          end

          def mark_submitting!(submission, provider)
            submission.with_lock do
              next false if submission.acknowledged?
              if submission.unresolved?
                raise Provider::Error,
                  "the prior IRP attempt is unresolved; reconcile by document identity before retrying"
              end
              unless submission.status == "prepared"
                raise Provider::Error, "a rejected e-invoice request cannot be retried unchanged"
              end

              submission.update!(
                provider: provider.name,
                status: "submitting",
                attempt_count: submission.attempt_count + 1,
                last_attempt_at: Time.current,
                error_code: nil,
                error_message: nil
              )
              true
            end
          end

          def acknowledge!(submission, acknowledgement, actor:, actor_user_id:)
            ack = Provider.validate_acknowledgement!(acknowledgement)
            Provider.bind_acknowledgement!(ack, submission.payload)
            response_digest = EInvoice.canonical_digest(ack.raw_response)
            EinvoiceSubmission.transaction do
              submission.with_lock do
                submission.update!(
                  status: "acknowledged",
                  irn: ack.irn.downcase,
                  ack_number: ack.ack_number.to_s,
                  acknowledged_at: ack.acknowledged_at,
                  signed_invoice: ack.signed_invoice,
                  signed_qr_code: ack.signed_qr_code,
                  signature_status: ack.signature_status,
                  provider_response: ack.raw_response,
                  provider_response_sha256: response_digest,
                  error_code: nil,
                  error_message: nil
                )
                record_conclusion!(submission, "einvoice.acknowledged", actor, actor_user_id)
              end
              if (eway_bill = submission.document.eway_bill_submission)
                Taxes::India::Gst::EwayBill::Acknowledge.call(
                  submission: eway_bill,
                  evidence: ack.eway_bill,
                  provider: submission.provider,
                  raw_response: ack.raw_response,
                  actor: actor,
                  actor_user_id: actor_user_id
                )
              end
            end
            submission
          rescue ActiveRecord::RecordNotUnique
            raise InvalidPayload, "the IRP returned an IRN already stored for this tenant"
          end

          def conclude_failure!(submission, status:, error:, actor:, actor_user_id:)
            return unless submission&.persisted?

            submission.with_lock do
              return if submission.acknowledged?

              response = Provider.safe_error_response(error)
              submission.update!(
                status: status,
                error_code: Provider.safe_error_code(error),
                error_message: Provider.safe_error_message(error),
                provider_response: response,
                provider_response_sha256: response ? EInvoice.canonical_digest(response) : nil
              )
              record_conclusion!(submission, "einvoice.#{status}", actor, actor_user_id)
            end
          end

          def record_conclusion!(submission, kind, actor, actor_user_id)
            DomainEvents::Record.call(
              tenant_id: submission.tenant_id,
              kind: kind,
              actor: actor,
              actor_user_id: actor_user_id,
              ref: submission.document.document_number,
              office_id: submission.document.office_id,
              payload: {
                "submissionId" => submission.id,
                "documentId" => submission.document_id,
                "provider" => submission.provider,
                "status" => submission.status,
                "attemptCount" => submission.attempt_count,
                "irn" => submission.irn,
                "ackNumber" => submission.ack_number,
                "responseSha256" => submission.provider_response_sha256,
                "signatureStatus" => submission.signature_status,
                "errorCode" => submission.error_code
              }.compact
            )
          end

          def ensure_provider!(provider)
            unless provider.respond_to?(:configured?) && provider.respond_to?(:generate_irn) &&
                   provider.respond_to?(:name) && provider.configured?
              raise Provider::ConfigurationError,
                "live IRP submission is disabled; choose and configure a reviewed GSP/IRP adapter"
            end
          end
        end
      end
    end
  end
end
