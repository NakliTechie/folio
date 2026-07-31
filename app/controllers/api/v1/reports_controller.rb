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

      def profit_and_loss
        to_date = params[:to].present? ? Date.iso8601(params[:to]) : Date.current
        from_date = params[:from].present? ? Date.iso8601(params[:from]) : fiscal_year_start(to_date)
        raise ArgumentError, "from must be on or before to" if from_date > to_date

        render json: { profit_and_loss: Reports.profit_and_loss(
          Current.tenant.id, from_date: from_date, to_date: to_date
        ) }
      rescue Date::Error, ArgumentError => e
        render_error(e.message, :unprocessable_entity)
      end

      def balance_sheet
        as_of = params[:as_of].present? ? Date.iso8601(params[:as_of]) : Date.current
        render json: { balance_sheet: Reports.balance_sheet(Current.tenant.id, as_of: as_of) }
      rescue Date::Error => e
        render_error(e.message, :unprocessable_entity)
      end

      def aged_receivables
        render_aged_open_items("customer")
      end

      def aged_payables
        render_aged_open_items("vendor")
      end

      def party_ledger
        raise ActiveRecord::RecordNotFound, "party is required" if params[:party_id].blank?

        render json: {
          party_ledger: Reports.party_ledger(Current.tenant.id, party_id: params[:party_id])
        }
      end

      def day_book
        to_date = report_date(:to, Date.current)
        from_date = report_date(:from, to_date.beginning_of_month)
        render json: {
          day_book: Reports.day_book(Current.tenant.id, from_date: from_date, to_date: to_date)
        }
      rescue Date::Error, ArgumentError => e
        render_error(e.message, :unprocessable_entity)
      end

      def gst_summary
        to_date = report_date(:to, Date.current)
        from_date = report_date(:from, to_date.beginning_of_month)
        raise ArgumentError, "tax_registration_id is required" if params[:tax_registration_id].blank?

        render json: {
          gst_summary: Reports.gst_returns(
            Current.tenant.id, tax_registration_id: params[:tax_registration_id],
            from_date: from_date, to_date: to_date
          )
        }
      rescue Date::Error, ArgumentError => e
        render_error(e.message, :unprocessable_entity)
      end

      private

      def fiscal_year_start(date)
        entity = Entity.find_by!(tenant_id: Current.tenant.id, code: "PRIMARY")
        return Date.new(date.year, 1, 1) unless entity.fiscal_year_variant == "IN_APR_MAR"

        Date.new(date.month >= 4 ? date.year : date.year - 1, 4, 1)
      end

      def report_date(key, fallback)
        params[key].present? ? Date.iso8601(params[key]) : fallback
      end

      def render_aged_open_items(role)
        aged_to = params[:aged_to].present? ? Date.iso8601(params[:aged_to]) : Date.current
        render json: {
          aged_open_items: Reports.aged_open_items(Current.tenant.id, role: role, aged_to: aged_to)
        }
      rescue Date::Error => e
        render_error(e.message, :unprocessable_entity)
      end
    end
  end
end
