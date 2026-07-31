# frozen_string_literal: true

module Api
  module V1
    class PeriodClosesController < BaseController
      before_action -> { require_capability!("reports.read") }, only: :show
      before_action -> { require_capability!("period.lock") }, only: :update

      def show
        render json: { period_close: readiness }
      rescue PeriodControls::InvalidControl => e
        render_error(e.message, :unprocessable_entity)
      end

      def update
        control = PeriodControls::Manage.call(
          tenant: Current.tenant,
          fiscal_year: params[:fiscal_year],
          period_no: params[:period_no],
          state: params[:state],
          actor: current_user
        )
        render json: {
          period_control: {
            fiscal_year: control.fiscal_year,
            period_no: control.period_no,
            state: control.state,
            restricted_capability: control.capability
          },
          period_close: readiness
        }
      rescue PeriodControls::InvalidControl, ActiveRecord::RecordInvalid => e
        message = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
        render_error(message, :unprocessable_entity)
      end

      private

      def readiness
        PeriodControls::Readiness.call(
          tenant: Current.tenant,
          fiscal_year: params[:fiscal_year],
          period_no: params[:period_no]
        )
      end
    end
  end
end
