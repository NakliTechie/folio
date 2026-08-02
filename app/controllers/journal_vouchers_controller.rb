# frozen_string_literal: true

class JournalVouchersController < BrowserController
  before_action -> { require_capability!("documents.post") }, only: %i[new create edit update destroy post]
  before_action -> { require_capability!("documents.reverse") }, only: :reverse
  before_action :require_identity_before_form_entry, only: %i[new edit]
  before_action :set_document, only: %i[show edit update destroy post reverse]

  def index
    @documents = document_scope.includes(:document_lines).order(created_at: :desc)
  end

  def show
    @simulation = Documents::Simulate.call(@document) if @document.postable?
    @plain_outcome = Documents::PlainLanguageOutcome.for(@document)
  end

  def new
    @event_kind = params[:event].presence
    load_form
  end

  def edit
    @event_kind = "journal"
    load_form(@document)
    render :new
  end

  def create
    @event_kind = voucher_params[:event_kind].presence || "journal"
    load_form
    attributes = journal_attributes
    @document = Documents::BuildDraft.call(
      tenant: Current.tenant,
      doc_type: "JV",
      document_date: attributes.fetch(:posting_date),
      posting_date: attributes.fetch(:posting_date),
      narration: attributes.fetch(:narration),
      lines: attributes.fetch(:lines)
    )

    redirect_to journal_voucher_path(@document, tenant_route_options),
      notice: "Draft ready. Review the balanced preview before posting."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError,
         Documents::InvalidDocument, CurrencyProfile::UnsupportedCurrency => e
    load_form
    flash.now[:alert] = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
    render :new, status: :unprocessable_entity
  end

  def update
    @event_kind = voucher_params[:event_kind].presence || "journal"
    load_form(@document)
    attributes = journal_attributes
    Documents::UpdateJournalDraft.call!(
      document: @document,
      posting_date: attributes.fetch(:posting_date),
      narration: attributes.fetch(:narration),
      lines: attributes.fetch(:lines)
    )
    redirect_to journal_voucher_path(@document, tenant_route_options), notice: "Draft updated. Review it before posting."
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError,
         Documents::InvalidDocument, CurrencyProfile::UnsupportedCurrency => e
    load_form(@document)
    flash.now[:alert] = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
    render :new, status: :unprocessable_entity
  end

  def destroy
    Documents::Discard.call!(@document)
    redirect_to journal_vouchers_path(tenant_route_options), notice: "Draft voucher discarded."
  rescue Documents::Discard::NotDiscardable => e
    redirect_to journal_voucher_path(@document, tenant_route_options), alert: e.message
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

  def require_identity_before_form_entry
    if Rails.application.config.x.email_verification_required && !Current.user.verified?
      return redirect_to root_path(tenant_route_options),
        alert: "Verify your email before recording a business event. No input has been lost."
    end
    return unless Rails.application.config.x.mfa_required && !Current.user.mfa_enabled?

    redirect_to mfa_setup_security_path(tenant_route_options.merge(return_to: request.fullpath)),
      alert: "Protect your account before recording a business event. You will return here after setup."
  end

  def set_document
    @document = document_scope.find(params[:id])
  end

  def document_scope
    Document.where(tenant_id: Current.tenant.id, doc_type: "JV")
  end

  def account_scope
    Account.active.where(tenant_id: Current.tenant.id)
  end

  def load_form(document = nil)
    @accounts = account_scope.in_code_order
    @cash_accounts = @accounts.select { |account| account.account_type == "asset" && %w[1000 1010].include?(account.code) }
    @expense_accounts = @accounts.select { |account| account.account_type == "expense" }
    @cost_centers = CostCenter.active.includes(profit_center: :controlling_segment)
      .where(tenant_id: Current.tenant.id).order(:code)
    return unless document

    debit = document.document_lines.find { |line| line.amount_minor&.positive? }
    credit = document.document_lines.find { |line| line.amount_minor&.negative? }
    @draft_values = {
      posting_date: document.posting_date,
      narration: document.narration,
      amount: helpers.money_input_value(
        debit&.amount_minor, currency: debit&.currency || Current.tenant.functional_currency
      ),
      currency: debit&.currency,
      debit_account_code: debit&.account_code,
      credit_account_code: credit&.account_code,
      cost_center_id: debit&.extra.to_h.dig("controlling", "costCenterId")
    }
  end

  def voucher_params
    params.require(:journal_voucher).permit(
      :posting_date,
      :event_kind,
      :cash_account_code,
      :expense_account_code,
      :contributor,
      :narration,
      :debit_account_code,
      :credit_account_code,
      :amount,
      :currency,
      :cost_center_id
    )
  end

  def journal_attributes
    currency = voucher_params[:currency].presence || Current.tenant.functional_currency
    amount_minor = amount_minor!(voucher_params[:amount], currency)
    posting_date = Date.iso8601(voucher_params[:posting_date])
    event_kind = voucher_params[:event_kind].presence || "journal"

    debit_code, credit_code, narration = case event_kind
    when "owner_deposit"
      contributor = voucher_params[:contributor].to_s.strip
      raise ArgumentError, "Contributor name is required" if contributor.blank?

      [ account_scope.find_by!(code: voucher_params[:cash_account_code]).code,
        account_scope.find_by!(code: "3000").code,
        "Owner deposit by #{contributor}" ]
    when "expense"
      explanation = voucher_params[:narration].to_s.strip
      raise ArgumentError, "Expense explanation is required" if explanation.blank?

      [ account_scope.where(account_type: "expense").find_by!(code: voucher_params[:expense_account_code]).code,
        account_scope.find_by!(code: voucher_params[:cash_account_code]).code,
        explanation ]
    when "journal"
      [ account_scope.find_by!(code: voucher_params[:debit_account_code]).code,
        account_scope.find_by!(code: voucher_params[:credit_account_code]).code,
        voucher_params[:narration].to_s.strip ]
    else
      raise ArgumentError, "Choose a supported business event"
    end
    raise ArgumentError, "Debit and credit accounts must be different" if debit_code == credit_code
    raise ArgumentError, "Explanation is required" if narration.blank?
    raise ArgumentError, "Explanation may be no more than 200 characters" if narration.length > 200

    {
      posting_date: posting_date,
      narration: narration,
      lines: [
        { account_code: debit_code, amount_minor: amount_minor, currency: currency,
          extra: controlling_extra(posting_date) },
        { account_code: credit_code, amount_minor: -amount_minor, currency: currency }
      ]
    }
  rescue Date::Error
    raise ArgumentError, "Posting date must be a valid date"
  end

  def controlling_extra(posting_date)
    return if voucher_params[:cost_center_id].blank?

    center = CostCenter.includes(profit_center: :controlling_segment)
      .where(tenant_id: Current.tenant.id).find(voucher_params[:cost_center_id])
    { "controlling" => Controlling::Dimensions.snapshot(center, on: posting_date) }
  end

  def amount_minor!(raw_amount, currency)
    exponent = CurrencyProfile.exponent_for!(currency)
    amount = Documents::DecimalInput.parse!(
      raw_amount, label: "Amount", scale: exponent,
      minimum: BigDecimal("1") / (10**exponent), error_class: ArgumentError
    )
    (amount * (10**exponent)).to_i
  end
end
