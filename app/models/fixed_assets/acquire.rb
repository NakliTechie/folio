# frozen_string_literal: true

module FixedAssets
  module Acquire
    module_function

    def call(asset:, actor:, attributes:)
      input = normalize!(asset, attributes)
      authorize!(asset, actor, input.fetch(:amount_minor))

      FixedAsset.transaction do
        LedgerEvent.acquire_tenant_lock!(asset.tenant_id)
        existing = AssetTransaction.find_by(
          tenant_id: asset.tenant_id, idempotency_key: input.fetch(:idempotency_key),
          valuation_code: "BOOK"
        )
        return assert_same!(existing, input) if existing

        asset.lock!
        raise InvalidAsset, "only a draft asset can be acquired" unless asset.status == "draft"
        valuations = asset.asset_valuations.includes(:asset_valuation_term).order(:id).lock.to_a
        raise InvalidAsset, "asset must have BOOK and TAX_IT valuation terms" unless
          valuations.map(&:valuation_code).sort == AssetValuationTerm::CODES.sort
        if valuations.any? { |valuation| valuation.asset_valuation_term.residual_value_minor > input.fetch(:amount_minor) }
          raise InvalidAsset, "residual value cannot exceed acquisition cost"
        end

        book = valuations.find(&:posts_to_ledger?)
        event = post_book_acquisition!(asset, actor, input)
        valuations.each do |valuation|
          valuation.gross_block_minor += input.fetch(:amount_minor)
          valuation.save!
          AssetTransaction.create!(
            tenant_id: asset.tenant_id, fixed_asset: asset, asset_valuation: valuation,
            created_by: actor, ledger_event: (event if valuation.posts_to_ledger?),
            idempotency_key: input.fetch(:idempotency_key), transaction_type: "acquisition",
            valuation_code: valuation.valuation_code,
            asset_value_date: input.fetch(:asset_value_date), posting_date: input.fetch(:posting_date),
            amount_minor: input.fetch(:amount_minor), details: request_details(input)
          )
        end
        asset.update!(status: "active", acquired_on: input.fetch(:asset_value_date))
        DomainEvents::Record.call(
          tenant_id: asset.tenant_id, office_id: asset.office_id, kind: "asset.acquired",
          actor: "u:#{actor.id}", actor_user_id: actor.id, ref: asset.identity,
          payload: FixedAssets.snapshot(asset).merge(
            "amountMinor" => input.fetch(:amount_minor),
            "assetValueDate" => input.fetch(:asset_value_date).to_s,
            "ledgerEventId" => event.id, "bookValuationId" => book.id
          )
        )
        AssetTransaction.find_by!(
          tenant_id: asset.tenant_id, idempotency_key: input.fetch(:idempotency_key),
          valuation_code: "BOOK"
        )
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def normalize!(asset, attributes)
      exponent = CurrencyProfile.exponent_for!(asset.entity.functional_currency)
      amount = Documents::DecimalInput.parse!(
        value(attributes, :amount), label: "acquisition amount", scale: exponent,
        error_class: InvalidAsset
      )
      amount_minor = (amount * (10**exponent)).to_i
      raise InvalidAsset, "acquisition amount must be positive" unless amount_minor.positive?
      input = {
        amount_minor: amount_minor,
        offset_account_code: value(attributes, :offset_account_code).to_s.strip,
        asset_value_date: parse_date(value(attributes, :asset_value_date), "asset value date"),
        posting_date: parse_date(value(attributes, :posting_date), "posting date"),
        idempotency_key: value(attributes, :idempotency_key).to_s.strip,
        external_reference: value(attributes, :external_reference).to_s.strip.presence
      }
      raise InvalidAsset, "idempotency key is required" if input[:idempotency_key].blank?
      input[:request_sha256] = Digest::SHA256.hexdigest(
        Folio::KhataHash.canonical_payload(request_details(input))
      )
      input
    end

    def post_book_acquisition!(asset, actor, input)
      account = Account.active.find_by(
        tenant_id: asset.tenant_id, code: input.fetch(:offset_account_code)
      )
      unless account && account.code != asset.asset_class.apc_account_code
        raise InvalidAsset, "choose an active offset account different from the asset account"
      end
      ledger = Ledger.find_by!(tenant_id: asset.tenant_id, code: "PRIMARY")
      amount = input.fetch(:amount_minor)
      common = line_common(asset, ledger, input.fetch(:asset_value_date), "BOOK")
      post!(asset, actor, input.fetch(:posting_date), [
        common.merge(line_no: 1, account_code: asset.asset_class.apc_account_code,
          amounts: [ amount_hash(asset, amount) ]),
        common.except(:fixed_asset_id, :asset_value_date, :valuation_view).merge(
          line_no: 2, account_code: account.code, amounts: [ amount_hash(asset, -amount) ]
        )
      ], "folio.fixed_assets.acquisition")
    end

    def post!(asset, actor, date, lines, origin)
      Posting::PostEntry.post!(
        tenant_id: asset.tenant_id, entity_id: asset.entity_id, office_id: asset.office_id,
        actor: "u:#{actor.id}", actor_user_id: actor.id, origin: origin,
        document_date: date, posting_date: date, entered_at: Time.current,
        fiscal_year: Documents.fiscal_year(date, variant: asset.entity.fiscal_year_variant),
        period_no: Documents.period_no(date, variant: asset.entity.fiscal_year_variant),
        authority: Authorization.authority_for(
          user: actor, tenant_id: asset.tenant_id, office_id: asset.office_id
        ), capabilities: capabilities_for(asset, actor), lines: lines
      ).then { |entry| LedgerEvent.find(entry.ledger_event_id) }
    end

    def line_common(asset, ledger, value_date, view)
      {
        ledger_id: ledger.id, entity_id: asset.entity_id, office_id: asset.office_id,
        fixed_asset_id: asset.id, asset_value_date: value_date, valuation_view: view,
        extra: FixedAssets.snapshot(asset)
      }
    end

    def amount_hash(asset, amount)
      {
        slot_role: "transaction", currency: asset.entity.functional_currency,
        minor_unit_exponent: CurrencyProfile.exponent_for!(asset.entity.functional_currency),
        amount_minor: amount
      }
    end

    def request_details(input)
      {
        "amountMinor" => input.fetch(:amount_minor),
        "offsetAccountCode" => input.fetch(:offset_account_code),
        "assetValueDate" => input.fetch(:asset_value_date).to_s,
        "postingDate" => input.fetch(:posting_date).to_s,
        "externalReference" => input[:external_reference]
      }.compact
    end

    def assert_same!(existing, input)
      return existing if Digest::SHA256.hexdigest(
        Folio::KhataHash.canonical_payload(existing.details)
      ) == input.fetch(:request_sha256)

      raise InvalidAsset, "the idempotency key already belongs to another asset acquisition"
    end

    def authorize!(asset, actor, amount)
      return if Authorization.permits?(
        user: actor, tenant_id: asset.tenant_id, office_id: asset.office_id,
        capability: "assets.post", amount_minor: amount
      )

      raise InvalidAsset, "not permitted to post fixed-asset transactions"
    end

    def capabilities_for(asset, actor)
      Authorization.role_for(user: actor, tenant_id: asset.tenant_id, office_id: asset.office_id)
        &.role_template&.role_permissions&.pluck(:capability) || []
    end

    def parse_date(raw, label)
      return raw if raw.is_a?(Date)

      Date.iso8601(raw.to_s)
    rescue Date::Error
      raise InvalidAsset, "#{label} must be a valid ISO date"
    end

    def value(attributes, key)
      attributes[key] || attributes[key.to_s]
    end
  end
end
