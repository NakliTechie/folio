# frozen_string_literal: true

module Taxes
  module India
    # Offline PAN (Permanent Account Number) structure validation, the sibling of Gstin.
    # This proves format consistency; it does NOT claim the Income Tax Department has issued
    # the number or that it is linked/active. PAN availability is load-bearing for TDS: a
    # deductee without a valid PAN is deducted at the higher §206AA rate.
    #
    # Structure: AAAAA9999A — five letters, four digits, one letter (ten chars).
    #   * char 4 encodes the holder type (the "status" character);
    #   * char 5 is the first letter of the holder's surname/entity name.
    module Pan
      FORMAT = /\A[A-Z]{5}[0-9]{4}[A-Z]\z/

      # The 4th character → holder type. Only the categories TDS routing cares about are
      # named; the rest fall through to :other. P = individual, H = HUF, and the entity
      # forms (company, firm, etc.) all deduct as the non-individual/HUF category for the
      # sections that split on it (e.g. 194C: 1% individual/HUF, 2% otherwise).
      HOLDER_TYPES = {
        "P" => :individual,
        "H" => :huf,
        "C" => :company,
        "F" => :firm,
        "A" => :association_of_persons,
        "T" => :trust,
        "B" => :body_of_individuals,
        "L" => :local_authority,
        "J" => :artificial_juridical_person,
        "G" => :government
      }.freeze

      module_function

      def normalize(value) = value.to_s.strip.upcase

      def valid?(value)
        normalize(value).match?(FORMAT)
      end

      def holder_type(value)
        return nil unless valid?(value)

        HOLDER_TYPES.fetch(normalize(value)[3], :other)
      end

      # The two-way split most TDS sections use for their rate: individual/HUF vs everything
      # else. Derived from a valid PAN's status character; nil when the PAN is unusable.
      def deductee_category(value)
        case holder_type(value)
        when :individual, :huf then :individual_huf
        when nil then nil
        else :other
        end
      end
    end
  end
end
