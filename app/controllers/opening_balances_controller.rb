# frozen_string_literal: true

class OpeningBalancesController < BrowserController
  before_action -> { require_capability!("reports.read") }, only: %i[index show]
  before_action -> { require_capability!("accounts.manage") }, only: %i[new create]
  before_action -> { require_capability!("documents.post") }, only: %i[new create post]
  before_action -> { require_capability!("documents.reverse") }, only: :reverse
  before_action :set_document, only: %i[show post reverse]

  def index
    @documents = document_scope.includes(:document_lines).order(created_at: :desc)
  end

  def show
    @simulation = Documents::Simulate.call(@document) if @document.postable?
    @accounts_by_code = Account.where(
      tenant_id: Current.tenant.id, code: @document.document_lines.map(&:account_code)
    ).index_by(&:code)
  end

  def new
    load_form
  end

  def create
    load_form
    posting_date = Date.iso8601(opening_balance_params.fetch(:posting_date))
    lines = parsed_lines!
    assert_balanced!(lines)

    narration = opening_balance_params[:narration].presence || "Opening balances"
    @document = Documents::BuildDraft.call(
      tenant: Current.tenant,
      doc_type: "OB",
      document_date: posting_date,
      posting_date: posting_date,
      narration: narration,
      lines: lines.map do |line|
        { account_code: line.fetch(:account).code, amount_minor: line.fetch(:amount_minor) }
      end
    )

    redirect_to opening_balance_path(@document, tenant_route_options),
      notice: "Opening-balance draft ready. Review it before posting."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError, KeyError,
         Documents::InvalidDocument, CurrencyProfile::UnsupportedCurrency => e
    load_form
    flash.now[:alert] = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
    render :new, status: :unprocessable_entity
  end

  def post
    Documents::Post.call(@document, actor: "u:#{Current.user.id}", authorize: { user: Current.user })
    redirect_to balance_sheet_report_path(tenant_route_options.merge(as_of: @document.posting_date.iso8601)),
      notice: "#{@document.reload.document_number} posted. Your balance sheet is updated."
  rescue Documents::Post::NotPostable, Documents::Post::NotPermitted, Documents::Post::InactiveAccount,
         Posting::UnbalancedError, Posting::PeriodClosedError, Posting::PeriodRestrictedError,
         Documents::InvalidDocument, CurrencyProfile::UnsupportedCurrency => e
    redirect_to opening_balance_path(@document, tenant_route_options), alert: e.message
  end

  def reverse
    Documents::Reverse.call(
      @document, actor: "u:#{Current.user.id}", authorize: { user: Current.user }
    )
    redirect_to opening_balance_path(@document, tenant_route_options),
      notice: "#{@document.document_number} reversed with a compensating opening-balance document."
  rescue Documents::Reverse::NotReversible, Documents::Post::NotPermitted,
         Documents::Post::InactiveAccount, Documents::InvalidDocument,
         Posting::PeriodClosedError, Posting::PeriodRestrictedError => e
    redirect_to opening_balance_path(@document, tenant_route_options), alert: e.message
  end

  private

  def set_document
    @document = document_scope.find(params[:id])
  end

  def document_scope
    Document.where(tenant_id: Current.tenant.id, doc_type: "OB")
  end

  def account_scope
    Account.active.where(tenant_id: Current.tenant.id, account_type: %w[asset liability equity])
  end

  def load_form
    @accounts = account_scope.in_code_order
    @entity = Entity.find_by!(tenant_id: Current.tenant.id, code: "PRIMARY")
    @submitted_lines = params.dig(:opening_balance, :lines)&.to_unsafe_h || {}
    @default_posting_date = fiscal_year_start(business_date)
  end

  def parsed_lines!
    raw_lines = opening_balance_params[:lines]&.to_h || {}
    raw_lines.each_with_object([]) do |(account_id, amounts), lines|
      account = account_scope.find(account_id)
      debit = amount_minor(amounts[:debit])
      credit = amount_minor(amounts[:credit])
      raise ArgumentError, "#{account.code} cannot have both a debit and credit" if debit.positive? && credit.positive?
      next if debit.zero? && credit.zero?

      lines << { account: account, amount_minor: debit - credit }
    end
  end

  def assert_balanced!(lines)
    raise ArgumentError, "Enter at least two non-zero account balances" if lines.size < 2
    raise ArgumentError, "Debits and credits must be equal" unless lines.sum { |line| line.fetch(:amount_minor) }.zero?
  end

  def amount_minor(raw_amount)
    return 0 if raw_amount.blank?

    amount = BigDecimal(raw_amount.to_s)
    scaled = amount * 100
    unless amount >= 0 && scaled.frac.zero?
      raise ArgumentError, "Amounts cannot be negative and may have no more than two decimal places"
    end
    scaled.to_i
  rescue ArgumentError
    raise ArgumentError, "Amounts cannot be negative and may have no more than two decimal places"
  end

  def fiscal_year_start(date)
    return Date.new(date.year, 1, 1) unless @entity.fiscal_year_variant == "IN_APR_MAR"

    Date.new(date.month >= 4 ? date.year : date.year - 1, 4, 1)
  end

  def opening_balance_params
    params.require(:opening_balance).permit(:posting_date, :narration, lines: {})
  end
end
