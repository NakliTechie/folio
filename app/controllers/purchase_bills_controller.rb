# frozen_string_literal: true

class PurchaseBillsController < BrowserController
  before_action -> { require_capability!("reports.read") }, only: %i[index show]
  before_action -> { require_capability!("bills.create") }, only: %i[new create post destroy]
  before_action -> { require_capability!("documents.reverse") }, only: :reverse
  before_action :set_document, only: %i[show post reverse destroy]

  def index
    @documents = document_scope.includes(:party).order(document_date: :desc, created_at: :desc)
  end

  def show
    @simulation = Documents::Simulate.call(@document) if @document.postable?
  end

  def new
    load_form
  end

  def create
    load_form
    @document = PurchaseBills::BuildDraft.call(
      tenant: Current.tenant,
      party_id: bill_params[:party_id],
      tax_registration_id: bill_params[:tax_registration_id],
      document_date: bill_params[:document_date],
      due_date: bill_params[:due_date],
      place_of_supply_state_code: bill_params[:place_of_supply_state_code],
      external_reference: bill_params[:external_reference],
      narration: bill_params[:narration],
      tds_section: bill_params[:tds_section],
      lines: bill_params[:lines]
    )
    redirect_to purchase_bill_path(@document, tenant_route_options),
      notice: "Draft bill ready. Review the frozen input-GST preview before posting."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, PurchaseBills::InvalidBill,
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
      required_capability: "bills.create"
    )
    redirect_to purchase_bill_path(@document, tenant_route_options),
      notice: "#{@document.reload.document_number} posted. Payables and input GST are updated."
  rescue Documents::Post::NotPostable, Documents::Post::NotPermitted, Posting::UnbalancedError,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError, Documents::Post::InactiveAccount,
         Documents::InvalidDocument, Taxes::InvalidTaxInput, CurrencyProfile::UnsupportedCurrency => e
    redirect_to purchase_bill_path(@document, tenant_route_options), alert: e.message
  end

  def reverse
    Documents::Reverse.call(
      @document, actor: "u:#{Current.user.id}", authorize: { user: Current.user }
    )
    redirect_to purchase_bill_path(@document, tenant_route_options),
      notice: "#{@document.document_number} reversed and its open payable cleared."
  rescue Documents::Reverse::NotReversible, Documents::Post::NotPermitted,
         Documents::Post::InactiveAccount, Documents::InvalidDocument,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError => e
    redirect_to purchase_bill_path(@document, tenant_route_options), alert: e.message
  end

  def destroy
    reference = @document.external_reference
    Documents::Discard.call!(@document)
    redirect_to purchase_bills_path(tenant_route_options),
      notice: "Draft #{reference} discarded. Its supplier reference can be used again."
  rescue Documents::Discard::NotDiscardable => e
    redirect_to purchase_bill_path(@document, tenant_route_options), alert: e.message
  end

  private

  def set_document
    @document = document_scope.find(params[:id])
  end

  def document_scope
    Document.where(tenant_id: Current.tenant.id, doc_type: "PB")
  end

  def load_form
    @parties = Party.active.joins(:party_roles)
      .where(tenant_id: Current.tenant.id, party_roles: { role: "vendor" })
      .distinct.order(:name)
    @buyer_registrations = TaxRegistration.active.joins(:office_tax_registrations)
      .where(
        tenant_id: Current.tenant.id,
        kind: "GSTIN",
        office_tax_registrations: { office_id: primary_office.id, tenant_id: Current.tenant.id }
      ).distinct.order(:identifier)
    @items = Item.active.where(tenant_id: Current.tenant.id).order(:name)
    @tds_sections = Taxes::India::Tds::Schedule.sections
    @company_profile_complete = primary_office.statutory_address_complete?
    @registered_vendor_ready = Party.active.joins(:party_roles, :party_tax_registrations)
      .where(
        tenant_id: Current.tenant.id,
        party_roles: { role: "vendor" },
        party_tax_registrations: { active: true, kind: "GSTIN" }
      ).exists?
    @purchase_setup_ready = @company_profile_complete && @buyer_registrations.any? &&
      @registered_vendor_ready && @items.any?
    @submitted_lines = Array(params.dig(:purchase_bill, :lines))
  end

  def primary_office
    @primary_office ||= Office.find_by!(tenant_id: Current.tenant.id, code: "PRIMARY")
  end

  def bill_params
    params.require(:purchase_bill).permit(
      :party_id,
      :tax_registration_id,
      :document_date,
      :due_date,
      :place_of_supply_state_code,
      :external_reference,
      :narration,
      :tds_section,
      lines: %i[item_id quantity unit_price]
    )
  end
end
