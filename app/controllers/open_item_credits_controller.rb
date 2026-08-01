# frozen_string_literal: true

class OpenItemCreditsController < BrowserController
  before_action -> { require_capability!("payments.create") }

  def net
    role = credit_input.fetch(:role)
    amount = Settlements::BuildDraft.money_minor!(credit_input.fetch(:amount), "net amount")
    result = OpenItemCredits::Net.call(
      tenant: Current.tenant,
      credit_entry_line_id: credit_input.fetch(:credit_entry_line_id),
      target_entry_line_id: credit_input.fetch(:target_entry_line_id),
      amount_minor: amount,
      applied_on: parsed_date(:applied_on),
      actor: "u:#{Current.user.id}", actor_user: Current.user
    )
    redirect_to report_path_for(role),
      notice: "#{money_amount_for_notice(result.amount_minor)} credit applied to the selected open item."
  rescue OpenItemCredits::InvalidCreditAction, Settlements::InvalidSettlement,
         Date::Error, KeyError => e
    redirect_to report_path_for(params.dig(:open_item_credit, :role)), alert: e.message
  end

  def refund
    role = credit_input.fetch(:role)
    amount = Settlements::BuildDraft.money_minor!(credit_input.fetch(:amount), "refund amount")
    document = OpenItemCredits::BuildRefund.call(
      tenant: Current.tenant,
      credit_entry_line_id: credit_input.fetch(:credit_entry_line_id),
      amount_minor: amount,
      bank_account_code: credit_input.fetch(:bank_account_code),
      document_date: parsed_date(:document_date),
      narration: credit_input[:narration]
    )
    Documents::Post.call(
      document, actor: "u:#{Current.user.id}", authorize: { user: Current.user },
      required_capability: "payments.create"
    )
    redirect_to settlement_path(document, tenant_route_options),
      notice: "#{document.reload.document_number} posted and the open credit was refunded."
  rescue OpenItemCredits::InvalidCreditAction, Settlements::InvalidSettlement,
         Documents::InvalidDocument, Documents::Post::NotPermitted,
         Posting::UnbalancedError, Posting::PeriodClosedError,
         Posting::PeriodRestrictedError, Date::Error, KeyError => e
    redirect_to report_path_for(params.dig(:open_item_credit, :role)), alert: e.message
  end

  private

  # Values are read one by one and passed to typed services; no parameter hash is ever
  # mass-assigned to a model.
  def credit_input
    params.require(:open_item_credit)
  end

  def parsed_date(key)
    value = credit_input[key].presence
    value ? Date.iso8601(value) : business_date
  end

  def report_path_for(role)
    role.to_s == "vendor" ? aged_payables_report_path(tenant_route_options) :
      aged_receivables_report_path(tenant_route_options)
  end

  def money_amount_for_notice(amount_minor)
    helpers.money_amount(amount_minor, currency: Current.tenant.functional_currency)
  end
end
