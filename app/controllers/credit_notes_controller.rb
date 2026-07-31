# frozen_string_literal: true

class CreditNotesController < BrowserController
  before_action -> { require_capability!("reports.read") }, only: %i[index show print]
  before_action -> { require_capability!("invoices.create") }, only: %i[new create post]
  before_action :set_document, only: %i[show print post]

  def index
    @documents = document_scope.includes(:credit_note_for).order(document_date: :desc, created_at: :desc)
  end

  def show
    @simulation = Documents::Simulate.call(@document) if @document.postable?
  end

  def print
    return if @document.statutory_printable?

    redirect_to credit_note_path(@document, tenant_route_options),
      alert: "Print is unavailable because statutory snapshots are incomplete."
  end

  def new
    load_form(params[:invoice_id])
  end

  def create
    load_form(credit_note_params[:invoice_id])
    @document = CreditNotes::BuildDraft.call(
      tenant: Current.tenant,
      invoice_id: credit_note_params[:invoice_id],
      document_date: credit_note_params[:document_date],
      reason_code: credit_note_params[:reason_code],
      narration: credit_note_params[:narration],
      lines: credit_note_params[:lines]
    )
    redirect_to credit_note_path(@document, tenant_route_options),
      notice: "Draft credit note ready. Review the tax and receivable adjustment before posting."
  rescue ActiveRecord::RecordNotFound
    redirect_to sales_invoices_path(tenant_route_options),
      alert: "That source invoice is unavailable. Choose a posted sales invoice."
  rescue ActiveRecord::RecordInvalid, CreditNotes::InvalidCreditNote,
         Documents::InvalidDocument, Taxes::InvalidTaxInput => e
    load_form(credit_note_params[:invoice_id])
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
    redirect_to credit_note_path(@document, tenant_route_options),
      notice: "#{@document.reload.document_number} posted and applied to the invoice receivable."
  rescue Documents::Post::NotPostable, Documents::Post::NotPermitted, Posting::UnbalancedError,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError, Documents::Post::InactiveAccount,
         Documents::InvalidDocument, Taxes::InvalidTaxInput => e
    redirect_to credit_note_path(@document, tenant_route_options), alert: e.message
  end

  private

  def set_document
    @document = document_scope.find(params[:id])
  end

  def document_scope
    Document.where(tenant_id: Current.tenant.id, doc_type: "CN")
  end

  def invoice_scope
    Document.where(tenant_id: Current.tenant.id, doc_type: "SI", state: "posted")
  end

  def load_form(invoice_id)
    @invoice = invoice_scope.includes(:document_lines).find(invoice_id)
    @remaining_quantities = @invoice.document_lines.to_h do |line|
      [ line.id, CreditNotes::BuildDraft.remaining_quantity(line) ]
    end
    @submitted_lines = Array(params.dig(:credit_note, :lines))
  end

  def credit_note_params
    params.require(:credit_note).permit(
      :invoice_id, :document_date, :reason_code, :narration,
      lines: %i[document_line_id quantity]
    )
  end
end
