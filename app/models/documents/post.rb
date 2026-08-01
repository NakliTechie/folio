# frozen_string_literal: true

module Documents
  # Post a draft/parked document: allocate its statutory number and post its entry, ATOMICALLY
  # — the number allocation and the ledger post live in one transaction, so a failed post
  # returns the number to the series (gapless). Simulate first, so an unbalanced document is
  # rejected before anything is written.
  module Post
    NotPostable = Class.new(StandardError)
    NotPermitted = Class.new(StandardError)
    InactiveAccount = Class.new(StandardError)

    module_function

    # `authorize:` — when given {user:, tenant:, office_id?}, RBAC is enforced (capability +
    # posting limit) and the resolved authority is stamped on the entry. Omit it for internal /
    # system posts (existing engine tests). This is defence-in-depth: the API also checks.
    def call(document, actor:, capabilities: [], authorize: nil, required_capability: "documents.post")
      ActiveRecord::Base.transaction do
        # Lock before any document/dependency row. Posting and projection rebuild use the
        # same tenant lock, so maintenance cannot wipe between append and projection and
        # the two paths cannot deadlock by taking their locks in opposite order.
        LedgerEvent.acquire_tenant_lock!(document.tenant_id)
        rule = Documents.rule_for(document)
        rule.lock_dependencies!(document) if rule.respond_to?(:lock_dependencies!)
        document.lock!
        raise NotPostable, "document is #{document.state}, not postable" unless document.postable?
        assert_document_integrity!(document)
        sim = Simulate.call(document)
        assert_accounts_active!(document, sim[:lines])

        authority, role_capabilities = enforce_and_resolve_authority!(
          document, authorize, lines: sim[:lines], required_capability: required_capability
        )
        effective_capabilities = (Array(capabilities) + role_capabilities).uniq
        raise Posting::UnbalancedError, sim[:offenders] unless sim[:balanced]

        posting = document.posting_date || document.document_date || Tenant.find(document.tenant_id).business_date
        number = allocate_number(document)
        entry = Posting::PostEntry.post!(
          tenant_id: document.tenant_id, entity_id: document.entity_id, office_id: document.office_id,
          actor: actor, origin: "folio",
          actor_user_id: authorize&.dig(:user)&.id,
          document_date: document.document_date || posting, posting_date: posting,
          entered_at: Time.now.utc, fiscal_year: document.fiscal_year, period_no: Documents.period_no_for(document),
          capabilities: effective_capabilities, authority: authority, document: { id: document.id },
          statutory_evidence: rule.respond_to?(:statutory_evidence) ? rule.statutory_evidence(document) : nil,
          lines: sim[:lines]
        )
        document.update!(state: "posted", document_number: number, posted_entry_id: entry.id)
        rule.after_post!(document: document, entry: entry, actor: actor) if rule.respond_to?(:after_post!)
        entry
      end
    end

    def assert_accounts_active!(document, posting_lines)
      codes = posting_lines.map { |line| line.fetch(:account_code) }.uniq
      scope = Account.where(tenant_id: document.tenant_id, code: codes)
      available_codes = document.reverses_document_id.present? ? scope.pluck(:code) : scope.active.pluck(:code)
      unavailable = codes - available_codes
      return if unavailable.empty?

      raise InactiveAccount, "accounts unavailable for posting: #{unavailable.join(", ")}"
    end

    def assert_document_integrity!(document)
      tenant = Tenant.find_by(id: document.tenant_id)
      raise InvalidDocument, "document tenant does not exist" unless tenant

      entity = Entity.find_by(tenant_id: document.tenant_id, id: document.entity_id)
      office = Office.find_by(tenant_id: document.tenant_id, entity_id: document.entity_id, id: document.office_id)
      raise InvalidDocument, "document entity or office does not belong to the tenant" unless entity && office

      type = DocumentType.find_by(tenant_id: document.tenant_id, id: document.document_type_id,
        code: document.doc_type)
      unless type && (type.active? || document.reverses_document_id.present?)
        raise InvalidDocument, "document type is unavailable"
      end
      unless document.document_date && document.posting_date
        raise InvalidDocument, "document and posting dates are required"
      end

      expected_fiscal_year = Documents.fiscal_year(
        document.posting_date, variant: entity.fiscal_year_variant
      )
      unless document.fiscal_year == expected_fiscal_year
        raise InvalidDocument,
          "fiscal_year #{document.fiscal_year} does not match posting date (expected #{expected_fiscal_year})"
      end

      lines = document.document_lines.to_a
      Documents.rule_for(document).validate_document!(document)

      lines.each do |line|
        raise InvalidDocument, "document line tenant mismatch" unless line.tenant_id == document.tenant_id
        raise InvalidDocument, "document lines must be non-zero" if line.amount_minor.zero?
        expected_exponent = CurrencyProfile.exponent_for!(line.currency)
        unless line.minor_unit_exponent == expected_exponent
          raise InvalidDocument,
            "#{line.account_code} must use #{line.currency} with minor-unit exponent #{expected_exponent}"
        end
      end
    end

    # Reject a post the actor's role/limit does not permit; return the authority to stamp.
    # The tenant is ALWAYS the document's own tenant_id — never a caller-supplied value — so a
    # role held in another tenant can never authorize a post here.
    def enforce_and_resolve_authority!(document, authorize, lines:, required_capability:)
      return [ {}, [] ] unless authorize

      user = authorize.fetch(:user)
      tenant_id = document.tenant_id
      office_id = authorize[:office_id] || document.office_id
      amount = lines.sum do |line|
        Array(line.fetch(:amounts)).select { |slot| slot[:slot_role] == "transaction" }
          .sum { |slot| [ Integer(slot[:amount_minor]), 0 ].max }
      end
      user_role = Authorization.role_for(user: user, tenant_id: tenant_id, office_id: office_id)

      unless user_role && Authorization.permits?(user: user, tenant_id: tenant_id, capability: required_capability,
                                                 office_id: office_id, amount_minor: amount)
        raise NotPermitted, "not permitted to #{required_capability} (role or posting limit)"
      end
      authority = { role_template_id: user_role.role_template_id, posting_limit_id: user_role.posting_limit_id }
      capabilities = user_role.role_template.role_permissions.pluck(:capability)
      [ authority, capabilities ]
    end

    # Ensure the series row exists (idempotent under concurrency), then allocate gaplessly
    # inside this transaction via the row lock. A prefix from the type, if any.
    def allocate_number(document)
      key = { tenant_id: document.tenant_id, entity_id: document.entity_id,
              office_id: document.office_id, doc_type: document.doc_type, fiscal_year: document.fiscal_year }
      begin
        NumberRange.find_or_create_by!(key) { |r| r.next_value = 1 }
      rescue ActiveRecord::RecordNotUnique
        # a concurrent poster created it first — fine, it exists now.
      end
      seq = NumberRange.allocate!(**key)
      Documents::NumberFormatter.format(document, seq)
    end
  end
end
