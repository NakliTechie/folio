# frozen_string_literal: true

module Api
  module V1
    class ReportsController < BaseController
      before_action -> { require_capability!("reports.read") }

      def trial_balance
        render json: { trial_balance: Reports.trial_balance(Current.tenant.id) }
      end

      def account_type_totals
        render json: { account_type_totals: Reports.account_type_totals(Current.tenant.id) }
      end
    end
  end
end
