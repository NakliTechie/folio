# frozen_string_literal: true

class SettlementsController < BrowserController
  KINDS = { "receipt" => "RC", "payment" => "PY" }.freeze

  before_action -> { require_capability!("reports.read") }, only: %i[index show]
  before_action -> { require_capability!("payments.create") }, only: %i[new create post]
  before_action :set_document, only: %i[show post]

  def index
    @documents = document_scope.includes(:party).order(document_date: :desc, created_at: :desc)
  end

  def show
    @simulation = Documents::Simulate.call(@document) if @document.postable?
  end

  def new
    load_form(params[:kind])
  end

  def create
    load_form(settlement_params[:kind])
    @document = Settlements::BuildDraft.call(
      tenant: Current.tenant,
      doc_type: @doc_type,
      document_date: settlement_params[:document_date],
      bank_account_code: settlement_params[:bank_account_code],
      narration: settlement_params[:narration],
      allocations: settlement_params[:allocations]
    )
    redirect_to settlement_path(@document, tenant_route_options),
      notice: "Draft #{@kind} ready. Review the allocation and accounting preview before posting."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, Settlements::InvalidSettlement,
         Documents::InvalidDocument, CurrencyProfile::UnsupportedCurrency => e
    load_form(settlement_params[:kind])
    flash.now[:alert] = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
    render :new, status: :unprocessable_entity
  end

  def post
    Documents::Post.call(
      @document,
      actor: "u:#{Current.user.id}",
      authorize: { user: Current.user },
      required_capability: "payments.create"
    )
    redirect_to settlement_path(@document, tenant_route_options),
      notice: "#{@document.reload.document_number} posted and its allocations were applied."
  rescue Documents::Post::NotPostable, Documents::Post::NotPermitted, Posting::UnbalancedError,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError, Documents::Post::InactiveAccount,
         Documents::InvalidDocument, CurrencyProfile::UnsupportedCurrency => e
    redirect_to settlement_path(@document, tenant_route_options), alert: e.message
  end

  private

  def set_document
    @document = document_scope.find(params[:id])
  end

  def document_scope
    Document.where(tenant_id: Current.tenant.id, doc_type: KINDS.values)
  end

  def load_form(kind)
    @kind = KINDS.key?(kind.to_s) ? kind.to_s : "receipt"
    @doc_type = KINDS.fetch(@kind)
    config = Settlements::BuildDraft::TYPES.fetch(@doc_type)
    @bank_accounts = Account.active.where(
      tenant_id: Current.tenant.id,
      code: Settlements::BuildDraft::CASH_ACCOUNT_CODES,
      account_type: "asset"
    ).in_code_order
    @open_items = EntryLine.open_items.includes(:party, :amounts, entry: :document).where(
      tenant_id: Current.tenant.id,
      account_code: config.fetch(:account_code),
      party_role: config.fetch(:role)
    ).order(:due_date, :id).select do |line|
      Settlements::BuildDraft.eligible_target?(line, config) && Posting::Clearing.open_amount(line).positive?
    end
    @submitted_allocations = Array(params.dig(:settlement, :allocations)).index_by do |allocation|
      (allocation[:target_entry_line_id] || allocation["target_entry_line_id"]).to_s
    end
  end

  def settlement_params
    params.require(:settlement).permit(
      :kind, :document_date, :bank_account_code, :narration,
      allocations: %i[target_entry_line_id amount clearing_mode]
    )
  end
end
