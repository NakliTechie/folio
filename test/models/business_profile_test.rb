# frozen_string_literal: true

require "test_helper"

class BusinessProfileTest < ActiveSupport::TestCase
  setup do
    @org = Onboarding::SignUp.call(
      email: "business-profile-model@folio.invalid",
      password: "correct-horse-battery",
      org_name: "Business Profile Model"
    )
    @entity = Entity.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: @org.tenant.id, code: "PRIMARY")
  end

  test "managed company details require a complete address and append an audit event" do
    assert_difference -> { LedgerEvent.for_tenant(@org.tenant.id).count }, 1 do
      BusinessProfiles::Manage.update!(
        entity: @entity,
        office: @office,
        entity_attributes: { legal_name: "Example Services Private Limited" },
        office_attributes: {
          name: "Registered Office", address_line1: "1 Ledger Lane", city: "Mumbai",
          postal_code: "400001", state_code: "27", country_code: "in"
        },
        actor: @org.user
      )
    end

    assert_equal "Example Services Private Limited", @entity.reload.legal_name
    assert @office.reload.statutory_address_complete?
    assert_equal "IN", @office.country_code
    event = LedgerEvent.for_tenant(@org.tenant.id).in_order.last
    assert_equal "business_profile.updated", event.action
    assert LedgerEvent.verify_chain(@org.tenant.id)[:ok]
  end

  test "incomplete and invalid India addresses fail without partial updates" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      BusinessProfiles::Manage.update!(
        entity: @entity,
        office: @office,
        entity_attributes: { legal_name: "Should Roll Back" },
        office_attributes: {
          name: "Head Office", address_line1: "", city: "Mumbai",
          postal_code: "bad", state_code: "99", country_code: "IN"
        },
        actor: @org.user
      )
    end

    assert_match(/complete legal address/, error.message)
    assert_equal "Business Profile Model", @entity.reload.legal_name
    assert_nil @office.reload.address_line1
  end

  test "statutory number formatter is fiscal-year scoped and bounded" do
    type = DocumentType.find_by!(tenant_id: @org.tenant.id, code: "SI")
    document = Document.new(doc_type: "SI", fiscal_year: 2026, document_type: type)

    assert_equal "SI/26-27/00001", Documents::NumberFormatter.format(document, 1)
    assert_equal "SI/26-27/9999999", Documents::NumberFormatter.format(document, 9_999_999)
    assert_raises(Documents::InvalidDocument) do
      Documents::NumberFormatter.format(document, 10_000_000)
    end
  end
end
