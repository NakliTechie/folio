# frozen_string_literal: true

class ReportsController < BrowserController
  before_action -> { require_capability!("reports.read") }

  def show
    @trial_balance = Reports.trial_balance(Current.tenant.id)
    @account_type_totals = Reports.account_type_totals(Current.tenant.id)
    @highlight_codes = highlighted_account_codes
    @posted_document = posted_document
    @plain_outcome = Documents::PlainLanguageOutcome.for(@posted_document)
  end

  def profit_and_loss
    @to_date = report_date(:to, business_date)
    @from_date = report_date(:from, fiscal_year_start(@to_date))
    raise ArgumentError, "From date must be on or before the to date" if @from_date > @to_date

    @statement = Reports.profit_and_loss(
      Current.tenant.id, from_date: @from_date, to_date: @to_date
    )
  rescue ArgumentError => e
    redirect_to profit_and_loss_report_path(tenant_route_options), alert: e.message unless params[:from].blank? && params[:to].blank?
  end

  def balance_sheet
    @as_of = report_date(:as_of, business_date)
    @statement = Reports.balance_sheet(Current.tenant.id, as_of: @as_of)
  rescue ArgumentError => e
    redirect_to balance_sheet_report_path(tenant_route_options), alert: e.message unless params[:as_of].blank?
  end

  def aged_receivables
    load_aged_report("customer")
  end

  def aged_payables
    load_aged_report("vendor")
  end

  def party_ledger
    @parties = Party.joins(:party_roles).where(tenant_id: Current.tenant.id)
      .where(party_roles: { role: %w[customer vendor] }).distinct.order(:party_number)
    @selected_party = params[:party_id].present? ? @parties.find(params[:party_id]) : @parties.first
    @ledger = Reports.party_ledger(Current.tenant.id, party_id: @selected_party.id) if @selected_party
  end

  def day_book
    @to_date = report_date(:to, business_date)
    @from_date = report_date(:from, @to_date.beginning_of_month)
    @day_book = Reports.day_book(Current.tenant.id, from_date: @from_date, to_date: @to_date)
  rescue ArgumentError => e
    redirect_to day_book_report_path(tenant_route_options), alert: e.message unless params[:from].blank? && params[:to].blank?
  end

  def gst_summary
    @to_date = report_date(:to, business_date)
    @from_date = report_date(:from, @to_date.beginning_of_month)
    @gst_registrations = TaxRegistration.where(tenant_id: Current.tenant.id, kind: "GSTIN")
      .order(:identifier, valid_from: :desc)
    @selected_registration = if params[:tax_registration_id].present?
      @gst_registrations.find(params[:tax_registration_id])
    else
      @gst_registrations.first
    end
    if @selected_registration
      @gst_summary = Reports.gst_returns(
        Current.tenant.id, tax_registration_id: @selected_registration.id,
        from_date: @from_date, to_date: @to_date
      )
    end
  rescue ArgumentError => e
    redirect_to gst_summary_report_path(tenant_route_options), alert: e.message unless params[:from].blank? && params[:to].blank?
  end

  private

  def report_date(key, fallback)
    params[key].present? ? Date.iso8601(params[key]) : fallback
  rescue Date::Error
    raise ArgumentError, "#{key.to_s.humanize} must be a valid date"
  end

  def load_aged_report(role)
    @aged_to = report_date(:aged_to, business_date)
    @aged_report = Reports.aged_open_items(Current.tenant.id, role: role, aged_to: @aged_to)
    @bank_accounts = Account.active.where(
      tenant_id: Current.tenant.id,
      code: OpenItemCredits::BuildRefund::BANK_ACCOUNT_CODES,
      account_type: "asset"
    ).in_code_order
  rescue ArgumentError => e
    destination = role == "customer" ? aged_receivables_report_path : aged_payables_report_path
    redirect_to destination, alert: e.message unless params[:aged_to].blank?
  end

  def fiscal_year_start(date)
    entity = Entity.find_by!(tenant_id: Current.tenant.id, code: "PRIMARY")
    return Date.new(date.year, 1, 1) unless entity.fiscal_year_variant == "IN_APR_MAR"

    Date.new(date.month >= 4 ? date.year : date.year - 1, 4, 1)
  end

  def highlighted_account_codes
    posted_document&.document_lines&.pluck(:account_code) || []
  end

  def posted_document
    return unless params[:posted_document_id].present?

    @posted_document ||= Document.where(tenant_id: Current.tenant.id).find_by(id: params[:posted_document_id])
  end
end
