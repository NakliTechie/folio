# frozen_string_literal: true

require "bigdecimal"

module Folio
  module SampleBooks
    # Drives Folio's real domain services to post a whole scenario. Mirrors the call
    # pattern proven in test/models/settlement_test.rb — the same services a user's clicks
    # go through, so a seeded book exercises the true posting and regulatory paths.
    class Generator
      Result = Data.define(
        :scenario_code, :org_name, :tenant_id, :email, :password,
        :counts, :trial_balance_tied, :trial_balance_debit_minor, :trial_balance_credit_minor,
        :tds_previews
      ) do
        def balanced? = trial_balance_tied
      end

      def initialize(scenario:, email:, password:)
        @s = scenario
        @email = email
        @password = password
        @parties = {}   # ref  => Party record
        @items   = {}   # code => Item record
        @sales   = {}   # ref  => posted sales Document
        @purchases = {} # ref  => posted purchase Document
      end

      # Onboarding enforces a 15-char minimum password; fail fast with a clear message
      # rather than deep inside SignUp's validation.
      MIN_PASSWORD_LENGTH = 15

      def run
        if @password.to_s.length < MIN_PASSWORD_LENGTH
          raise Error, "password must be at least #{MIN_PASSWORD_LENGTH} characters"
        end

        sign_up
        configure_office
        register_gstin
        create_masters
        post_sales
        post_purchases
        settle
        build_result
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        raise Error, "seed failed (already seeded with this email? use a fresh one): #{e.message}"
      end

      private

      attr_reader :s

      def actor_string = "u:#{@user.id}"

      # A valid GSTIN for a state + PAN: <state><PAN><entity 1><Z> + mod-36 checksum. Built
      # rather than hardcoded so every seeded identifier passes Taxes::India::Gstin.valid?.
      def gstin_for(state_code, pan, entity_code = "1")
        base = "#{state_code}#{pan}#{entity_code}Z"
        base + Taxes::India::Gstin.checksum(base)
      end

      def sign_up
        org = Onboarding::SignUp.call(
          email: @email, password: @password, org_name: s.org_name,
          jurisdiction_profile: "IN", functional_currency: "INR", fiscal_year_variant: "IN_APR_MAR"
        )
        @user = org.user
        @tenant = org.tenant
        @entity = Entity.find_by!(tenant_id: @tenant.id, code: "PRIMARY")
        @office = Office.find_by!(tenant_id: @tenant.id, code: "PRIMARY")
      end

      def configure_office
        @office.update!(
          address_line1: "1 #{s.org_name} House", city: s.home_city,
          postal_code: s.home_postal_code, state_code: s.home_state, country_code: "IN"
        )
      end

      def register_gstin
        @registration = TaxRegistrations::Manage.create!(
          tenant: @tenant, entity: @entity,
          attributes: {
            kind: "GSTIN", identifier: gstin_for(s.home_state, s.company_pan),
            jurisdiction: s.home_jurisdiction, valid_from: Date.new(2026, 4, 1)
          },
          office_ids: [ @office.id ], actor: @user
        )
      end

      def create_masters
        s.customers.each { |c| @parties[c.ref] = create_party(c, "customer") }
        s.vendors.each   { |v| @parties[v.ref] = create_party(v, "vendor") }
        s.services.each do |svc|
          @items[svc.code] = Items::Manage.create!(
            tenant: @tenant,
            attributes: {
              code: svc.code, name: svc.name, item_type: "service",
              hsn_sac_code: svc.hsn_sac_code, unit_of_measure: "OTH",
              tax_rate_basis_points: svc.rate_basis_points, cess_rate_basis_points: 0,
              income_account_code: "4000", expense_account_code: "5000"
            },
            actor: @user
          )
        end
      end

      def create_party(party, role)
        Parties::Manage.create!(
          tenant: @tenant,
          attributes: {
            party_number: party.ref, name: party.name, state_code: party.state_code,
            country_code: "IN", address_line1: "1 #{party.name} Marg",
            city: party.city, postal_code: party.postal_code
          },
          roles: [ role ],
          tax_registration_attributes: {
            kind: "GSTIN", identifier: gstin_for(party.state_code, party.pan),
            valid_from: Date.new(2026, 4, 1)
          },
          actor: @user
        )
      end

      def post_sales
        s.sales.each do |sale|
          customer = @parties.fetch(sale.customer_ref)
          draft = SalesInvoices::BuildDraft.call(
            tenant: @tenant, party_id: customer.id, tax_registration_id: @registration.id,
            document_date: sale.date, due_date: sale.due_date,
            place_of_supply_state_code: customer.state_code,
            lines: [ { item_id: @items.fetch(sale.service_code).id,
                       quantity: sale.quantity, unit_price: sale.unit_price } ],
            narration: "#{@items.fetch(sale.service_code).name} — #{customer.name}"
          )
          Documents::Post.call(draft, actor: actor_string)
          @sales[sale.ref] = draft
        end
      end

      def post_purchases
        s.purchases.each do |purchase|
          vendor = @parties.fetch(purchase.vendor_ref)
          draft = PurchaseBills::BuildDraft.call(
            tenant: @tenant, party_id: vendor.id, tax_registration_id: @registration.id,
            document_date: purchase.date, due_date: purchase.due_date,
            place_of_supply_state_code: s.home_state, external_reference: purchase.supplier_ref,
            lines: [ { item_id: @items.fetch(purchase.service_code).id,
                       quantity: purchase.quantity, unit_price: purchase.unit_price } ],
            narration: "#{@items.fetch(purchase.service_code).name} — #{vendor.name}"
          )
          Documents::Post.call(draft, actor: actor_string)
          @purchases[purchase.ref] = draft
        end
      end

      def settle
        s.receipts.each do |r|
          target = open_item(@sales.fetch(r.sale_ref), "1200")
          post_settlement("RC", r.date, target, r.amount, r.mode)
        end
        s.payments.each do |p|
          target = open_item(@purchases.fetch(p.purchase_ref), "2000")
          post_settlement("PY", p.date, target, p.amount, p.mode)
        end
      end

      def post_settlement(doc_type, date, target, amount, mode)
        draft = Settlements::BuildDraft.call(
          tenant: @tenant, doc_type: doc_type, document_date: date, bank_account_code: "1010",
          narration: "#{doc_type == 'RC' ? 'Receipt' : 'Payment'} settlement",
          allocations: [ { target_entry_line_id: target.id, amount: amount, clearing_mode: mode } ]
        )
        Documents::Post.call(draft, actor: actor_string)
      end

      def open_item(document, account_code)
        EntryLine.joins(:entry).find_by!(entries: { document_id: document.id }, account_code: account_code)
      end

      # Preview what a TDS lifecycle WOULD withhold on each tagged purchase, using the
      # shipped kernel against real seeded amounts. Informational — the deduction leg is
      # not posted yet (TDS lifecycle is a later slice).
      def tds_previews
        s.purchases.filter_map do |purchase|
          next unless purchase.tds_section

          # The scenario struct carries the PAN (the persisted Party record does not).
          vendor = s.vendors.find { |v| v.ref == purchase.vendor_ref }
          taxable = (BigDecimal(purchase.unit_price) * 100).to_i * Integer(purchase.quantity)
          d = Taxes::India::Tds::Deduction.compute(
            section: purchase.tds_section, on: purchase.date,
            amount_minor: taxable, pan: vendor.pan
          )
          { purchase: purchase.ref, vendor: vendor.name, section: purchase.tds_section,
            taxable_minor: taxable, applied: d.applied,
            rate_basis_points: d.rate_basis_points, tds_minor: d.tds_minor }
        end
      end

      def build_result
        tb = Reports.trial_balance(@tenant.id)
        debit = tb.sum { |row| row.fetch("debit") }
        credit = tb.sum { |row| row.fetch("credit") }
        Result.new(
          scenario_code: s.code, org_name: s.org_name, tenant_id: @tenant.id,
          email: @email, password: @password,
          counts: {
            customers: s.customers.size, vendors: s.vendors.size, services: s.services.size,
            sales: @sales.size, purchases: @purchases.size,
            receipts: s.receipts.size, payments: s.payments.size
          },
          trial_balance_tied: debit == credit,
          trial_balance_debit_minor: debit, trial_balance_credit_minor: credit,
          tds_previews: tds_previews
        )
      end
    end
  end
end
