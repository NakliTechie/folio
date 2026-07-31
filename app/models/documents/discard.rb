# frozen_string_literal: true

module Documents
  # Drafts have no ledger event and no statutory number. Explicitly discarding one releases
  # reserved supplier references while preserving the append-only rule for posted documents.
  module Discard
    NotDiscardable = Class.new(StandardError)

    module_function

    def call!(document)
      document.with_lock do
        unless document.postable? && document.posted_entry_id.nil? && document.document_number.nil?
          raise NotDiscardable, "only an unposted, unnumbered draft can be discarded"
        end

        document.destroy!
      end
    end
  end
end
