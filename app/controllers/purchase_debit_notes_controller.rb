# frozen_string_literal: true

class PurchaseDebitNotesController < BrowserController
  before_action -> { require_capability!("reports.read") }, only: %i[index show]
  before_action -> { require_capability!("bills.create") }, only: %i[new create post destroy]
  before_action :set_document, only: %i[show post destroy]

  def index
    @documents = document_scope.includes(:debit_note_for).order(document_date: :desc, created_at: :desc)
  end

  def show
    @simulation = Documents::Simulate.call(@document) if @document.postable?
  end

  def new
    load_form(params[:purchase_bill_id])
  end

  def create
    load_form(debit_note_params[:purchase_bill_id])
    @document = PurchaseDebitNotes::BuildDraft.call(
      tenant: Current.tenant,
      purchase_bill_id: debit_note_params[:purchase_bill_id],
      document_date: debit_note_params[:document_date],
      external_reference: debit_note_params[:external_reference],
      reason_code: debit_note_params[:reason_code],
      narration: debit_note_params[:narration],
      lines: debit_note_params[:lines]
    )
    redirect_to purchase_debit_note_path(@document, tenant_route_options),
      notice: "Draft supplier debit ready. Review the input-tax and payable increase before posting."
  rescue ActiveRecord::RecordNotFound
    redirect_to purchase_bills_path(tenant_route_options),
      alert: "That source purchase bill is unavailable. Choose a posted purchase bill."
  rescue ActiveRecord::RecordInvalid,
         PurchaseDebitNotes::InvalidDebitNote, Documents::InvalidDocument, Taxes::InvalidTaxInput => e
    load_form(debit_note_params[:purchase_bill_id])
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
    redirect_to purchase_debit_note_path(@document, tenant_route_options),
      notice: "#{@document.reload.document_number} posted as a separate vendor payable."
  rescue Documents::Post::NotPostable, Documents::Post::NotPermitted, Posting::UnbalancedError,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError, Documents::Post::InactiveAccount,
         Documents::InvalidDocument, Taxes::InvalidTaxInput => e
    redirect_to purchase_debit_note_path(@document, tenant_route_options), alert: e.message
  end

  def destroy
    reference = @document.external_reference
    Documents::Discard.call!(@document)
    redirect_to purchase_debit_notes_path(tenant_route_options),
      notice: "Draft #{reference} discarded. Its supplier reference can be used again."
  rescue Documents::Discard::NotDiscardable => e
    redirect_to purchase_debit_note_path(@document, tenant_route_options), alert: e.message
  end

  private

  def set_document
    @document = document_scope.find(params[:id])
  end

  def document_scope
    Document.where(tenant_id: Current.tenant.id, doc_type: "PD")
  end

  def bill_scope
    Document.where(tenant_id: Current.tenant.id, doc_type: "PB", state: "posted")
  end

  def load_form(purchase_bill_id)
    @purchase_bill = bill_scope.includes(:document_lines).find(purchase_bill_id)
    @submitted_lines = Array(params.dig(:purchase_debit_note, :lines))
  end

  def debit_note_params
    params.require(:purchase_debit_note).permit(
      :purchase_bill_id, :document_date, :external_reference, :reason_code, :narration,
      lines: %i[document_line_id quantity]
    )
  end
end
