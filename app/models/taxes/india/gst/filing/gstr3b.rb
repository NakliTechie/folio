# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module Filing
        # GSTN GSTR3B Save v7.1 profile. Outward liability is book-derived; eligible ITC is
        # accepted only through an explicit GSTR-2B-reviewed input object and is capped by the
        # domestic purchase-book reference currently supported by Folio.
        module Gstr3b
          REVIEW_STATUS = "gstr_2b_reconciled"
          COMPONENTS = %i[igst cgst sgst cess].freeze
          GROUPS = %i[available reversal_rule reversal_other ineligible_rule ineligible_other].freeze

          module_function

          def call(tenant_id:, tax_registration_id:, from_date:, to_date:, reviewed_itc:)
            Filing.regular_period!(from_date, to_date)
            registration = TaxRegistration.where(tenant_id: tenant_id, kind: "GSTIN")
              .find(tax_registration_id)
            # Reuse GSTR-1's fail-closed check for non-statutory internal invoice reversals.
            Gstr1.source_documents(
              tenant_id: tenant_id,
              registration_id: registration.id,
              from_date: from_date,
              to_date: to_date
            )
            review = normalize_review!(reviewed_itc)
            preparation = Reports::GstReturns.call(
              tenant_id: tenant_id,
              tax_registration_id: registration.id,
              from_date: from_date,
              to_date: to_date
            )
            outward = preparation.dig(:gstr_3b, :table_3_1_a_outward_taxable)
            book_input = preparation.dig(:gstr_3b, :table_4_a_5_book_input_tax_reference)
            ensure_review_within_book!(review, book_input.fetch(:tax))

            payload = {
              "gstin" => registration.identifier,
              "ret_period" => Filing.return_period(to_date),
              "sup_details" => supply_details(outward),
              "inter_sup" => {
                "unreg_details" => [], "comp_details" => [], "uin_details" => []
              },
              "itc_elg" => itc_details(review),
              "inward_sup" => {
                "isup_details" => [
                  { "ty" => "GST", "inter" => 0, "intra" => 0 },
                  { "ty" => "NONGST", "inter" => 0, "intra" => 0 }
                ]
              },
              "intr_ltfee" => {
                "intr_details" => { "iamt" => 0, "camt" => 0, "samt" => 0, "csamt" => 0 }
              },
              "eco_dtls" => {
                "eco_sup" => { "txval" => 0, "iamt" => 0, "camt" => 0, "samt" => 0, "csamt" => 0 },
                "eco_reg_sup" => { "txval" => 0 }
              }
            }
            crosscheck = {
              status: "matched",
              outward_source: "folio_posted_documents",
              itc_source: REVIEW_STATUS,
              outward_taxable_minor: outward.fetch(:taxable_value_minor),
              outward_tax_minor: outward.fetch(:tax),
              reviewed_itc_minor: net_itc(review),
              purchase_book_reference_minor: book_input.fetch(:tax)
            }
            Filing.result(form: "GSTR3B", payload: payload, crosscheck: crosscheck)
          end

          def normalize_review!(input)
            unless input.is_a?(Hash) && value(input, :status) == REVIEW_STATUS
              raise NotReady,
                "GSTR-3B filing requires an explicit #{REVIEW_STATUS.inspect} ITC review"
            end

            GROUPS.to_h do |group|
              values = value(input, group)
              if group == :available && !values.is_a?(Hash)
                raise NotReady, "reviewed ITC available amounts are required"
              end
              values ||= {}
              [ group, COMPONENTS.to_h do |component|
                key = "#{component}_minor"
                raw = value(values, key)
                raw = 0 if group != :available && raw.nil?
                [ component, Filing.non_negative_minor!(raw, "#{group} #{component}") ]
              end ]
            end
          end

          def ensure_review_within_book!(review, book_tax)
            review.fetch(:available).each do |component, amount|
              reference = if component == :sgst
                book_tax.fetch(:sgst, 0) + book_tax.fetch(:utgst, 0)
              else
                book_tax.fetch(component, 0)
              end
              if amount > [ reference, 0 ].max
                raise NotReady,
                  "reviewed #{component.to_s.upcase} ITC exceeds Folio's purchase-book reference"
              end
            end
          end

          def supply_details(outward)
            tax = outward.fetch(:tax)
            {
              "osup_det" => {
                "txval" => Filing.rupees(outward.fetch(:taxable_value_minor)),
                "iamt" => Filing.rupees(tax.fetch(:igst)),
                "camt" => Filing.rupees(tax.fetch(:cgst)),
                "samt" => Filing.rupees(tax.fetch(:sgst) + tax.fetch(:utgst)),
                "csamt" => Filing.rupees(tax.fetch(:cess))
              },
              "osup_zero" => { "txval" => 0, "iamt" => 0, "csamt" => 0 },
              "osup_nil_exmp" => { "txval" => 0 },
              "isup_rev" => { "txval" => 0, "iamt" => 0, "camt" => 0, "samt" => 0, "csamt" => 0 },
              "osup_nongst" => { "txval" => 0 }
            }
          end

          def itc_details(review)
            available = review.fetch(:available)
            rule = review.fetch(:reversal_rule)
            other = review.fetch(:reversal_other)
            ineligible_rule = review.fetch(:ineligible_rule)
            ineligible_other = review.fetch(:ineligible_other)
            {
              "itc_avl" => [ component_row("OTH", available) ],
              "itc_rev" => [ component_row("RUL", rule), component_row("OTH", other) ],
              "itc_net" => component_row(nil, net_itc(review)),
              "itc_inelg" => [
                component_row("RUL", ineligible_rule),
                component_row("OTH", ineligible_other)
              ]
            }
          end

          def net_itc(review)
            COMPONENTS.to_h do |component|
              value = review.dig(:available, component) -
                review.dig(:reversal_rule, component) - review.dig(:reversal_other, component)
              [ component, value ]
            end
          end

          def component_row(type, amounts)
            row = {
              "iamt" => Filing.rupees(amounts.fetch(:igst)),
              "camt" => Filing.rupees(amounts.fetch(:cgst)),
              "samt" => Filing.rupees(amounts.fetch(:sgst)),
              "csamt" => Filing.rupees(amounts.fetch(:cess))
            }
            row["ty"] = type if type
            row
          end

          def value(hash, key)
            hash[key] || hash[key.to_s]
          end
        end
      end
    end
  end
end
