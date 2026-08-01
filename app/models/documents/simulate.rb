# frozen_string_literal: true

module Documents
  # Preview a document's posting WITHOUT posting it: run the type's rule to produce the entry
  # lines and report whether they balance per (ledger, slot, currency). Do not skip this — it
  # is the difference between "post and pray" and "see what will happen".
  module Simulate
    module_function

    def call(document)
      lines = Posting::DocumentSplitting.apply(Documents.rule_for(document).entry_lines(document))
      offenders = Posting::PostEntry.balance_offenders(lines)
      { lines: lines, balanced: offenders.empty?, offenders: offenders }
    end
  end
end
