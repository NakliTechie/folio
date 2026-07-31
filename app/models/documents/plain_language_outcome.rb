# frozen_string_literal: true

module Documents
  module PlainLanguageOutcome
    module_function

    def for(document)
      return unless document&.doc_type == "JV"

      debit_line = document.document_lines.find { |line| line.amount_minor&.positive? }
      credit_line = document.document_lines.find { |line| line.amount_minor&.negative? }
      return unless debit_line && credit_line && debit_line.amount_minor == -credit_line.amount_minor

      accounts = Account.where(
        tenant_id: document.tenant_id, code: [ debit_line.account_code, credit_line.account_code ]
      ).index_by(&:code)
      debit = accounts[debit_line.account_code]
      credit = accounts[credit_line.account_code]
      return unless debit && credit

      kind = if %w[1000 1010].include?(debit.code) && credit.code == "3000"
        "owner_deposit"
      elsif debit.account_type == "expense" && %w[1000 1010].include?(credit.code)
        "expense"
      end
      return unless kind

      {
        kind: kind,
        amount_minor: debit_line.amount_minor,
        debit_account: debit,
        credit_account: credit
      }
    end
  end
end
