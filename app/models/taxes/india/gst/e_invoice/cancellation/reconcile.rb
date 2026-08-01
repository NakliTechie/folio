# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module EInvoice
        module Cancellation
          module Reconcile
            module_function

            def call(cancellation:, actor:, provider:)
              Prepare.validate_actor!(cancellation.einvoice_submission, actor)
              Submit.ensure_provider!(provider)
              unless cancellation.unresolved?
                raise Provider::Error, "only an unresolved IRP cancellation can be reconciled"
              end

              result = provider.fetch_by_irn(irn: cancellation.einvoice_submission.irn)
              unless result
                raise Provider::TransportError,
                  "the IRP has not returned a conclusive cancellation status for this IRN"
              end
              status = Provider.validate_irn_status!(result)
              unless status.irn.casecmp?(cancellation.einvoice_submission.irn)
                raise InvalidPayload, "IRP reconciliation names a different IRN"
              end

              if status.status == "cancelled"
                acknowledgement = Provider::CancellationAcknowledgement.new(
                  irn: status.irn,
                  cancelled_at: status.cancelled_at,
                  raw_response: status.raw_response
                )
                return Submit.conclude_cancelled!(cancellation, acknowledgement, actor: actor)
              end

              cancellation.with_lock do
                cancellation.update!(
                  status: "prepared",
                  provider_response: status.raw_response,
                  provider_response_sha256: EInvoice.canonical_digest(status.raw_response),
                  error_code: nil,
                  error_message: nil
                )
                Prepare.record_event!(cancellation, "einvoice.cancellation_reconciled_active", actor)
              end
              cancellation
            end
          end
        end
      end
    end
  end
end
