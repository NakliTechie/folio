# frozen_string_literal: true

module Documents
  # Post a draft/parked document: allocate its statutory number and post its entry, ATOMICALLY
  # — the number allocation and the ledger post live in one transaction, so a failed post
  # returns the number to the series (gapless). Simulate first, so an unbalanced document is
  # rejected before anything is written.
  module Post
    NotPostable = Class.new(StandardError)
    NotPermitted = Class.new(StandardError)

    module_function

    # `authorize:` — when given {user:, tenant:, office_id?}, RBAC is enforced (capability +
    # posting limit) and the resolved authority is stamped on the entry. Omit it for internal /
    # system posts (existing engine tests). This is defence-in-depth: the API also checks.
    def call(document, actor:, capabilities: [], authorize: nil)
      raise NotPostable, "document is #{document.state}, not postable" unless document.postable?
      authority = enforce_and_resolve_authority!(document, authorize)

      ActiveRecord::Base.transaction do
        sim = Simulate.call(document)
        raise Posting::UnbalancedError, sim[:offenders] unless sim[:balanced]

        posting = document.posting_date || document.document_date || Date.current
        number = allocate_number(document)
        entry = Posting::PostEntry.post!(
          tenant_id: document.tenant_id, entity_id: document.entity_id, office_id: document.office_id,
          actor: actor, origin: "folio",
          document_date: document.document_date || posting, posting_date: posting,
          entered_at: Time.now.utc, fiscal_year: document.fiscal_year, period_no: Documents.period_no(posting),
          capabilities: capabilities, authority: authority, document: { id: document.id }, lines: sim[:lines]
        )
        document.update!(state: "posted", document_number: number, posted_entry_id: entry.id)
        entry
      end
    end

    # Reject a post the actor's role/limit does not permit; return the authority to stamp.
    # The tenant is ALWAYS the document's own tenant_id — never a caller-supplied value — so a
    # role held in another tenant can never authorize a post here.
    def enforce_and_resolve_authority!(document, authorize)
      return {} unless authorize

      user = authorize.fetch(:user)
      tenant_id = document.tenant_id
      office_id = authorize[:office_id] || document.office_id
      amount = document.document_lines.select { |l| l.amount_minor.positive? }.sum(&:amount_minor)

      unless Authorization.permits?(user: user, tenant_id: tenant_id, capability: "documents.post",
                                    office_id: office_id, amount_minor: amount)
        raise NotPermitted, "not permitted to post this document (role or posting limit)"
      end
      Authorization.authority_for(user: user, tenant_id: tenant_id, office_id: office_id)
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
      [ document.document_type&.number_prefix, seq ].compact.join
    end
  end
end
