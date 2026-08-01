# frozen_string_literal: true

require "test_helper"

class SalesInvoiceTest < ActiveSupport::TestCase
  INVOICE_DATE = Date.new(2026, 7, 31)

  class FakeIrpProvider
    include Taxes::India::Gst::EInvoice::Provider::Contract

    attr_reader :generate_calls, :fetch_calls

    def initialize(generate_result: nil, generate_error: nil, fetch_result: nil)
      @generate_result = generate_result
      @generate_error = generate_error
      @fetch_result = fetch_result
      @generate_calls = 0
      @fetch_calls = 0
    end

    def name = "fake_irp"
    def configured? = true

    def generate_irn(payload:, request_id:)
      @generate_calls += 1
      raise @generate_error if @generate_error

      @generate_result
    end

    def fetch_by_document(seller_gstin:, document_type:, document_number:, document_date:)
      @fetch_calls += 1
      @fetch_result
    end
  end

  setup do
    @org = Onboarding::SignUp.call(
      email: "sales-invoice-model@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Sales Invoice Model"
    )
    @entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    @seller_registration = TaxRegistrations::Manage.create!(
      tenant: @org.tenant,
      entity: @entity,
      attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", jurisdiction: "IN-MH",
        valid_from: Date.new(2026, 4, 1)
      },
      office_ids: [ @office.id ],
      actor: @org.user
    )
    @customer = Parties::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        party_number: "C-001", name: "Acme Customer", state_code: "27", country_code: "IN",
        address_line1: "2 Customer Road", city: "Mumbai", postal_code: "400002"
      },
      roles: [ "customer" ],
      tax_registration_attributes: {
        kind: "GSTIN", identifier: "27AAPFU0939F1ZV", valid_from: Date.new(2026, 4, 1)
      },
      actor: @org.user
    )
    @service = Items::Manage.create!(
      tenant: @org.tenant,
      attributes: {
        code: "CONSULT", name: "Consulting services", item_type: "service",
        hsn_sac_code: "998311", unit_of_measure: "OTH", tax_rate_basis_points: 1800,
        cess_rate_basis_points: 0, income_account_code: "4000", expense_account_code: "5000"
      },
      actor: @org.user
    )
  end

  test "an intra-state service invoice freezes tax inputs and posts typed GST lines" do
    invoice = build_invoice

    assert_equal 10_000, invoice.subtotal_minor
    assert_equal 1_800, invoice.tax_minor
    assert_equal 11_800, invoice.total_minor
    assert_equal({ "cgst" => 900, "sgst" => 900 }, invoice.tax_breakdown)
    assert_equal "27AAPFU0939F1ZV", invoice.party_snapshot.fetch("gstin")
    assert_equal "998311", invoice.document_lines.first.item_snapshot.fetch("hsnSacCode")

    simulation = Documents::Simulate.call(invoice)
    assert simulation[:balanced]
    assert_equal 4, simulation[:lines].size

    entry = Documents::Post.call(invoice, actor: "u:#{@org.user.id}")
    assert_equal "SI/26-27/00001", invoice.reload.document_number
    assert_operator invoice.document_number.length, :<=, 16
    assert_equal "Sales Invoice Model", invoice.tax_registration_snapshot.fetch("legalName")
    assert_equal [ "1200", "4000", "2100", "2100" ], entry.entry_lines.order(:line_no).pluck(:account_code)

    receivable = entry.entry_lines.find_by!(account_code: "1200")
    assert receivable.open_item?
    assert_equal @customer.id, receivable.party_id
    assert_equal 11_800, receivable.amounts.find_by!(slot_role: "transaction").amount_minor

    revenue = entry.entry_lines.find_by!(account_code: "4000")
    assert_equal @service.id, revenue.item_id
    assert_equal "998311", revenue.hsn_sac_code
    assert_equal 10_000, revenue.taxable_amount_minor
    assert_equal(-10_000, revenue.amounts.find_by!(slot_role: "transaction").amount_minor)

    tax_lines = entry.entry_lines.where(account_code: "2100").order(:tax_component)
    assert_equal %w[cgst sgst], tax_lines.pluck(:tax_component)
    assert_equal [ 900, 900 ], tax_lines.pluck(:tax_rate_basis_points)
    assert_equal [ -900, -900 ], tax_lines.map { |line| line.amounts.find_by!(slot_role: "transaction").amount_minor }

    payload = JSON.parse(LedgerEvent.find(entry.ledger_event_id).payload)
    revenue_payload = payload.fetch("lines").find { |line| line["accountCode"] == "4000" }
    assert_equal @service.id, revenue_payload.fetch("itemId")
    assert_equal "998311", revenue_payload.fetch("hsnSacCode")
  end

  test "an inter-state invoice posts IGST instead of CGST and SGST" do
    invoice = build_invoice(place_of_supply_state_code: "29")
    assert_equal({ "igst" => 1_800 }, invoice.tax_breakdown)

    entry = Documents::Post.call(invoice, actor: "u:#{@org.user.id}")
    tax_line = entry.entry_lines.find_by!(account_code: "2100")
    assert_equal "igst", tax_line.tax_component
    assert_equal 1800, tax_line.tax_rate_basis_points
    assert_equal(-1_800, tax_line.amounts.find_by!(slot_role: "transaction").amount_minor)
  end

  test "posting rejects altered frozen tax before allocating a number" do
    invoice = build_invoice
    invoice.document_lines.first.update_column(:tax_components, { "cgst" => 800, "sgst" => 900 })

    error = assert_raises(Documents::InvalidDocument) do
      Documents::Post.call(invoice, actor: "u:#{@org.user.id}")
    end
    assert_match(/tax was altered/, error.message)
    assert_nil NumberRange.find_by(tenant_id: @org.tenant.id, doc_type: "SI")
    assert_equal "draft", invoice.reload.state
  end

  test "an unsupported odd component rate is rejected before draft persistence" do
    @service.update_column(:tax_rate_basis_points, 501)

    assert_no_difference "Document.count" do
      error = assert_raises(Taxes::InvalidTaxInput) { build_invoice }
      assert_match(/split exactly/, error.message)
    end
  end

  test "posting rejects altered invoice identity and price snapshots" do
    invoice = build_invoice
    invoice.update_column(:party_snapshot, invoice.party_snapshot.merge("id" => @customer.id + 1))

    error = assert_raises(Documents::InvalidDocument) do
      Documents::Post.call(invoice, actor: "u:#{@org.user.id}")
    end
    assert_match(/snapshots do not match/, error.message)

    invoice.update_column(:party_snapshot, invoice.party_snapshot.merge("id" => @customer.id))
    invoice.document_lines.first.update_column(:taxable_minor, 9_999)
    error = assert_raises(Documents::InvalidDocument) do
      Documents::Post.call(invoice.reload, actor: "u:#{@org.user.id}")
    end
    assert_match(/price or currency was altered/, error.message)
    assert_nil NumberRange.find_by(tenant_id: @org.tenant.id, doc_type: "SI")
  end

  test "the generic draft builder cannot bypass the specialized invoice contract" do
    error = assert_raises(Documents::InvalidDocument) do
      Documents::BuildDraft.call(
        tenant: @org.tenant, doc_type: "SI",
        document_date: INVOICE_DATE, posting_date: INVOICE_DATE,
        narration: nil,
        lines: [ { account_code: "1200", amount_minor: 100 }, { account_code: "4000", amount_minor: -100 } ]
      )
    end

    assert_match(/specialized endpoint/, error.message)
  end

  test "the first invoice vertical fails closed outside an India INR profile" do
    other = Onboarding::SignUp.call(
      email: "sales-invoice-us@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Sales Invoice US",
      jurisdiction_profile: "US",
      functional_currency: "USD",
      fiscal_year_variant: "CAL"
    )

    error = assert_raises(SalesInvoices::InvalidInvoice) do
      SalesInvoices::BuildDraft.call(
        tenant: other.tenant,
        party_id: 0,
        tax_registration_id: 0,
        document_date: INVOICE_DATE,
        due_date: INVOICE_DATE,
        place_of_supply_state_code: "27",
        lines: []
      )
    end
    assert_match(/India\/INR/, error.message)
  end

  test "an invoice cannot be issued before company legal address setup is complete" do
    @office.update_columns(address_line1: nil, city: nil, postal_code: nil, state_code: nil, country_code: nil)

    error = assert_raises(SalesInvoices::InvalidInvoice) { build_invoice }
    assert_match(/complete India company details/, error.message)
    assert_no_difference "Document.count" do
      assert_raises(SalesInvoices::InvalidInvoice) { build_invoice }
    end
  end

  test "a posted invoice reverses from snapshots after its masters are deactivated" do
    invoice = build_invoice
    Documents::Post.call(invoice, actor: "u:#{@org.user.id}")

    Parties::Manage.update!(
      party: @customer, attributes: { active: false }, roles: @customer.role_codes, actor: @org.user
    )
    Items::Manage.update!(item: @service, attributes: { active: false }, actor: @org.user)
    TaxRegistrations::Manage.update!(
      registration: @seller_registration, attributes: { active: false },
      office_ids: [ @office.id ], actor: @org.user
    )

    reversal_entry = Documents::Reverse.call(invoice, actor: "u:#{@org.user.id}")
    assert_equal "reversed", invoice.reload.state
    assert reversal_entry.entry_lines.all?(&:is_negative_posting)
    reversal_amounts = reversal_entry.entry_lines.order(:line_no).map do |line|
      line.amounts.find_by!(slot_role: "transaction").amount_minor
    end
    assert_equal [ -11_800, 10_000, 900, 900 ], reversal_amounts

    original_receivable = Entry.find(invoice.posted_entry_id).entry_lines.find_by!(account_code: "1200")
    assert_equal 11_800, original_receivable.cleared_amount_minor
    assert_equal reversal_entry.id, original_receivable.cleared_by_entry_id
    assert_equal INVOICE_DATE, original_receivable.cleared_on
  end

  test "a posted invoice remains reversible after projection rebuild" do
    invoice = build_invoice
    Documents::Post.call(invoice, actor: "u:#{@org.user.id}")
    old_entry_id = invoice.posted_entry_id

    Posting.rebuild!(@org.tenant.id)
    refute_equal old_entry_id, invoice.reload.posted_entry_id
    rebuilt_receivable = Entry.find(invoice.posted_entry_id).entry_lines.find_by!(account_code: "1200")

    reversal_entry = Documents::Reverse.call(invoice, actor: "u:#{@org.user.id}")

    assert_equal 11_800, rebuilt_receivable.reload.cleared_amount_minor
    assert_equal reversal_entry.id, rebuilt_receivable.cleared_by_entry_id
    assert_equal INVOICE_DATE, rebuilt_receivable.cleared_on
  end

  test "a partially settled invoice requires a credit note instead of reversal" do
    invoice = build_invoice
    Documents::Post.call(invoice, actor: "u:#{@org.user.id}")
    receivable = Entry.find(invoice.posted_entry_id).entry_lines.find_by!(account_code: "1200")
    Posting::Clearing.clear!(
      item: receivable, amount_minor: 1_000, cleared_on: INVOICE_DATE,
      mode: :partial, actor: "u:#{@org.user.id}"
    )
    documents_before = Document.where(tenant_id: @org.tenant.id).count

    error = assert_raises(Documents::Reverse::NotReversible) do
      Documents::Reverse.call(invoice, actor: "u:#{@org.user.id}")
    end
    assert_match(/credit note/, error.message)
    assert_equal "posted", invoice.reload.state
    assert_equal documents_before, Document.where(tenant_id: @org.tenant.id).count
  end

  test "a fully settled invoice cannot reverse into hidden receivables" do
    invoice = build_invoice
    entry = Documents::Post.call(invoice, actor: "u:#{@org.user.id}")
    receivable = entry.entry_lines.find_by!(account_code: "1200")
    Posting::Clearing.clear!(
      item: receivable, amount_minor: 11_800, cleared_on: INVOICE_DATE,
      mode: :full, actor: "u:#{@org.user.id}"
    )

    refute invoice.reload.reversible?
    assert_raises(Documents::Reverse::NotReversible) do
      Documents::Reverse.call(invoice, actor: "u:#{@org.user.id}")
    end
    assert_equal "posted", invoice.reload.state
    assert_equal 1, Document.where(tenant_id: @org.tenant.id, doc_type: "SI").count
  end

  test "INV-01 preparation is schema-valid idempotent and blocks ambiguous reversal" do
    invoice = build_invoice(place_of_supply_state_code: "29")
    Documents::Post.call(invoice, actor: "u:#{@org.user.id}")

    submission = nil
    assert_difference "EinvoiceSubmission.count", 1 do
      assert_difference -> { DomainEvent.where(tenant_id: @org.tenant.id, action: "einvoice.prepared").count }, 1 do
        submission = Taxes::India::Gst::EInvoice::Prepare.call(
          document: invoice,
          actor: "u:#{@org.user.id}",
          actor_user_id: @org.user.id
        )
      end
    end

    payload = submission.payload
    assert_equal "1.1", payload.fetch("Version")
    assert_equal "INV", payload.dig("DocDtls", "Typ")
    assert_equal "SI/26-27/00001", payload.dig("DocDtls", "No")
    assert_equal "27AAPFU0939F1ZV", payload.dig("SellerDtls", "Gstin")
    assert_equal "29", payload.dig("BuyerDtls", "Pos")
    assert_equal "Y", payload.dig("ItemList", 0, "IsServc")
    assert_equal 100, payload.dig("ItemList", 0, "AssAmt")
    assert_equal 18, payload.dig("ItemList", 0, "IgstAmt")
    assert_equal 118, payload.dig("ValDtls", "TotInvVal")
    assert_equal Taxes::India::Gst::EInvoice.canonical_digest(payload), submission.payload_sha256
    assert Taxes::India::Gst::EInvoice::Validator.validate!(payload)

    assert_no_difference [ "EinvoiceSubmission.count", "DomainEvent.count" ] do
      repeated = Taxes::India::Gst::EInvoice::Prepare.call(
        document: invoice, actor: "u:#{@org.user.id}", actor_user_id: @org.user.id
      )
      assert_equal submission.id, repeated.id
    end
    refute invoice.reload.reversible?
    assert_raises(Documents::Reverse::NotReversible) do
      Documents::Reverse.call(invoice, actor: "u:#{@org.user.id}")
    end

    mutated = payload.deep_dup
    mutated["DocDtls"]["No"] = "lowercase"
    assert_raises(Taxes::India::Gst::EInvoice::InvalidPayload) do
      Taxes::India::Gst::EInvoice::Validator.validate!(mutated)
    end
  end

  test "provider seam stores complete IRP acknowledgement artifacts exactly once" do
    invoice = build_invoice
    Documents::Post.call(invoice, actor: "u:#{@org.user.id}")
    submission = Taxes::India::Gst::EInvoice::Prepare.call(
      document: invoice, actor: "u:#{@org.user.id}", actor_user_id: @org.user.id
    )

    disabled = Taxes::India::Gst::EInvoice::Providers::Disabled.new
    assert_raises(Taxes::India::Gst::EInvoice::Provider::ConfigurationError) do
      Taxes::India::Gst::EInvoice::Submit.call(
        submission: submission, actor: "test", provider: disabled
      )
    end
    assert_equal "prepared", submission.reload.status
    assert_equal 0, submission.attempt_count

    acknowledgement = irp_acknowledgement
    provider = FakeIrpProvider.new(generate_result: acknowledgement)
    assert_difference -> { DomainEvent.where(action: "einvoice.acknowledged").count }, 1 do
      Taxes::India::Gst::EInvoice::Submit.call(
        submission: submission,
        actor: "u:#{@org.user.id}",
        actor_user_id: @org.user.id,
        provider: provider
      )
    end
    submission.reload
    assert_equal "acknowledged", submission.status
    assert_equal acknowledgement.irn, submission.irn
    assert_equal "signed-invoice-jws", submission.signed_invoice
    assert_equal "signed-qr-jws", submission.signed_qr_code
    assert_equal "provider_verified", submission.signature_status
    assert_equal 1, submission.attempt_count
    assert_equal 1, provider.generate_calls
    refute_includes DomainEvent.where(action: "einvoice.acknowledged").last.payload,
      "signed-invoice-jws"

    assert_raises(ActiveRecord::RecordInvalid) do
      submission.update!(irn: "b" * 64)
    end
    assert_equal acknowledgement.irn, submission.reload.irn

    assert_no_difference "DomainEvent.count" do
      Taxes::India::Gst::EInvoice::Submit.call(
        submission: submission, actor: "test", provider: provider
      )
    end
    assert_equal 1, provider.generate_calls
  end

  test "provider acknowledgements require a verified signature" do
    acknowledgement = irp_acknowledgement.with(signature_status: "not_checked")

    error = assert_raises(Taxes::India::Gst::EInvoice::InvalidPayload) do
      Taxes::India::Gst::EInvoice::Provider.validate_acknowledgement!(acknowledgement)
    end

    assert_match(/signature has not been verified/, error.message)
  end

  test "a transport ambiguity must reconcile by document identity before any retry" do
    invoice = build_invoice
    Documents::Post.call(invoice, actor: "u:#{@org.user.id}")
    submission = Taxes::India::Gst::EInvoice::Prepare.call(
      document: invoice, actor: "test", actor_user_id: @org.user.id
    )
    transport_error = Taxes::India::Gst::EInvoice::Provider::TransportError.new(
      "connection ended after request", code: "timeout"
    )
    provider = FakeIrpProvider.new(generate_error: transport_error)

    assert_raises(Taxes::India::Gst::EInvoice::Provider::TransportError) do
      Taxes::India::Gst::EInvoice::Submit.call(
        submission: submission, actor: "test", provider: provider
      )
    end
    assert_equal "indeterminate", submission.reload.status
    assert_equal 1, submission.attempt_count
    assert_equal 1, provider.generate_calls

    assert_raises(Taxes::India::Gst::EInvoice::Provider::Error) do
      Taxes::India::Gst::EInvoice::Submit.call(
        submission: submission, actor: "test", provider: provider
      )
    end
    assert_equal 1, provider.generate_calls

    reconciliation = FakeIrpProvider.new(fetch_result: irp_acknowledgement)
    Taxes::India::Gst::EInvoice::Reconcile.call(
      submission: submission, actor: "test", provider: reconciliation
    )
    assert_equal "acknowledged", submission.reload.status
    assert_equal 1, reconciliation.fetch_calls
  end

  test "an unexpected adapter failure is treated as an indeterminate IRP attempt" do
    invoice = build_invoice
    Documents::Post.call(invoice, actor: "u:#{@org.user.id}")
    submission = Taxes::India::Gst::EInvoice::Prepare.call(
      document: invoice, actor: "test", actor_user_id: @org.user.id
    )
    provider = FakeIrpProvider.new(generate_error: RuntimeError.new("adapter bug"))

    error = assert_raises(RuntimeError) do
      Taxes::India::Gst::EInvoice::Submit.call(
        submission: submission, actor: "test", provider: provider
      )
    end

    assert_equal "adapter bug", error.message
    assert_equal "indeterminate", submission.reload.status
    assert_equal 1, submission.attempt_count
    assert_equal 1, provider.generate_calls
    assert_match(/RuntimeError/, submission.error_message)
    assert_equal 1, DomainEvent.where(action: "einvoice.indeterminate").count
  end

  private

  def build_invoice(place_of_supply_state_code: "27")
    SalesInvoices::BuildDraft.call(
      tenant: @org.tenant,
      party_id: @customer.id,
      tax_registration_id: @seller_registration.id,
      document_date: INVOICE_DATE,
      due_date: INVOICE_DATE + 30,
      place_of_supply_state_code: place_of_supply_state_code,
      narration: "July consulting",
      lines: [ { item_id: @service.id, quantity: "2", unit_price: "50.00" } ]
    )
  end

  def irp_acknowledgement
    Taxes::India::Gst::EInvoice::Provider::Acknowledgement.new(
      irn: "a" * 64,
      ack_number: "112026000000001",
      acknowledged_at: Time.zone.parse("2026-07-31 12:00:00"),
      signed_invoice: "signed-invoice-jws",
      signed_qr_code: "signed-qr-jws",
      raw_response: {
        "Status" => 1,
        "Data" => { "Irn" => "a" * 64, "AckNo" => "112026000000001" }
      },
      signature_status: "provider_verified"
    )
  end
end
