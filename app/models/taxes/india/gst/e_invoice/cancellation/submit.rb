# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module EInvoice
        module Cancellation
          module Submit
            module_function

            def call(cancellation:, actor:, provider:, at: Time.current)
              attempted = false
              Prepare.validate_actor!(cancellation.einvoice_submission, actor)
              ensure_provider!(provider)
              return cancellation if cancellation.cancelled?
              return cancellation unless mark_submitting!(cancellation, provider, at: at)

              attempted = true
              acknowledgement = provider.cancel_irn(
                irn: cancellation.einvoice_submission.irn,
                reason_code: cancellation.reason_code,
                remarks: cancellation.remarks,
                request_id: cancellation.request_id
              )
              conclude_cancelled!(cancellation, acknowledgement, actor: actor)
            rescue Provider::Rejection => error
              conclude_failure!(cancellation, status: "rejected", error: error, actor: actor)
              raise
            rescue Provider::TransportError => error
              conclude_failure!(cancellation, status: "indeterminate", error: error, actor: actor)
              raise
            rescue InvalidPayload => error
              wrapped = Provider::TransportError.new(error.message)
              conclude_failure!(cancellation, status: "indeterminate", error: wrapped, actor: actor)
              raise
            rescue StandardError => error
              if attempted
                wrapped = Provider::TransportError.new(
                  "IRP cancellation adapter failed without a conclusive response: #{error.class}"
                )
                conclude_failure!(cancellation, status: "indeterminate", error: wrapped, actor: actor)
              end
              raise
            end

            def mark_submitting!(cancellation, provider, at:)
              cancellation.with_lock do
                next false if cancellation.cancelled?
                if cancellation.unresolved?
                  raise Provider::Error,
                    "the prior cancellation attempt is unresolved; reconcile by IRN before retrying"
                end
                unless cancellation.status == "prepared"
                  raise Provider::Error, "a rejected IRN cancellation cannot be retried unchanged"
                end
                deadline = Cancellation.eligible_until(cancellation.einvoice_submission)
                if !deadline || at > deadline
                  raise NotReady,
                    "the IRP 24-hour cancellation window has closed; use a governed credit note and return adjustment"
                end

                cancellation.update!(
                  provider: provider.name,
                  status: "submitting",
                  attempt_count: cancellation.attempt_count + 1,
                  last_attempt_at: at,
                  error_code: nil,
                  error_message: nil
                )
                true
              end
            end

            def conclude_cancelled!(cancellation, acknowledgement, actor:)
              result = Provider.validate_cancellation_acknowledgement!(acknowledgement)
              unless result.irn.casecmp?(cancellation.einvoice_submission.irn)
                raise InvalidPayload, "IRP cancellation acknowledgement names a different IRN"
              end

              cancellation.with_lock do
                cancellation.update!(
                  status: "cancelled",
                  cancelled_at: result.cancelled_at,
                  provider_response: result.raw_response,
                  provider_response_sha256: EInvoice.canonical_digest(result.raw_response),
                  error_code: nil,
                  error_message: nil
                )
                Prepare.record_event!(cancellation, "einvoice.cancelled", actor)
              end
              cancellation
            end

            def conclude_failure!(cancellation, status:, error:, actor:)
              return unless cancellation&.persisted?

              cancellation.with_lock do
                return if cancellation.cancelled?

                response = Provider.safe_error_response(error)
                cancellation.update!(
                  status: status,
                  error_code: Provider.safe_error_code(error),
                  error_message: Provider.safe_error_message(error),
                  provider_response: response,
                  provider_response_sha256: response ? EInvoice.canonical_digest(response) : nil
                )
                Prepare.record_event!(cancellation, "einvoice.cancellation_#{status}", actor)
              end
            end

            def ensure_provider!(provider)
              unless provider.respond_to?(:configured?) && provider.respond_to?(:cancel_irn) &&
                     provider.respond_to?(:fetch_by_irn) && provider.respond_to?(:name) && provider.configured?
                raise Provider::ConfigurationError,
                  "live IRP cancellation is disabled; choose and configure a reviewed GSP/IRP adapter"
              end
            end
          end
        end
      end
    end
  end
end
