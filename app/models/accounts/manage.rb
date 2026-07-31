# frozen_string_literal: true

module Accounts
  # The only product write path for account-master changes. It keeps statement mappings in sync
  # and appends an immutable, hash-chained audit event in the same transaction as the mutation.
  module Manage
    AUDITED_FIELDS = %w[code name account_type active].freeze

    module_function

    def create!(tenant:, attributes:, actor:)
      Account.transaction do
        account = Account.create!(attributes.merge(tenant_id: tenant.id))
        FinancialStatements::DefaultLayout.assign!(account)
        append_event!(account, action: "account.created", actor: actor,
          changes: account.attributes.slice(*AUDITED_FIELDS).transform_values { |value| { "to" => value } })
        account
      end
    end

    def update!(account:, attributes:, actor:)
      Account.transaction do
        account.lock!
        account.assign_attributes(attributes)
        changes = account.changes.slice(*AUDITED_FIELDS).transform_values do |before, after|
          { "from" => before, "to" => after }
        end
        return account if changes.empty?

        account.save!
        FinancialStatements::DefaultLayout.assign!(account) if changes.key?("account_type")
        action = if changes.dig("active", "to") == false
          "account.deactivated"
        elsif changes.dig("active", "to") == true
          "account.reactivated"
        else
          "account.updated"
        end
        append_event!(account, action: action, actor: actor, changes: changes)
        account
      end
    end

    def append_event!(account, action:, actor:, changes:)
      timestamp = Time.current.iso8601(6)
      payload = {
        "account" => {
          "id" => account.id,
          "code" => account.code,
          "name" => account.name,
          "accountType" => account.account_type,
          "active" => account.active
        },
        "changes" => changes
      }
      LedgerEvent.append!(
        tenant_id: account.tenant_id,
        actor: "u:#{actor.id}",
        actor_user_id: actor.id,
        action: action,
        origin: "folio",
        ts: timestamp,
        ref: account.code,
        payload_str: Folio::KhataHash.canonical_payload(payload)
      )
    end
  end
end
