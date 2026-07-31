# frozen_string_literal: true

require "test_helper"

# API.1 — the core JSON API, exercised for the security-critical paths: auth, per-endpoint
# tenant isolation, RBAC, balance, CSRF, and the full document lifecycle.
class Api::V1::DocumentsApiTest < ActionDispatch::IntegrationTest
  setup do
    @acme = Onboarding::SignUp.call(email: "acme@x.com", password: "correct-horse-battery", org_name: "Acme")
    @globex = Onboarding::SignUp.call(email: "globex@x.com", password: "correct-horse-battery", org_name: "Globex")
  end

  def jv_params(dr: 100_000)
    { doc_type: "JV", fiscal_year: 2025, document_date: "2025-06-01", posting_date: "2025-06-01",
      lines: [ { account_code: "1000", amount_minor: dr }, { account_code: "4000", amount_minor: -dr } ] }
  end

  def create_jv(**over)
    post "/api/v1/documents", params: jv_params(**over)
    JSON.parse(response.body).dig("document", "id")
  end

  test "unauthenticated API requests are 401" do
    get "/api/v1/reports/trial_balance"
    assert_response :unauthorized
    post "/api/v1/documents", params: jv_params
    assert_response :unauthorized
  end

  test "owner: create → simulate → post → trial balance over the API" do
    sign_in_as(@acme.user)
    id = create_jv
    assert_response :created
    document = Document.find(id)
    assert_equal Entity.find_by!(tenant_id: @acme.tenant.id, code: "PRIMARY").id, document.entity_id
    assert_equal Office.find_by!(tenant_id: @acme.tenant.id, code: "PRIMARY").id, document.office_id

    post "/api/v1/documents/#{id}/simulate"
    assert_response :success
    assert JSON.parse(response.body)["balanced"]

    post "/api/v1/documents/#{id}/post"
    assert_response :success
    assert_equal "posted", JSON.parse(response.body).dig("document", "state")
    assert_equal Ledger.find_by!(tenant_id: @acme.tenant.id, code: "PRIMARY").id,
      EntryLine.find_by!(tenant_id: @acme.tenant.id, entry_id: document.reload.posted_entry_id).ledger_id

    get "/api/v1/reports/trial_balance"
    tb = JSON.parse(response.body)["trial_balance"]
    assert_equal 100_000, tb.find { |r| r["name"] == "Cash" }["debit"]
  end

  test "an unbalanced post is 422" do
    sign_in_as(@acme.user)
    post "/api/v1/documents", params: jv_params.merge(
      lines: [ { account_code: "1000", amount_minor: 100_000 }, { account_code: "4000", amount_minor: -99_999 } ])
    id = JSON.parse(response.body).dig("document", "id")
    post "/api/v1/documents/#{id}/post"
    assert_response :unprocessable_entity
  end

  test "draft creation rejects empty zero invalid and fiscally inconsistent documents" do
    sign_in_as(@acme.user)

    assert_no_difference "Document.count" do
      post "/api/v1/documents", params: jv_params.merge(lines: [])
    end
    assert_response :unprocessable_entity
    assert_match(/at least two non-zero lines/, JSON.parse(response.body)["error"])

    assert_no_difference "Document.count" do
      post "/api/v1/documents", params: jv_params.merge(
        lines: [ { account_code: "1000", amount_minor: "not-a-number" },
                 { account_code: "4000", amount_minor: 0 } ]
      )
    end
    assert_response :unprocessable_entity
    assert_match(/must be an integer/, JSON.parse(response.body)["error"])

    assert_no_difference "Document.count" do
      post "/api/v1/documents", params: jv_params.merge(fiscal_year: 1999)
    end
    assert_response :unprocessable_entity
    assert_match(/does not match posting date/, JSON.parse(response.body)["error"])

    assert_no_difference "Document.count" do
      post "/api/v1/documents", params: jv_params.except(:posting_date)
    end
    assert_response :unprocessable_entity
    assert_match(/posting date must be a valid ISO date/, JSON.parse(response.body)["error"])
  end

  test "draft currency defaults to the tenant profile and rejects incompatible currency metadata" do
    usd = Onboarding::SignUp.call(
      email: "usd-books@x.com", password: "correct-horse-battery", org_name: "USD Books",
      jurisdiction_profile: "US", functional_currency: "USD", fiscal_year_variant: "CAL"
    )
    sign_out
    sign_in_as(usd.user)
    params = {
      doc_type: "JV", fiscal_year: 2026, document_date: "2026-06-01", posting_date: "2026-06-01",
      lines: [ { account_code: "1000", amount_minor: 100_000 },
               { account_code: "4000", amount_minor: -100_000 } ]
    }

    post "/api/v1/documents", params: params
    assert_response :created
    document = Document.find(JSON.parse(response.body).dig("document", "id"))
    assert_equal [ [ "USD", 2 ] ],
      document.document_lines.reorder(nil).distinct.pluck(:currency, :minor_unit_exponent)

    assert_no_difference "Document.count" do
      post "/api/v1/documents", params: params.merge(
        lines: [ { account_code: "1000", amount_minor: 100_000, currency: "INR", minor_unit_exponent: 0 },
                 { account_code: "4000", amount_minor: -100_000, currency: "INR", minor_unit_exponent: 0 } ]
      )
    end
    assert_response :unprocessable_entity
    assert_match(/must use USD with minor-unit exponent 2/, JSON.parse(response.body)["error"])
  end

  test "a closed period is a JSON 409 and leaves the document draft" do
    sign_in_as(@acme.user)
    id = create_jv
    entity = Entity.find_by!(tenant_id: @acme.tenant.id, code: "PRIMARY")
    ledger = Ledger.find_by!(tenant_id: @acme.tenant.id, code: "PRIMARY")
    PeriodControl.create!(tenant_id: @acme.tenant.id, entity_id: entity.id, ledger_id: ledger.id,
      account_class: "ALL", fiscal_year: 2025, period_no: 3, state: "closed", domain: "posting")

    post "/api/v1/documents/#{id}/post"

    assert_response :conflict
    assert_match(/period 2025\/3 is closed/, JSON.parse(response.body)["error"])
    assert_equal "draft", Document.find(id).state
  end

  test "a restricted period is a JSON 403 when the role lacks its capability" do
    sign_in_as(@acme.user)
    id = create_jv
    sign_out
    accountant = Onboarding::Invite.accept!(
      token: Onboarding::Invite.create!(tenant: @acme.tenant, email: "accountant@x.com",
        role_code: "accountant", invited_by: @acme.user).generate_token_for(:invite),
      password: "correct-horse-battery"
    )
    entity = Entity.find_by!(tenant_id: @acme.tenant.id, code: "PRIMARY")
    ledger = Ledger.find_by!(tenant_id: @acme.tenant.id, code: "PRIMARY")
    PeriodControl.create!(tenant_id: @acme.tenant.id, entity_id: entity.id, ledger_id: ledger.id,
      account_class: "ALL", fiscal_year: 2025, period_no: 3, state: "restricted",
      capability: "period.lock", domain: "posting")
    sign_in_as(accountant)

    post "/api/v1/documents/#{id}/post"

    assert_response :forbidden
    assert_match(/capability 'period.lock' required/, JSON.parse(response.body)["error"])
    assert_equal "draft", Document.find(id).state
  end

  test "ISOLATION — a user cannot read or post another tenant's document (404)" do
    sign_in_as(@acme.user)
    acme_id = create_jv
    sign_out

    sign_in_as(@globex.user)
    get "/api/v1/documents/#{acme_id}"
    assert_response :not_found
    post "/api/v1/documents/#{acme_id}/post"
    assert_response :not_found
    post "/api/v1/documents/#{acme_id}/reverse"
    assert_response :not_found
  end

  test "ISOLATION — each tenant's trial balance shows only its own postings" do
    sign_in_as(@acme.user)
    id = create_jv
    post "/api/v1/documents/#{id}/post"
    sign_out

    sign_in_as(@globex.user)
    get "/api/v1/reports/trial_balance"
    assert_equal [], JSON.parse(response.body)["trial_balance"], "Globex sees none of Acme's postings"
  end

  test "RBAC — an operator cannot create/post a voucher (403)" do
    op = Onboarding::Invite.accept!(
      token: Onboarding::Invite.create!(tenant: @acme.tenant, email: "op@x.com", role_code: "operator",
        invited_by: @acme.user).generate_token_for(:invite), password: "correct-horse-battery")
    sign_in_as(op)
    post "/api/v1/documents", params: jv_params
    assert_response :forbidden
  end

  test "masters are tenant-scoped; create needs accounts.manage" do
    sign_in_as(@acme.user)
    get "/api/v1/accounts"
    assert_includes JSON.parse(response.body)["accounts"].map { |a| a["code"] }, "1000"
    assert_difference -> { Account.where(tenant_id: @acme.tenant.id).count }, 1 do
      post "/api/v1/accounts", params: { code: "6000", name: "Rent", account_type: "expense" }
    end
    assert_response :created
    account = Account.find_by!(tenant_id: @acme.tenant.id, code: "6000")
    patch "/api/v1/accounts/#{account.id}", params: { name: "Premises rent", active: false }
    assert_response :success
    assert_equal false, JSON.parse(response.body).dig("account", "active")

    %w[2 10 AR].each do |code|
      post "/api/v1/accounts", params: { code: code, name: "Account #{code}", account_type: "asset" }
      assert_response :created
    end
    get "/api/v1/accounts"
    ordered_codes = JSON.parse(response.body)["accounts"].filter_map do |item|
      item["code"] if %w[2 10 AR].include?(item["code"])
    end
    assert_equal %w[2 10 AR], ordered_codes

    DocumentType.find_by!(tenant_id: @acme.tenant.id, code: "OB").update!(active: false)
    get "/api/v1/document_types"
    refute_includes JSON.parse(response.body)["document_types"].pluck("code"), "OB"
  end

  test "financial statement endpoints use dated versioned layouts" do
    sign_in_as(@acme.user)
    id = create_jv
    post "/api/v1/documents/#{id}/post"

    get "/api/v1/reports/profit_and_loss", params: { from: "2025-04-01", to: "2026-03-31" }
    assert_response :success
    profit = JSON.parse(response.body)["profit_and_loss"]
    assert_equal 100_000, profit["net_income_minor"]
    assert_equal 1, profit.dig("version", "version")

    get "/api/v1/reports/balance_sheet", params: { as_of: "2025-06-01" }
    assert_response :success
    balance = JSON.parse(response.body)["balance_sheet"]
    assert_equal 0, balance["difference_minor"]
  end

  test "a deactivated account cannot be posted through the generic document API" do
    sign_in_as(@acme.user)
    Account.find_by!(tenant_id: @acme.tenant.id, code: "1000").update!(active: false)

    post "/api/v1/documents", params: jv_params

    assert_response :unprocessable_entity
    assert_match(/account 1000 is unavailable/, JSON.parse(response.body)["error"])
  end

  test "reversal remains available after deactivation and preserves resolved authority" do
    sign_in_as(@acme.user)
    id = create_jv
    post "/api/v1/documents/#{id}/post"
    original = Document.find(id)
    Account.find_by!(tenant_id: @acme.tenant.id, code: "1000").update!(active: false)

    post "/api/v1/documents/#{id}/reverse"

    assert_response :success
    reversal = original.reload.reversed_by
    entry = Entry.find(reversal.posted_entry_id)
    assert_equal Rbac::Presets.role_for(@acme.tenant, "owner").id, entry.role_template_id
    assert entry.entry_lines.all?(&:is_negative_posting)
  end

  test "state-changing API writes are CSRF-protected" do
    sign_in_as(@acme.user)
    ActionController::Base.allow_forgery_protection = true
    post "/api/v1/documents", params: jv_params
    assert_response :unprocessable_entity, "a write without a CSRF token is blocked"
    assert_equal "invalid or missing CSRF token", JSON.parse(response.body)["error"], "and stays JSON"
  ensure
    ActionController::Base.allow_forgery_protection = false
  end
end
