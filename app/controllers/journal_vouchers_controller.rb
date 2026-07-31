# frozen_string_literal: true

class JournalVouchersController < BrowserController
  before_action -> { require_capability!("documents.post") }, only: %i[new create post]
  before_action -> { require_capability!("documents.reverse") }, only: :reverse
  before_action :set_document, only: %i[show post reverse]

  def index
    @documents = document_scope.includes(:document_lines).order(created_at: :desc)
  end

  def show
    @simulation = Documents::Simulate.call(@document) if @document.postable?
  end

  def new
    load_form
  end

  def create
    load_form
    debit = account_scope.find_by!(code: voucher_params[:debit_account_code])
    credit = account_scope.find_by!(code: voucher_params[:credit_account_code])
    raise ArgumentError, "Debit and credit accounts must be different" if debit == credit

    amount_minor = amount_minor!(voucher_params[:amount])
    posting_date = Date.iso8601(voucher_params[:posting_date])
    @document = Documents::BuildDraft.call(
      tenant: Current.tenant,
      doc_type: "JV",
      document_date: posting_date,
      posting_date: posting_date,
      narration: voucher_params[:narration],
      lines: [
        { account_code: debit.code, amount_minor: amount_minor },
        { account_code: credit.code, amount_minor: -amount_minor }
      ]
    )

    redirect_to journal_voucher_path(@document, tenant_route_options),
      notice: "Draft ready. Review the balanced preview before posting."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError,
         Documents::InvalidDocument, CurrencyProfile::UnsupportedCurrency => e
    load_form
    flash.now[:alert] = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
    render :new, status: :unprocessable_entity
  end

  def post
    Documents::Post.call(@document, actor: "u:#{Current.user.id}", authorize: { user: Current.user })
    redirect_to reports_path(tenant_route_options.merge(posted_document_id: @document.id)),
      notice: "#{@document.reload.document_number} posted. Your trial balance is updated."
  rescue Documents::Post::NotPostable, Documents::Post::NotPermitted, Posting::UnbalancedError,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError, Documents::Post::InactiveAccount,
         Documents::InvalidDocument, CurrencyProfile::UnsupportedCurrency => e
    redirect_to journal_voucher_path(@document, tenant_route_options), alert: e.message
  end

  def reverse
    Documents::Reverse.call(
      @document, actor: "u:#{Current.user.id}", authorize: { user: Current.user }
    )
    redirect_to journal_voucher_path(@document, tenant_route_options),
      notice: "#{@document.document_number} reversed with a compensating voucher."
  rescue Documents::Reverse::NotReversible, Documents::Post::NotPermitted,
         Documents::Post::InactiveAccount, Documents::InvalidDocument,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError => e
    redirect_to journal_voucher_path(@document, tenant_route_options), alert: e.message
  end

  private

  def set_document
    @document = document_scope.find(params[:id])
  end

  def document_scope
    Document.where(tenant_id: Current.tenant.id, doc_type: "JV")
  end

  def account_scope
    Account.active.where(tenant_id: Current.tenant.id)
  end

  def load_form
    @accounts = account_scope.in_code_order
  end

  def voucher_params
    params.require(:journal_voucher).permit(
      :posting_date,
      :narration,
      :debit_account_code,
      :credit_account_code,
      :amount
    )
  end

  def amount_minor!(raw_amount)
    amount = BigDecimal(raw_amount.to_s)
    scaled = amount * 100
    unless amount.positive? && scaled.frac.zero?
      raise ArgumentError, "Amount must be positive with no more than two decimal places"
    end

    scaled.to_i
  rescue ArgumentError
    raise ArgumentError, "Amount must be positive with no more than two decimal places"
  end
end
