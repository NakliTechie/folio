# frozen_string_literal: true

class BankReconciliationsController < BrowserController
  before_action -> { require_capability!("banking.read") }, only: %i[index show]
  before_action -> { require_capability!("banking.manage") }, only: :import_statement
  before_action -> { require_capability!("banking.reconcile") },
    only: %i[auto_match manual_match ignore_line finalize]
  before_action :load_statement, only: %i[show auto_match manual_match ignore_line finalize]

  def index
    load_index
  end

  def show
    @lines = @statement.bank_statement_lines.in_statement_order
    @candidates_by_line = if permitted?("banking.reconcile") && @statement.status == "imported"
      @lines.where(status: "unmatched").index_with do |line|
        Banking::Reconcile.candidates_for(line).limit(20).to_a
      end
    else
      {}
    end
  end

  def import_statement
    upload = params.require(:statement_file)
    unless upload.respond_to?(:read)
      raise Banking::InvalidStatement, "choose a CSV bank statement"
    end
    if upload.respond_to?(:size) && upload.size.to_i > Banking::ImportStatement::MAX_BYTES
      raise Banking::InvalidStatement, "bank statement exceeds 5 MB"
    end

    statement = Banking::ImportStatement.call(
      tenant: Current.tenant, actor: Current.user,
      bank_account_code: params.require(:bank_account_code),
      currency: params.require(:currency),
      opening_balance: params.require(:opening_balance),
      closing_balance: params.require(:closing_balance),
      file_name: upload.original_filename, csv_text: upload.read
    )
    redirect_to bank_reconciliation_path(statement, tenant_route_options),
      notice: "Statement imported with #{statement.row_count} lines."
  rescue ActionController::ParameterMissing, Banking::InvalidStatement, ActiveRecord::RecordInvalid => e
    load_index
    flash.now[:alert] = e.message
    render :index, status: :unprocessable_entity
  end

  def auto_match
    count = Banking::Reconcile.auto_match!(statement: @statement, actor: Current.user)
    redirect_to bank_reconciliation_path(@statement, tenant_route_options),
      notice: "#{count} unambiguous #{'line'.pluralize(count)} matched."
  rescue Banking::InvalidStatement, ActiveRecord::RecordInvalid => e
    redirect_to bank_reconciliation_path(@statement, tenant_route_options), alert: e.message
  end

  def manual_match
    line = statement_line
    entry_line = EntryLine.joins(:entry).where(tenant_id: Current.tenant.id)
      .find(params.require(:entry_line_id))
    Banking::Reconcile.manual_match!(line: line, entry_line: entry_line, actor: Current.user)
    redirect_to bank_reconciliation_path(@statement, tenant_route_options),
      notice: "Statement line #{line.line_no} matched."
  rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound,
         ActiveRecord::RecordInvalid, Banking::InvalidStatement => e
    redirect_to bank_reconciliation_path(@statement, tenant_route_options), alert: e.message
  end

  def ignore_line
    line = statement_line
    Banking::Reconcile.ignore!(line: line, actor: Current.user, reason: params.require(:reason))
    redirect_to bank_reconciliation_path(@statement, tenant_route_options),
      notice: "Statement line #{line.line_no} excluded with evidence."
  rescue ActionController::ParameterMissing, ActiveRecord::RecordInvalid,
         Banking::InvalidStatement => e
    redirect_to bank_reconciliation_path(@statement, tenant_route_options), alert: e.message
  end

  def finalize
    Banking::Reconcile.finalize!(statement: @statement, actor: Current.user)
    redirect_to bank_reconciliation_path(@statement, tenant_route_options),
      notice: "Statement reconciled and closed."
  rescue ActiveRecord::RecordInvalid, Banking::InvalidStatement => e
    redirect_to bank_reconciliation_path(@statement, tenant_route_options), alert: e.message
  end

  private

  def load_index
    @statements = BankStatementImport.where(tenant_id: Current.tenant.id).recent_first.limit(100)
    @bank_accounts = Account.active.where(
      tenant_id: Current.tenant.id, account_type: "asset", monetary: true
    ).in_code_order
  end

  def load_statement
    @statement = BankStatementImport.where(tenant_id: Current.tenant.id).find(params[:id])
  end

  def statement_line
    @statement.bank_statement_lines.find(params.require(:line_id))
  end
end
