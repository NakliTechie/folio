# frozen_string_literal: true

module Taxes
  module India
    module Gst
      module Filing
        # GSTN CMP Save v1.2 profile. Folio does not yet have a composition bill-of-supply
        # document, so turnover must be explicitly reviewed and supplied by the caller. The
        # tax formula mirrors Bahi's independent CMP-08 oracle: reviewed turnover × scheme rate.
        module Cmp08
          RATES = {
            "trader" => 100,
            "manufacturer" => 100,
            "restaurant" => 500,
            "service" => 600
          }.freeze

          module_function

          def call(gstin:, from_date:, to_date:, composition_type:,
                   reviewed_turnover_minor:, composition_rate_basis_points:)
            Filing.composition_quarter!(from_date, to_date)
            type = composition_type.to_s
            expected_rate = RATES[type]
            raise NotReady, "choose a supported composition type" unless expected_rate

            rate = Integer(composition_rate_basis_points)
            unless rate == expected_rate
              raise NotReady,
                "#{type} CMP-08 rate must be #{expected_rate / 100.0}% in this statutory profile"
            end
            turnover = Filing.non_negative_minor!(reviewed_turnover_minor, "reviewed turnover")
            payload = {
              "gstin" => gstin,
              "ret_period" => Filing.return_period(to_date),
              "isnil" => turnover.zero? ? "Y" : "N"
            }
            tax_minor = Taxes::India::Adapter.tax_amount(turnover, rate)
            unless turnover.zero?
              central = tax_minor / 2
              state = tax_minor - central
              zero_outward = { "tax_val" => 0, "camt" => 0, "samt" => 0 }
              outward_key = type == "service" ? "out_ser" : "out_sup"
              outward = {
                "tax_val" => Filing.rupees(turnover),
                "camt" => Filing.rupees(central),
                "samt" => Filing.rupees(state)
              }
              payload["table3"] = {
                "out_sup" => outward_key == "out_sup" ? outward : zero_outward,
                "out_ser" => outward_key == "out_ser" ? outward : zero_outward,
                "out_ecom" => zero_outward,
                "tax_pay" => {
                  "tax_val" => Filing.rupees(turnover),
                  "iamt" => 0,
                  "camt" => Filing.rupees(central),
                  "samt" => Filing.rupees(state),
                  "csamt" => 0
                },
                "in_sup" => { "tax_val" => 0, "iamt" => 0, "camt" => 0, "samt" => 0, "csamt" => 0 },
                "intr_pay" => { "iamt" => 0, "camt" => 0, "samt" => 0, "csamt" => 0 }
              }
            end

            crosscheck = {
              status: "matched",
              source: "reviewed_composition_turnover",
              independent_oracle: "bahi_cmp08_turnover_x_rate",
              composition_type: type,
              turnover_minor: turnover,
              rate_basis_points: rate,
              tax_payable_minor: tax_minor
            }
            Filing.result(form: "CMP08", payload: payload, crosscheck: crosscheck)
          rescue ArgumentError, TypeError => e
            raise e if e.is_a?(NotReady)

            raise NotReady, "composition rate must be an integer basis-point value"
          end
        end
      end
    end
  end
end
