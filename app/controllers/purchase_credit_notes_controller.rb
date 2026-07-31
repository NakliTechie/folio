# frozen_string_literal: true

class PurchaseCreditNotesController < BrowserController
  before_action -> { require_capability!("reports.read") }, only: %i[index show]
  before_action -> { require_capability!("bills.create") }, only: %i[new create post]
  before_action :set_document, only: %i[show post]

  def index
    @documents = document_scope.includes(:credit_note_for).order(document_date: :desc, created_at: :desc)
  end

  def show
    @simulation = Documents::Simulate.call(@document) if @document.postable?
  end

  def new
    load_form(params[:purchase_bill_id])
  end

  def create
    load_form(credit_note_params[:purchase_bill_id])
    @document = PurchaseCreditNotes::BuildDraft.call(
      tenant: Current.tenant,
      purchase_bill_id: credit_note_params[:purchase_bill_id],
      document_date: credit_note_params[:document_date],
      external_reference: credit_note_params[:external_reference],
      reason_code: credit_note_params[:reason_code],
      narration: credit_note_params[:narration],
      lines: credit_note_params[:lines]
    )
    redirect_to purchase_credit_note_path(@document, tenant_route_options),
      notice: "Draft supplier credit ready. Review the input-tax and payable adjustment before posting."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound,
         PurchaseCreditNotes::InvalidCreditNote, Documents::InvalidDocument, Taxes::InvalidTaxInput => e
    load_form(credit_note_params[:purchase_bill_id])
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
    redirect_to purchase_credit_note_path(@document, tenant_route_options),
      notice: "#{@document.reload.document_number} posted and applied to the purchase-bill payable."
  rescue Documents::Post::NotPostable, Documents::Post::NotPermitted, Posting::UnbalancedError,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError, Documents::Post::InactiveAccount,
         Documents::InvalidDocument, Taxes::InvalidTaxInput => e
    redirect_to purchase_credit_note_path(@document, tenant_route_options), alert: e.message
  end

  private

  def set_document
    @document = document_scope.find(params[:id])
  end

  def document_scope
    Document.where(tenant_id: Current.tenant.id, doc_type: "PC")
  end

  def bill_scope
    Document.where(tenant_id: Current.tenant.id, doc_type: "PB", state: "posted")
  end

  def load_form(purchase_bill_id)
    @purchase_bill = bill_scope.includes(:document_lines).find(purchase_bill_id)
    @remaining_quantities = @purchase_bill.document_lines.to_h do |line|
      [ line.id, PurchaseCreditNotes::BuildDraft.remaining_quantity(line) ]
    end
    @submitted_lines = Array(params.dig(:purchase_credit_note, :lines))
  end

  def credit_note_params
    params.require(:purchase_credit_note).permit(
      :purchase_bill_id, :document_date, :external_reference, :reason_code, :narration,
      lines: %i[document_line_id quantity]
    )
  end
end
