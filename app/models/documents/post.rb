# frozen_string_literal: true

module Documents
  # Post a draft/parked document: allocate its statutory number and post its entry, ATOMICALLY
  # — the number allocation and the ledger post live in one transaction, so a failed post
  # returns the number to the series (gapless). Simulate first, so an unbalanced document is
  # rejected before anything is written.
  module Post
    NotPostable = Class.new(StandardError)

    module_function

    def call(document, actor:, capabilities: [])
      raise NotPostable, "document is #{document.state}, not postable" unless document.postable?

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
          capabilities: capabilities, document: { id: document.id }, lines: sim[:lines]
        )
        document.update!(state: "posted", document_number: number, posted_entry_id: entry.id)
        entry
      end
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
