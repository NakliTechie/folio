# frozen_string_literal: true

module Api
  module V1
    class OpenItemCreditsController < BaseController
      before_action -> { require_capability!("payments.create") }
      rescue_from OpenItemCredits::InvalidCreditAction do |e|
        render_error(e.message, :unprocessable_entity)
      end

      def net
        amount = Settlements::BuildDraft.money_minor!(params.fetch(:amount), "net amount")
        result = OpenItemCredits::Net.call(
          tenant: Current.tenant,
          credit_entry_line_id: params.fetch(:credit_entry_line_id),
          target_entry_line_id: params.fetch(:target_entry_line_id),
          amount_minor: amount,
          applied_on: params[:applied_on].present? ? Date.iso8601(params[:applied_on]) : business_date,
          actor: "u:#{current_user.id}"
        )
        render json: { netting: { reference: result.reference, amount_minor: result.amount_minor } },
          status: :created
      rescue Date::Error, KeyError, Settlements::InvalidSettlement,
             Documents::InvalidDocument, Documents::Post::NotPermitted,
             Documents::Post::NotPostable, Documents::Post::InactiveAccount,
             Posting::UnbalancedError, Posting::PeriodClosedError,
             Posting::PeriodRestrictedError => e
        render_error(e.message, :unprocessable_entity)
      end

      def refund
        amount = Settlements::BuildDraft.money_minor!(params.fetch(:amount), "refund amount")
        document = OpenItemCredits::BuildRefund.call(
          tenant: Current.tenant,
          credit_entry_line_id: params.fetch(:credit_entry_line_id),
          amount_minor: amount,
          bank_account_code: params.fetch(:bank_account_code),
          document_date: params[:document_date].presence || business_date,
          narration: params[:narration]
        )
        entry = Documents::Post.call(
          document, actor: "u:#{current_user.id}", authorize: { user: current_user },
          required_capability: "payments.create"
        )
        render json: {
          refund: { id: document.id, document_number: document.document_number,
                    amount_minor: document.total_minor, ledger_event_id: entry.ledger_event_id }
        }, status: :created
      rescue Date::Error, KeyError, Settlements::InvalidSettlement => e
        render_error(e.message, :unprocessable_entity)
      end
    end
  end
end
