# frozen_string_literal: true

module Taxes
  module India
    module StateCodes
      # GST state/UT codes currently used in GSTINs. Retired legacy codes 25 and 28 are excluded.
      CODES = %w[
        01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24
        26 27 29 30 31 32 33 34 35 36 37 38 97
      ].freeze
      NAMES = {
        "01" => "Jammu and Kashmir", "02" => "Himachal Pradesh", "03" => "Punjab",
        "04" => "Chandigarh", "05" => "Uttarakhand", "06" => "Haryana", "07" => "Delhi",
        "08" => "Rajasthan", "09" => "Uttar Pradesh", "10" => "Bihar", "11" => "Sikkim",
        "12" => "Arunachal Pradesh", "13" => "Nagaland", "14" => "Manipur", "15" => "Mizoram",
        "16" => "Tripura", "17" => "Meghalaya", "18" => "Assam", "19" => "West Bengal",
        "20" => "Jharkhand", "21" => "Odisha", "22" => "Chhattisgarh", "23" => "Madhya Pradesh",
        "24" => "Gujarat", "26" => "Dadra and Nagar Haveli and Daman and Diu",
        "27" => "Maharashtra", "29" => "Karnataka", "30" => "Goa", "31" => "Lakshadweep",
        "32" => "Kerala", "33" => "Tamil Nadu", "34" => "Puducherry",
        "35" => "Andaman and Nicobar Islands", "36" => "Telangana", "37" => "Andhra Pradesh",
        "38" => "Ladakh", "97" => "Other Territory"
      }.freeze
      UNION_TERRITORIES_WITHOUT_LEGISLATURE = %w[04 26 31 34 35 38].freeze

      module_function

      def valid?(code) = CODES.include?(code.to_s)

      def name_for(code) = NAMES.fetch(code.to_s)

      def union_territory_without_legislature?(code)
        UNION_TERRITORIES_WITHOUT_LEGISLATURE.include?(code.to_s)
      end
    end
  end
end
