# frozen_string_literal: true

module FixedAssets
  module RunDepreciation
    module_function

    def call(tenant:, actor:, attributes:)
      input = normalize!(attributes)
      entity = Entity.find_by!(tenant_id: tenant.id, code: "PRIMARY")
      office = Office.find_by!(tenant_id: tenant.id, entity_id: entity.id, code: "PRIMARY")
      authorize!(tenant, office, actor)

      DepreciationRun.transaction do
        LedgerEvent.acquire_tenant_lock!(tenant.id)
        existing = DepreciationRun.find_by(
          tenant_id: tenant.id, idempotency_key: input.fetch(:idempotency_key)
        )
        return assert_same!(existing, input) if existing

        rows = valuation_rows(tenant, input.fetch(:through_date))
        run = DepreciationRun.create!(
          tenant_id: tenant.id, entity: entity, office: office, created_by: actor,
          idempotency_key: input.fetch(:idempotency_key), request_sha256: input.fetch(:request_sha256),
          mode: input.fetch(:mode), status: input.fetch(:mode) == "post" ? "posted" : "simulated",
          through_date: input.fetch(:through_date), posting_date: input.fetch(:posting_date),
          result: result(rows)
        )
        post_rows!(run, rows, actor) if run.mode == "post"
        run
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def normalize!(attributes)
      input = {
        through_date: parse_date(value(attributes, :through_date), "through date"),
        posting_date: parse_date(value(attributes, :posting_date), "posting date"),
        mode: value(attributes, :mode).to_s,
        idempotency_key: value(attributes, :idempotency_key).to_s.strip
      }
      raise InvalidAsset, "mode must be simulate or post" unless %w[simulate post].include?(input[:mode])
      raise InvalidAsset, "idempotency key is required" if input[:idempotency_key].blank?
      input[:request_sha256] = Digest::SHA256.hexdigest(
        Folio::KhataHash.canonical_payload(input.except(:request_sha256).transform_values(&:to_s))
      )
      input
    end

    def valuation_rows(tenant, through_date)
      AssetValuation.joins(:fixed_asset).includes(:asset_valuation_term, fixed_asset: :asset_class)
        .where(tenant_id: tenant.id, fixed_assets: { status: "active" }).order(:fixed_asset_id, :id)
        .map do |valuation|
          {
            valuation: valuation,
            fixed_asset: valuation.fixed_asset,
            delta_minor: Depreciation.delta(valuation, through_date)
          }
        end
        .select { |row| row.fetch(:delta_minor).positive? }
    end

    def post_rows!(run, rows, actor)
      rows.each do |row|
        valuation = row.fetch(:valuation)
        valuation.lock!
        delta = Depreciation.delta(valuation, run.through_date)
        next unless delta.positive?

        event = post_book!(run, valuation, actor, delta) if valuation.posts_to_ledger?
        AssetTransaction.create!(
          tenant_id: run.tenant_id, fixed_asset: valuation.fixed_asset,
          asset_valuation: valuation, depreciation_run: run, created_by: actor,
          ledger_event: event, idempotency_key: "#{run.idempotency_key}:#{valuation.fixed_asset_id}",
          transaction_type: "depreciation", valuation_code: valuation.valuation_code,
          asset_value_date: run.through_date, posting_date: run.posting_date, amount_minor: delta,
          details: {
            "throughDate" => run.through_date.to_s,
            "method" => valuation.asset_valuation_term.depreciation_method,
            "cumulativeTargetMinor" => valuation.accumulated_depreciation_minor + delta
          }
        )
        valuation.accumulated_depreciation_minor += delta
        valuation.depreciation_posted_through = run.through_date
        valuation.save!
      end
    end

    def post_book!(run, valuation, actor, delta)
      asset = valuation.fixed_asset
      ledger = Ledger.find_by!(tenant_id: run.tenant_id, code: "PRIMARY")
      klass = asset.asset_class
      common = {
        ledger_id: ledger.id, entity_id: asset.entity_id, office_id: asset.office_id,
        fixed_asset_id: asset.id, asset_value_date: run.through_date,
        valuation_view: valuation.valuation_code, extra: FixedAssets.snapshot(asset)
      }
      amount = lambda do |minor|
        [ {
          slot_role: "transaction", currency: asset.entity.functional_currency,
          minor_unit_exponent: CurrencyProfile.exponent_for!(asset.entity.functional_currency),
          amount_minor: minor
        } ]
      end
      entry = Posting::PostEntry.post!(
        tenant_id: run.tenant_id, entity_id: asset.entity_id, office_id: asset.office_id,
        actor: "u:#{actor.id}", actor_user_id: actor.id, origin: "folio.fixed_assets.depreciation",
        document_date: run.posting_date, posting_date: run.posting_date, entered_at: Time.current,
        fiscal_year: Documents.fiscal_year(
          run.posting_date, variant: asset.entity.fiscal_year_variant
        ),
        period_no: Documents.period_no(
          run.posting_date, variant: asset.entity.fiscal_year_variant
        ),
        authority: Authorization.authority_for(
          user: actor, tenant_id: run.tenant_id, office_id: asset.office_id
        ), capabilities: capabilities_for(asset, actor),
        lines: [
          common.merge(line_no: 1, account_code: klass.depreciation_expense_account_code,
            amounts: amount.call(delta)),
          common.merge(line_no: 2, account_code: klass.accumulated_depreciation_account_code,
            amounts: amount.call(-delta))
        ]
      )
      LedgerEvent.find(entry.ledger_event_id)
    end

    def result(rows)
      details = rows.map do |row|
        valuation = row.fetch(:valuation)
        {
          "assetId" => valuation.fixed_asset_id,
          "assetIdentity" => valuation.fixed_asset.identity,
          "valuationCode" => valuation.valuation_code,
          "postsToLedger" => valuation.posts_to_ledger,
          "deltaMinor" => row.fetch(:delta_minor)
        }
      end
      {
        "valuationCount" => details.size,
        "assetCount" => details.pluck("assetId").uniq.size,
        "ledgerAmountMinor" => details.select { |row| row.fetch("postsToLedger") }.sum { |row| row.fetch("deltaMinor") },
        "valuations" => details
      }
    end

    def assert_same!(existing, input)
      return existing if existing.request_sha256 == input.fetch(:request_sha256)

      raise InvalidAsset, "the idempotency key already belongs to another depreciation run"
    end

    def authorize!(tenant, office, actor)
      return if Authorization.permits?(
        user: actor, tenant_id: tenant.id, office_id: office.id, capability: "assets.post"
      )

      raise InvalidAsset, "not permitted to run depreciation"
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
