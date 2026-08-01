# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module EInvoice
        # Resolves an ambiguous submission using the IRP's get-by-document operation. This is
        # intentionally separate from Submit so callers cannot turn a timeout into a blind retry.
        module Reconcile
          module_function

          def call(submission:, actor:, provider:, actor_user_id: nil)
            Submit.ensure_provider!(provider)
            unless submission.unresolved?
              raise Provider::Error, "only an unresolved IRP attempt can be reconciled"
            end

            doc = submission.payload.fetch("DocDtls")
            acknowledgement = provider.fetch_by_document(
              seller_gstin: submission.payload.dig("SellerDtls", "Gstin"),
              document_type: doc.fetch("Typ"),
              document_number: doc.fetch("No"),
              document_date: doc.fetch("Dt")
            )
            unless acknowledgement
              raise Provider::TransportError,
                "the IRP has not returned a conclusive result for this document"
            end

            Submit.acknowledge!(
              submission, acknowledgement,
              actor: actor, actor_user_id: actor_user_id
            )
          end
        end
      end
    end
  end
end
