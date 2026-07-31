# frozen_string_literal: true

module Taxes
  module India
    module StateCodes
      # GST state/UT codes currently used in GSTINs. Retired legacy codes 25 and 28 are excluded.
      CODES = %w[
        01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24
        26 27 29 30 31 32 33 34 35 36 37 38 97
      ].freeze
      UNION_TERRITORIES_WITHOUT_LEGISLATURE = %w[04 26 31 34 35 38].freeze

      module_function

      def valid?(code) = CODES.include?(code.to_s)

      def union_territory_without_legislature?(code)
        UNION_TERRITORIES_WITHOUT_LEGISLATURE.include?(code.to_s)
      end
    end
  end
end
