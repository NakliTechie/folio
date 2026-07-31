# frozen_string_literal: true

class SettlementsController < BrowserController
  KINDS = { "receipt" => "RC", "payment" => "PY" }.freeze

  before_action -> { require_capability!("reports.read") }, only: %i[index show]
  before_action -> { require_capability!("payments.create") },
    only: %i[new create post reset_allocation new_reallocation reallocate]
  before_action :set_document, only: %i[show post reset_allocation new_reallocation reallocate]

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

  def reset_allocation
    allocation = Settlements::ResetAllocation.call(
      document: @document, allocation_id: params[:allocation_id],
      actor: "u:#{Current.user.id}", reset_on: [ Date.current, @document.document_date ].max
    )
    redirect_to settlement_path(@document, tenant_route_options),
      notice: "Allocation #{allocation.line_no} reset. The cash is now unapplied and can be reassigned."
  rescue Settlements::InvalidReset => e
    redirect_to settlement_path(@document, tenant_route_options), alert: e.message
  end

  def new_reallocation
    load_reallocation
  rescue Settlements::InvalidReset, ActiveRecord::RecordNotFound => e
    redirect_to settlement_path(@document, tenant_route_options), alert: e.message
  end

  def reallocate
    allocation = Settlements::Reallocate.call(
      document: @document, allocation_id: params[:allocation_id],
      target_entry_line_id: reallocation_params[:target_entry_line_id],
      clearing_mode: reallocation_params[:clearing_mode],
      actor: "u:#{Current.user.id}", applied_on: [ Date.current, @document.document_date ].max
    )
    redirect_to settlement_path(@document, tenant_route_options),
      notice: "Unapplied cash reallocated to #{allocation.target_snapshot.fetch("assignment")}."
  rescue Settlements::InvalidReset, ActiveRecord::RecordNotFound => e
    render_reallocation_error(e)
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
  def load_reallocation
    @allocation = @document.document_allocations.find(params[:allocation_id])
    unless @allocation.reset? && @allocation.settlement_reallocation.nil?
      raise Settlements::InvalidReset, "allocation is not available for reallocation"
    end
    config = Settlements::BuildDraft::TYPES.fetch(@document.doc_type)
    @open_items = EntryLine.open_items.includes(:party, :amounts, entry: :document).where(
      tenant_id: Current.tenant.id,
      account_code: config.fetch(:account_code),
      party_role: config.fetch(:role),
      party_id: @document.party_id
    ).order(:due_date, :id).select do |line|
      Settlements::BuildDraft.eligible_target?(line, config) &&
        Posting::Clearing.open_amount(line) >= @allocation.amount_minor
    end
  end

  def reallocation_params
    params.require(:reallocation).permit(:target_entry_line_id, :clearing_mode)
  end

  def render_reallocation_error(error)
    load_reallocation
    flash.now[:alert] = error.message
    render :new_reallocation, status: :unprocessable_entity
  rescue Settlements::InvalidReset, ActiveRecord::RecordNotFound
    redirect_to settlement_path(@document, tenant_route_options), alert: error.message
  end
end
