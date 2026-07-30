# frozen_string_literal: true

class ReportsController < BrowserController
  before_action -> { require_capability!("reports.read") }

  def show
    @trial_balance = Reports.trial_balance(Current.tenant.id)
    @account_type_totals = Reports.account_type_totals(Current.tenant.id)
    @highlight_codes = highlighted_account_codes
  end

  private

  def highlighted_account_codes
    return [] unless params[:posted_document_id].present?

    Document.where(tenant_id: Current.tenant.id).find_by(id: params[:posted_document_id])
      &.document_lines&.pluck(:account_code) || []
  end
end
