# frozen_string_literal: true

require "test_helper"
require "securerandom"

class PurchaseCreditNoteConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    token = SecureRandom.hex(8)
    @tenant = Tenant.create!(name: "Purchase Credit Race #{token}", slug: "purchase-credit-race-#{token}")
    spine = Onboarding::Seeds.org_spine!(@tenant)
    Onboarding::Seeds.chart_of_accounts!(@tenant)
    Onboarding::Seeds.document_types!(@tenant)
    entity = spine.fetch(:entity)
    office = spine.fetch(:office)
    office.update!(
      address_line1: "1 Ledger Lane", city: "Mumbai", postal_code: "400001",
      state_code: "27", country_code: "IN"
    )
    registration = TaxRegistration.create!(
      tenant_id: @tenant.id, entity: entity,
      kind: "GSTIN", identifier: "27AAPFU0939F1ZV", valid_from: Date.new(2026, 4, 1)
    )
    OfficeTaxRegistration.create!(tenant_id: @tenant.id, office: office, tax_registration: registration)
    vendor = Party.create!(
      tenant_id: @tenant.id, party_number: "V-001", name: "Acme", state_code: "27", country_code: "IN",
      address_line1: "2 Supplier Road", city: "Mumbai", postal_code: "400002"
    )
    PartyRole.create!(party: vendor, role: "vendor")
    PartyTaxRegistration.create!(
      tenant_id: @tenant.id, party: vendor, kind: "GSTIN",
      identifier: "27AAPFU0939F1ZV", valid_from: Date.new(2026, 4, 1)
    )
    service = Item.create!(
      tenant_id: @tenant.id,
      code: "LEGAL", name: "Legal services", item_type: "service", hsn_sac_code: "998211",
      unit_of_measure: "OTH", tax_rate_basis_points: 1800, cess_rate_basis_points: 0,
      income_account_code: "4000", expense_account_code: "5000"
    )
    @bill = PurchaseBills::BuildDraft.call(
      tenant: @tenant, party_id: vendor.id, tax_registration_id: registration.id,
      document_date: Date.new(2026, 7, 31), due_date: Date.new(2026, 8, 30),
      place_of_supply_state_code: "27", external_reference: "V-INV-001",
      lines: [ { item_id: service.id, quantity: "1", unit_price: "100.00" } ]
    )
    Documents::Post.call(@bill, actor: "setup")
  end

  test "competing full supplier credits serialize on the bill and only one posts" do
    notes = 2.times.map { |index| build_note(index) }
    outcomes = race(notes) do |note, index|
      Documents::Post.call(Document.find(note.id), actor: "thread:#{index}")
    end

    assert_equal 1, outcomes.count { |outcome| outcome.is_a?(Entry) }
    assert_equal [ Documents::InvalidDocument ], outcomes.grep(Exception).map(&:class)
    assert_equal 1, Document.where(tenant_id: @tenant.id, doc_type: "PC", state: "posted").count
    assert_equal 1, Document.where(tenant_id: @tenant.id, doc_type: "PC", state: "draft").count
    remaining = ActiveRecord::Base.uncached do
      PurchaseCreditNotes::BuildDraft.remaining_quantity(@bill.document_lines.first)
    end
    assert_equal 0.to_d, remaining
    assert_equal 2, NumberRange.find_by!(tenant_id: @tenant.id, doc_type: "PC").next_value
  end

  private

  def build_note(index)
    PurchaseCreditNotes::BuildDraft.call(
      tenant: @tenant, purchase_bill_id: @bill.id,
      document_date: Date.new(2026, 8, 1), external_reference: "V-CN-#{index + 1}",
      reason_code: "value_reduction",
      lines: [ { document_line_id: @bill.document_lines.first.id, quantity: "1" } ]
    )
  end

  def race(notes)
    ready = Queue.new
    start = Queue.new
    outcomes = Array.new(2)
    threads = notes.each_with_index.map do |note, index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          outcomes[index] = yield(note, index)
        rescue StandardError => e
          outcomes[index] = e
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }
    threads.each(&:join)
    outcomes
  end
end
