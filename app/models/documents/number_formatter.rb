# frozen_string_literal: true

module Documents
  module NumberFormatter
    STATUTORY_TYPES = %w[SI CN PB RC PY].freeze
    VALID_STATUTORY_NUMBER = /\A[A-Za-z0-9\/-]{1,16}\z/

    module_function

    def format(document, sequence)
      return legacy_format(document, sequence) unless STATUTORY_TYPES.include?(document.doc_type)

      number = "#{document.doc_type}/#{financial_year_label(document.fiscal_year)}/#{sequence.to_i.to_s.rjust(5, "0")}"
      unless VALID_STATUTORY_NUMBER.match?(number)
        raise Documents::InvalidDocument, "#{document.doc_type} number exceeds the 16-character statutory limit"
      end

      number
    end

    def financial_year_label(start_year)
      year = Integer(start_year)
      "#{year.to_s.last(2)}-#{(year + 1).to_s.last(2)}"
    end

    def legacy_format(document, sequence)
      [ document.document_type&.number_prefix, sequence ].compact.join
    end
  end
end
