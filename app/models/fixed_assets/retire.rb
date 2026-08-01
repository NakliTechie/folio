# frozen_string_literal: true

module FixedAssets
  # Retires a complete component asset and clears its BOOK carrying amount. Partial
  # retirements are intentionally out of scope: components are the unit of retirement.
  module Retire
    module_function

    def call(asset:, actor:, attributes:)
      input = normalize!(asset, attributes)
      authorize!(asset, actor)

      FixedAsset.transaction do
        LedgerEvent.acquire_tenant_lock!(asset.tenant_id)
        existing = AssetTransaction.find_by(
          tenant_id: asset.tenant_id, idempotency_key: input.fetch(:idempotency_key),
          valuation_code: "BOOK"
        )
        return assert_same!(existing, input) if existing

        asset.lock!
        raise InvalidAsset, "only an active asset can be retired" unless asset.status == "active"

        valuations = asset.asset_valuations.includes(:asset_valuation_term).order(:id).lock.to_a
        assert_depreciated_through!(valuations, input.fetch(:retirement_date))
        book = valuations.find(&:posts_to_ledger?)
        book_net_value = book.net_book_value_minor
        event = post_book_retirement!(asset, book, actor, input)
        valuations.each do |valuation|
          details = request_details(input).merge(
            "grossBlockMinor" => valuation.gross_block_minor,
            "accumulatedDepreciationMinor" => valuation.accumulated_depreciation_minor,
            "netBookValueMinor" => valuation.net_book_value_minor
          )
          AssetTransaction.create!(
            tenant_id: asset.tenant_id, fixed_asset: asset, asset_valuation: valuation,
            created_by: actor, ledger_event: (event if valuation.posts_to_ledger?),
            idempotency_key: input.fetch(:idempotency_key), transaction_type: "retirement",
            valuation_code: valuation.valuation_code,
            asset_value_date: input.fetch(:retirement_date),
            posting_date: input.fetch(:posting_date), amount_minor: valuation.gross_block_minor,
            details: details
          )
          valuation.update!(gross_block_minor: 0, accumulated_depreciation_minor: 0)
        end
        asset.update!(status: "retired", retired_on: input.fetch(:retirement_date))
        DomainEvents::Record.call(
          tenant_id: asset.tenant_id, office_id: asset.office_id, kind: "asset.retired",
          actor: "u:#{actor.id}", actor_user_id: actor.id, ref: asset.identity,
          payload: FixedAssets.snapshot(asset).merge(
            "retiredOn" => input.fetch(:retirement_date).to_s,
            "proceedsMinor" => input.fetch(:proceeds_minor),
            "bookNetValueMinor" => book_net_value,
            "ledgerEventId" => event.id, "reason" => input.fetch(:reason)
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
      proceeds = Documents::DecimalInput.parse!(
        value(attributes, :proceeds), label: "retirement proceeds", scale: exponent,
        minimum: 0, error_class: InvalidAsset
      )
      date = parse_date(value(attributes, :retirement_date), "retirement date")

      input = {
        retirement_date: date, posting_date: date,
        proceeds_minor: (proceeds * (10**exponent)).to_i,
        proceeds_account_code: value(attributes, :proceeds_account_code).to_s.strip.presence,
        reason: value(attributes, :reason).to_s.strip,
        idempotency_key: value(attributes, :idempotency_key).to_s.strip
      }
      raise InvalidAsset, "reason is required" if input[:reason].blank?
      raise InvalidAsset, "idempotency key is required" if input[:idempotency_key].blank?
      if input[:proceeds_minor].positive? && input[:proceeds_account_code].blank?
        raise InvalidAsset, "choose an account for retirement proceeds"
      end
      input[:request_sha256] = Digest::SHA256.hexdigest(
        Folio::KhataHash.canonical_payload(request_details(input))
      )
      input
    end

    def assert_depreciated_through!(valuations, date)
      stale = valuations.find do |valuation|
        latest_value_date = valuation.asset_transactions.maximum(:asset_value_date)
        latest_value_date && (latest_value_date > date || Depreciation.delta(valuation, date).positive?)
      end
      return unless stale

      raise InvalidAsset,
        "run depreciation through #{date} for #{stale.valuation_code} before retirement"
    end

    def post_book_retirement!(asset, book, actor, input)
      klass = asset.asset_class
      proceeds_account = if input.fetch(:proceeds_minor).positive?
        Account.active.where(tenant_id: asset.tenant_id, account_type: "asset")
          .find_by(code: input.fetch(:proceeds_account_code))
      end
      if input.fetch(:proceeds_minor).positive? && !proceeds_account
        raise InvalidAsset, "choose an active asset account for retirement proceeds"
      end
      if proceeds_account && [ klass.apc_account_code,
                               klass.accumulated_depreciation_account_code ].include?(proceeds_account.code)
        raise InvalidAsset, "retirement proceeds need an asset account outside the retired asset class"
      end

      ledger = Ledger.find_by!(tenant_id: asset.tenant_id, code: "PRIMARY")
      common = Acquire.line_common(asset, ledger, input.fetch(:retirement_date), "BOOK")
      plain = common.except(:fixed_asset_id, :asset_value_date, :valuation_view)
      lines = []
      add_line(lines, common, klass.accumulated_depreciation_account_code,
        book.accumulated_depreciation_minor, asset)
      add_line(lines, plain, proceeds_account&.code, input.fetch(:proceeds_minor), asset)
      add_line(lines, common, klass.apc_account_code, -book.gross_block_minor, asset)
      gain_loss = input.fetch(:proceeds_minor) - book.net_book_value_minor
      if gain_loss.positive?
        add_line(lines, plain, klass.gain_account_code, -gain_loss, asset)
      elsif gain_loss.negative?
        add_line(lines, plain, klass.loss_account_code, -gain_loss, asset)
      end
      Acquire.post!(
        asset, actor, input.fetch(:posting_date), lines,
        "folio.fixed_assets.retirement"
      )
    end

    def add_line(lines, common, account_code, amount_minor, asset)
      return if amount_minor.zero?

      lines << common.merge(
        line_no: lines.size + 1, account_code: account_code,
        amounts: [ Acquire.amount_hash(asset, amount_minor) ]
      )
    end

    def request_details(input)
      {
        "retirementDate" => input.fetch(:retirement_date).to_s,
        "postingDate" => input.fetch(:posting_date).to_s,
        "proceedsMinor" => input.fetch(:proceeds_minor),
        "proceedsAccountCode" => input[:proceeds_account_code],
        "reason" => input.fetch(:reason)
      }.compact
    end

    def assert_same!(existing, input)
      stored = existing.details.slice(*request_details(input).keys)
      return existing if Digest::SHA256.hexdigest(Folio::KhataHash.canonical_payload(stored)) ==
        input.fetch(:request_sha256)

      raise InvalidAsset, "the idempotency key already belongs to another asset retirement"
    end

    def authorize!(asset, actor)
      return if Authorization.permits?(
        user: actor, tenant_id: asset.tenant_id, office_id: asset.office_id,
        capability: "assets.post", amount_minor: asset.asset_valuations.maximum(:gross_block_minor)
      )

      raise InvalidAsset, "not permitted to retire this fixed asset"
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
