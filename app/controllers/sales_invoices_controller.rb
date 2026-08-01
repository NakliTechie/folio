# frozen_string_literal: true

class SalesInvoicesController < BrowserController
  before_action -> { require_capability!("reports.read") }, only: %i[index show print einvoice_json]
  before_action -> { require_capability!("invoices.create") }, only: %i[new create post prepare_einvoice]
  before_action -> { require_capability!("documents.reverse") }, only: :reverse
  before_action :set_document, only: %i[show print einvoice_json prepare_einvoice post reverse]

  def index
    @documents = document_scope.includes(:party).order(document_date: :desc, created_at: :desc)
  end

  def show
    @simulation = Documents::Simulate.call(@document) if @document.postable?
    @einvoice_submission = @document.einvoice_submission
    @einvoice_cancellation = @einvoice_submission&.einvoice_cancellation
  end

  def print
    @einvoice_submission = @document.einvoice_submission
    @einvoice_cancellation = @einvoice_submission&.einvoice_cancellation
    return if @document.statutory_printable?

    redirect_to sales_invoice_path(@document, tenant_route_options),
      alert: "Print is unavailable because this historical draft predates complete statutory snapshots."
  end

  def prepare_einvoice
    submission = Taxes::India::Gst::EInvoice::Prepare.call(
      document: @document,
      actor: "u:#{Current.user.id}",
      actor_user_id: Current.user.id
    )
    redirect_to sales_invoice_path(@document, tenant_route_options),
      notice: "INV-01 v#{submission.schema_version} JSON prepared. No IRN has been generated or submitted."
  rescue Taxes::India::Gst::EInvoice::NotReady,
         Taxes::India::Gst::EInvoice::InvalidPayload,
         ActiveRecord::RecordInvalid => e
    redirect_to sales_invoice_path(@document, tenant_route_options), alert: e.message
  end

  def einvoice_json
    submission = @document.einvoice_submission
    unless submission
      return redirect_to sales_invoice_path(@document, tenant_route_options),
        alert: "Prepare the e-invoice request before downloading it."
    end

    send_data(
      JSON.pretty_generate(submission.payload),
      filename: "einvoice-#{@document.document_number.tr('/', '-')}.json",
      type: "application/json",
      disposition: "attachment"
    )
  end

  def new
    load_form
  end

  def create
    load_form
    @document = SalesInvoices::BuildDraft.call(
      tenant: Current.tenant,
      party_id: invoice_params[:party_id],
      tax_registration_id: invoice_params[:tax_registration_id],
      document_date: invoice_params[:document_date],
      due_date: invoice_params[:due_date],
      place_of_supply_state_code: invoice_params[:place_of_supply_state_code],
      place_of_supply_override_reason: invoice_params[:place_of_supply_override_reason],
      contract_id: invoice_params[:contract_id],
      actor: Current.user,
      external_reference: invoice_params[:external_reference],
      narration: invoice_params[:narration],
      lines: invoice_params[:lines]
    )
    redirect_to sales_invoice_path(@document, tenant_route_options),
      notice: "Draft invoice ready. Review the frozen tax preview before posting."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, SalesInvoices::InvalidInvoice,
         Documents::InvalidDocument, Taxes::InvalidTaxInput, CurrencyProfile::UnsupportedCurrency => e
    load_form
    flash.now[:alert] = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
    render :new, status: :unprocessable_entity
  end

  def post
    Documents::Post.call(
      @document,
      actor: "u:#{Current.user.id}",
      authorize: { user: Current.user },
      required_capability: "invoices.create"
    )
    redirect_to sales_invoice_path(@document, tenant_route_options),
      notice: "#{@document.reload.document_number} posted. Receivables and GST are updated."
  rescue Documents::Post::NotPostable, Documents::Post::NotPermitted, Posting::UnbalancedError,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError, Documents::Post::InactiveAccount,
         Documents::InvalidDocument, Taxes::InvalidTaxInput, CurrencyProfile::UnsupportedCurrency => e
    redirect_to sales_invoice_path(@document, tenant_route_options), alert: e.message
  end

  def reverse
    Documents::Reverse.call(
      @document, actor: "u:#{Current.user.id}", authorize: { user: Current.user }
    )
    redirect_to sales_invoice_path(@document, tenant_route_options),
      notice: "#{@document.document_number} reversed and its open receivable cleared."
  rescue Documents::Reverse::NotReversible, Documents::Post::NotPermitted,
         Documents::Post::InactiveAccount, Documents::InvalidDocument,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError => e
    redirect_to sales_invoice_path(@document, tenant_route_options), alert: e.message
  end

  private

  def set_document
    @document = document_scope.find(params[:id])
  end

  def document_scope
    Document.where(tenant_id: Current.tenant.id, doc_type: "SI")
  end

  def load_form
    @parties = Party.active.joins(:party_roles)
      .where(tenant_id: Current.tenant.id, party_roles: { role: "customer" })
      .distinct.order(:name)
    @seller_registrations = TaxRegistration.active.joins(:office_tax_registrations)
      .where(
        tenant_id: Current.tenant.id,
        kind: "GSTIN",
        office_tax_registrations: { office_id: primary_office.id, tenant_id: Current.tenant.id }
      ).distinct.order(:identifier)
    @items = Item.active.where(tenant_id: Current.tenant.id).order(:name)
    @contracts = Contract.where(tenant_id: Current.tenant.id, status: "active", side: "sell")
      .includes(:party).order(:contract_number)
    @company_profile_complete = primary_office.statutory_address_complete?
    @registered_customer_ready = Party.active.joins(:party_roles, :party_tax_registrations)
      .where(
        tenant_id: Current.tenant.id,
        party_roles: { role: "customer" },
        party_tax_registrations: { active: true, kind: "GSTIN" }
      ).exists?
    @invoice_setup_ready = @company_profile_complete && @seller_registrations.any? &&
      @registered_customer_ready && @items.any?
    @submitted_lines = Array(params.dig(:sales_invoice, :lines))
  end

  def primary_office
    @primary_office ||= Office.find_by!(tenant_id: Current.tenant.id, code: "PRIMARY")
  end

  def invoice_params
    params.require(:sales_invoice).permit(
      :party_id,
      :contract_id,
      :tax_registration_id,
      :document_date,
      :due_date,
      :place_of_supply_state_code,
      :place_of_supply_override_reason,
      :external_reference,
      :narration,
      lines: %i[item_id quantity unit_price]
    )
  end
end
