# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module EInvoice
        module Providers
          # Default production-safe provider: preparation/export works, but no request can
          # accidentally leave Folio before a reviewed adapter and credentials are configured.
          class Disabled
            include Provider::Contract

            def name = "unconfigured"
            def configured? = false

            def generate_irn(payload:, request_id:)
              raise Provider::ConfigurationError,
                "live IRP submission is disabled; choose and configure a reviewed GSP/IRP adapter"
            end

            def fetch_by_document(seller_gstin:, document_type:, document_number:, document_date:)
              raise Provider::ConfigurationError,
                "IRP reconciliation is disabled until a reviewed provider is configured"
            end
          end
        end
      end
    end
  end
end
