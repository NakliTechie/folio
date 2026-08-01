# frozen_string_literal: true

module Procurement
  # Freezes two-/three-way match evidence on a draft bill. Exceptions are advisory:
  # authorized AP users may post a legitimate invoice while its discrepancy stays visible.
  module MatchBill
    module_function

    def call!(document:, purchase_order:)
      unless document.doc_type == "PB" && document.state == "draft" &&
          document.tenant_id == purchase_order.tenant_id &&
          document.party_id == purchase_order.vendor.id
        raise InvalidProcurement, "bill and purchase order must belong to the same company and vendor"
      end

      document.document_lines.each do |bill_line|
        order_line = purchase_order.purchase_order_lines.find_by(item_id: bill_line.item_id)
        unless order_line
          raise InvalidProcurement,
            "bill item #{bill_line.item_snapshot.fetch('code')} is not present on the purchase order"
        end

        exceptions = exceptions_for(order_line, bill_line, document)
        bill_line.update!(
          purchase_order_line: order_line,
          account_code: order_line.item_type == "good" ? "2050" : bill_line.account_code
        )
        ProcurementMatch.create!(
          tenant_id: document.tenant_id, document: document, document_line: bill_line,
          purchase_order: purchase_order, purchase_order_line: order_line,
          status: exceptions.empty? ? "matched" : "exception",
          billed_quantity: bill_line.quantity,
          ordered_unit_price_minor: order_line.unit_price_minor,
          billed_unit_price_minor: bill_line.unit_price_minor,
          exceptions: exceptions
        )
      end
    end

    def exceptions_for(order_line, bill_line, document)
      prior_billed = order_line.matched_quantity(excluding_document: document)
      after_bill = prior_billed + bill_line.quantity
      exceptions = []
      exceptions << evidence(
        "quantity_over_order", "Billed quantity exceeds the ordered quantity",
        order_line.ordered_quantity, after_bill
      ) if after_bill > order_line.ordered_quantity
      exceptions << evidence(
        "price_variance", "Billed unit price differs from the purchase order",
        order_line.unit_price_minor, bill_line.unit_price_minor
      ) if bill_line.unit_price_minor != order_line.unit_price_minor
      if order_line.item_type == "good" && after_bill > order_line.received_quantity
        raise InvalidProcurement,
          "bill quantity for #{bill_line.item_snapshot.fetch('code')} exceeds accepted goods receipts"
      end
      exceptions
    end

    def evidence(code, message, expected, actual)
      { "code" => code, "message" => message, "expected" => expected.to_s, "actual" => actual.to_s }
    end
  end
end
