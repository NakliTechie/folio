# frozen_string_literal: true

class ReportsController < BrowserController
  before_action -> { require_capability!("reports.read") }
  before_action :load_report_entity

  def show
    @trial_balance = Reports.trial_balance(Current.tenant.id, entity_id: @report_entity.id)
    @account_type_totals = Reports.account_type_totals(Current.tenant.id, entity_id: @report_entity.id)
    @highlight_codes = highlighted_account_codes
    @posted_document = posted_document
    @plain_outcome = Documents::PlainLanguageOutcome.for(@posted_document)
  end

  def profit_and_loss
    @to_date = report_date(:to, business_date)
    @from_date = report_date(:from, fiscal_year_start(@to_date))
    raise ArgumentError, "From date must be on or before the to date" if @from_date > @to_date

    @statement = Reports.profit_and_loss(
      Current.tenant.id, from_date: @from_date, to_date: @to_date,
      entity_id: @report_entity.id
    )
  rescue ArgumentError => e
    redirect_to profit_and_loss_report_path(tenant_route_options), alert: e.message unless params[:from].blank? && params[:to].blank?
  end

  def balance_sheet
    @as_of = report_date(:as_of, business_date)
    @statement = Reports.balance_sheet(
      Current.tenant.id, as_of: @as_of, entity_id: @report_entity.id
    )
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
    if @selected_party
      @ledger = Reports.party_ledger(
        Current.tenant.id, party_id: @selected_party.id, entity_id: @report_entity.id
      )
    end
  end

  def day_book
    @to_date = report_date(:to, business_date)
    @from_date = report_date(:from, @to_date.beginning_of_month)
    @day_book = Reports.day_book(
      Current.tenant.id, from_date: @from_date, to_date: @to_date,
      entity_id: @report_entity.id
    )
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

  def gstr1_filing
    from_date = report_date(:from, business_date.beginning_of_month)
    to_date = report_date(:to, from_date.end_of_month)
    result = Reports.gstr1_filing(
      Current.tenant.id,
      tax_registration_id: params.require(:tax_registration_id),
      from_date: from_date,
      to_date: to_date
    )
    send_data(
      JSON.pretty_generate(result.payload),
      filename: "gstr1-#{result.payload.fetch('fp')}-#{result.payload.fetch('gstin')}.json",
      type: "application/json",
      disposition: "attachment"
    )
  rescue Date::Error, ArgumentError, Taxes::India::Gst::Filing::NotReady,
         Taxes::India::Gst::Filing::InvalidPayload => e
    redirect_to gst_summary_report_path(tenant_route_options), alert: e.message
  end

  def tds
    @fiscal_year, @quarter = tds_period
    @tds_return = Reports.tds_return_26q(
      Current.tenant.id, fiscal_year: @fiscal_year, quarter: @quarter
    )
    @tds_deductees = @tds_return.fetch("deductees")
    selected_id = params[:party_id].presence || @tds_deductees.first&.fetch("party_id")
    @tds_certificate = if selected_id
      Reports.tds_certificate_16a(
        Current.tenant.id, party_id: selected_id,
        fiscal_year: @fiscal_year, quarter: @quarter
      )
    end
  rescue ArgumentError => e
    redirect_to tds_report_path(tenant_route_options), alert: e.message
  end

  def tds_form_26q
    fiscal_year, quarter = tds_period
    result = Reports.tds_return_26q(
      Current.tenant.id, fiscal_year: fiscal_year, quarter: quarter
    )
    send_tds_json(result, "form-26q-fy#{fiscal_year}-q#{quarter}.json")
  rescue ArgumentError => e
    redirect_to tds_report_path(tenant_route_options), alert: e.message
  end

  def tds_form_16a
    fiscal_year, quarter = tds_period
    ensure_tds_deductee!(params.require(:party_id), fiscal_year, quarter)
    result = Reports.tds_certificate_16a(
      Current.tenant.id, party_id: params[:party_id],
      fiscal_year: fiscal_year, quarter: quarter
    )
    send_tds_json(result, "form-16a-fy#{fiscal_year}-q#{quarter}-deductee-#{params[:party_id]}.json")
  rescue ArgumentError, ActionController::ParameterMissing => e
    redirect_to tds_report_path(tenant_route_options), alert: e.message
  end

  private

  def load_report_entity
    @report_entities = Entity.where(tenant_id: Current.tenant.id).order(:code)
    @report_entity = if params[:entity_id].present?
      @report_entities.find(params[:entity_id])
    else
      @report_entities.find_by!(code: "PRIMARY")
    end
  end

  def report_date(key, fallback)
    params[key].present? ? Date.iso8601(params[key]) : fallback
  rescue Date::Error
    raise ArgumentError, "#{key.to_s.humanize} must be a valid date"
  end

  def tds_period
    fiscal_year = params[:fiscal_year].present? ? Integer(params[:fiscal_year], 10) :
      Documents.fiscal_year(business_date, variant: @report_entity.fiscal_year_variant)
    quarter = params[:quarter].present? ? Integer(params[:quarter], 10) :
      TdsDeduction.india_quarter(business_date)
    raise ArgumentError, "Fiscal year is invalid" unless fiscal_year.between?(2000, 2200)
    raise ArgumentError, "Quarter must be between 1 and 4" unless quarter.between?(1, 4)

    [ fiscal_year, quarter ]
  rescue ArgumentError => e
    raise ArgumentError, e.message.match?(/Quarter|Fiscal/) ? e.message : "TDS period is invalid"
  end

  def ensure_tds_deductee!(party_id, fiscal_year, quarter)
    return if TdsDeduction.for_tenant(Current.tenant.id).in_period(fiscal_year, quarter)
      .exists?(party_id: party_id)

    raise ActiveRecord::RecordNotFound, "TDS deductee not found for this period"
  end

  def send_tds_json(result, filename)
    send_data JSON.pretty_generate(result), filename: filename,
      type: "application/json", disposition: "attachment"
  end

  def load_aged_report(role)
    @aged_to = report_date(:aged_to, business_date)
    @aged_report = Reports.aged_open_items(
      Current.tenant.id, role: role, aged_to: @aged_to, entity_id: @report_entity.id
    )
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
    return Date.new(date.year, 1, 1) unless @report_entity.fiscal_year_variant == "IN_APR_MAR"

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
