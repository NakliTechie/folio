# frozen_string_literal: true

module Taxes
  module India
    module Tds
      # Selects the statutory TDS base without consulting persistence. At invoice credit,
      # separately stated GST is excluded. When an advance payment precedes the invoice and
      # GST cannot yet be identified, the gross advance is the base; a later invoice may be
      # used by a future advance-adjustment workflow to reconcile that frozen assessment.
      module Base
        Result = Data.define(:gross_minor, :gst_minor, :taxable_minor, :basis, :trigger_event)

        module_function

        def for_invoice(gross_minor:, gst_minor:, gst_separately_stated:)
          gross = non_negative_integer!(gross_minor, "gross_minor")
          gst = non_negative_integer!(gst_minor, "gst_minor")
          raise InvalidInput, "gst_minor cannot exceed gross_minor" if gst > gross

          if gst_separately_stated
            Result.new(
              gross_minor: gross,
              gst_minor: gst,
              taxable_minor: gross - gst,
              basis: "invoice_excluding_separately_stated_gst",
              trigger_event: "credit"
            )
          else
            Result.new(
              gross_minor: gross,
              gst_minor: 0,
              taxable_minor: gross,
              basis: "invoice_gross_gst_not_separately_stated",
              trigger_event: "credit"
            )
          end
        end

        def for_advance_payment(gross_minor:)
          gross = non_negative_integer!(gross_minor, "gross_minor")
          Result.new(
            gross_minor: gross,
            gst_minor: 0,
            taxable_minor: gross,
            basis: "advance_payment_gross_before_invoice",
            trigger_event: "advance_payment"
          )
        end

        def non_negative_integer!(value, label)
          return value if value.is_a?(Integer) && value >= 0

          raise InvalidInput, "#{label} must be a non-negative integer minor amount"
        end
      end
    end
  end
end
