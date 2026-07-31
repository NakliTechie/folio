# frozen_string_literal: true

class NarrowSupplierDebitReason < ActiveRecord::Migration[8.1]
  CREDIT_REASONS = %w[value_reduction service_deficiency return other].freeze
  OLD_DEBIT_REASONS = %w[price_increase additional_charge underbilling other].freeze
  NEW_DEBIT_REASON = "quantity_underbilling"

  def up
    remove_check_constraint :documents, name: "chk_documents_adjustment_reason"
    execute <<~SQL
      UPDATE documents
      SET reason_code = #{connection.quote(NEW_DEBIT_REASON)}
      WHERE doc_type = 'PD'
        AND reason_code IN (#{OLD_DEBIT_REASONS.map { |reason| connection.quote(reason) }.join(', ')})
    SQL
    add_reason_constraint(CREDIT_REASONS + [ NEW_DEBIT_REASON ])
  end

  def down
    remove_check_constraint :documents, name: "chk_documents_adjustment_reason"
    execute <<~SQL
      UPDATE documents
      SET reason_code = 'underbilling'
      WHERE doc_type = 'PD' AND reason_code = #{connection.quote(NEW_DEBIT_REASON)}
    SQL
    add_reason_constraint(CREDIT_REASONS + OLD_DEBIT_REASONS)
  end

  private

  def add_reason_constraint(reasons)
    add_check_constraint :documents,
      "reason_code IS NULL OR reason_code IN (#{reasons.uniq.map { |reason| connection.quote(reason) }.join(', ')})",
      name: "chk_documents_adjustment_reason"
  end
end
