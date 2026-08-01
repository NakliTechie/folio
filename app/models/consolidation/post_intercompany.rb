# frozen_string_literal: true

module Consolidation
  module PostIntercompany
    ACCOUNT_TYPES = {
      seller_receivable_account_code: "asset", seller_revenue_account_code: "income",
      buyer_expense_account_code: "expense", buyer_payable_account_code: "liability"
    }.freeze

    module_function

    def call(group:, actor:, attributes:)
      input = normalize!(group, attributes)
      authorize!(group, actor, input.fetch(:amount_minor))
      IntercompanyTransaction.transaction do
        LedgerEvent.acquire_tenant_lock!(group.tenant_id)
        existing = IntercompanyTransaction.find_by(
          tenant_id: group.tenant_id, idempotency_key: input.fetch(:idempotency_key)
        )
        return assert_same!(existing, input) if existing

        ledger = Ledger.find_by!(tenant_id: group.tenant_id, code: "PRIMARY")
        seller_office = Office.where(tenant_id: group.tenant_id, entity_id: input.fetch(:seller).id).first!
        buyer_office = Office.where(tenant_id: group.tenant_id, entity_id: input.fetch(:buyer).id).first!
        transaction_code = "IC/#{input.fetch(:posting_date).strftime('%Y%m%d')}/#{SecureRandom.hex(6).upcase}"
        entry = Posting::PostEntry.post!(
          tenant_id: group.tenant_id, actor: "u:#{actor.id}", actor_user_id: actor.id,
          origin: "folio.consolidation", document_date: input.fetch(:posting_date),
          posting_date: input.fetch(:posting_date), entered_at: Time.current,
          fiscal_year: Documents.fiscal_year(
            input.fetch(:posting_date), variant: input.fetch(:seller).fiscal_year_variant
          ),
          period_no: Documents.period_no(
            input.fetch(:posting_date), variant: input.fetch(:seller).fiscal_year_variant
          ),
          authority: Authorization.authority_for(user: actor, tenant_id: group.tenant_id),
          capabilities: capabilities(group, actor),
          lines: posting_lines(
            input, ledger: ledger, seller_office: seller_office,
            buyer_office: buyer_office, transaction_code: transaction_code
          )
        )
        IntercompanyTransaction.create!(
          tenant_id: group.tenant_id, consolidation_group: group,
          seller_entity: input.fetch(:seller), buyer_entity: input.fetch(:buyer), created_by: actor,
          ledger_event_id: entry.ledger_event_id, transaction_code: transaction_code,
          idempotency_key: input.fetch(:idempotency_key), request_sha256: input.fetch(:request_sha256),
          posting_date: input.fetch(:posting_date), currency: group.presentation_currency,
          amount_minor: input.fetch(:amount_minor), description: input.fetch(:description)
        )
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def normalize!(group, attributes)
      values = attributes.to_h.symbolize_keys
      date = parse_date(values[:posting_date])
      member_ids = group.consolidation_group_members.select { |member| member.effective_on?(date) }
        .map(&:entity_id)
      seller = Entity.where(tenant_id: group.tenant_id, id: member_ids).find(values[:seller_entity_id])
      buyer = Entity.where(tenant_id: group.tenant_id, id: member_ids).find(values[:buyer_entity_id])
      raise InvalidConsolidation, "seller and buyer must be different entities" if seller == buyer
      unless seller.fiscal_year_variant == buyer.fiscal_year_variant
        raise InvalidConsolidation, "intercompany posting requires aligned fiscal-year variants"
      end
      amount_minor = money_minor(values[:amount], group.presentation_currency)
      description = values[:description].to_s.strip
      key = values[:idempotency_key].to_s.strip
      raise InvalidConsolidation, "description is required" if description.blank?
      raise InvalidConsolidation, "idempotency key is required" if key.blank?
      accounts = ACCOUNT_TYPES.to_h do |attribute, type|
        code = values[attribute].to_s.strip
        account = Account.active.where(tenant_id: group.tenant_id, account_type: type).find_by(code: code)
        raise InvalidConsolidation, "choose an active #{type} account for #{attribute.to_s.humanize}" unless account
        [ attribute, code ]
      end
      payload = {
        "groupId" => group.id, "sellerEntityId" => seller.id, "buyerEntityId" => buyer.id,
        "postingDate" => date.to_s, "currency" => group.presentation_currency,
        "amountMinor" => amount_minor, "description" => description,
        "accounts" => accounts.transform_keys(&:to_s)
      }
      {
        seller: seller, buyer: buyer, posting_date: date, amount_minor: amount_minor,
        description: description, idempotency_key: key, accounts: accounts,
        request_sha256: Digest::SHA256.hexdigest(Folio::KhataHash.canonical_payload(payload))
      }
    rescue ActiveRecord::RecordNotFound
      raise InvalidConsolidation, "choose two entities from this consolidation group"
    end

    def posting_lines(input, ledger:, seller_office:, buyer_office:, transaction_code:)
      amount = input.fetch(:amount_minor)
      exponent = CurrencyProfile.exponent_for!(input.fetch(:seller).functional_currency)
      slot = ->(value) { [ { slot_role: "transaction", currency: input.fetch(:seller).functional_currency,
        minor_unit_exponent: exponent, amount_minor: value } ] }
      base = { ledger_id: ledger.id, posting_layer: "00", intercompany_transaction_id: transaction_code,
        extra: { "intercompanyDescription" => input.fetch(:description) } }
      seller = input.fetch(:seller)
      buyer = input.fetch(:buyer)
      accounts = input.fetch(:accounts)
      [
        base.merge(line_no: 1, account_code: accounts.fetch(:seller_receivable_account_code),
          entity_id: seller.id, office_id: seller_office.id, partner_entity_id: buyer.id,
          amounts: slot.call(amount)),
        base.merge(line_no: 2, account_code: accounts.fetch(:seller_revenue_account_code),
          entity_id: seller.id, office_id: seller_office.id, partner_entity_id: buyer.id,
          amounts: slot.call(-amount)),
        base.merge(line_no: 3, account_code: accounts.fetch(:buyer_expense_account_code),
          entity_id: buyer.id, office_id: buyer_office.id, partner_entity_id: seller.id,
          amounts: slot.call(amount)),
        base.merge(line_no: 4, account_code: accounts.fetch(:buyer_payable_account_code),
          entity_id: buyer.id, office_id: buyer_office.id, partner_entity_id: seller.id,
          amounts: slot.call(-amount))
      ]
    end

    def assert_same!(existing, input)
      return existing if existing.request_sha256 == input.fetch(:request_sha256)

      raise InvalidConsolidation, "the idempotency key already belongs to another intercompany transaction"
    end

    def authorize!(group, actor, amount_minor)
      return if Authorization.permits?(
        user: actor, tenant_id: group.tenant_id, capability: "consolidation.post",
        amount_minor: amount_minor
      )
      raise InvalidConsolidation, "not permitted to post this intercompany amount"
    end

    def capabilities(group, actor)
      Authorization.role_for(user: actor, tenant_id: group.tenant_id)
        .role_template.role_permissions.pluck(:capability)
    end

    def parse_date(value)
      return value if value.is_a?(Date)
      Date.iso8601(value.to_s)
    rescue Date::Error
      raise InvalidConsolidation, "posting date must be a valid ISO date"
    end

    def money_minor(value, currency)
      exponent = CurrencyProfile.exponent_for!(currency)
      amount = Documents::DecimalInput.parse!(
        value, label: "intercompany amount", scale: exponent, minimum: 0,
        error_class: InvalidConsolidation
      )
      minor = (amount * (10**exponent)).to_i
      raise InvalidConsolidation, "intercompany amount must be positive" unless minor.positive?
      minor
    end
  end
end
