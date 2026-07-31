# frozen_string_literal: true

# The authenticated overview: company context, setup progress, and the next useful action.
class HomeController < BrowserController
  def show
    @entity = Entity.find_by(tenant_id: Current.tenant.id, code: "PRIMARY")
    @accounts_count = Account.where(tenant_id: Current.tenant.id).count
    @accounts_by_type = Account.where(tenant_id: Current.tenant.id).in_code_order.group_by(&:account_type)
    @documents = Document.where(tenant_id: Current.tenant.id).order(created_at: :desc).limit(5)
    @posted_count = Document.where(tenant_id: Current.tenant.id, state: %w[posted reversed]).count
    @journal_posted_count = Document.where(
      tenant_id: Current.tenant.id, doc_type: "JV", state: %w[posted reversed]
    ).count
  end
end
