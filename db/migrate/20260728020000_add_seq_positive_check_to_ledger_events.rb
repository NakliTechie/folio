# frozen_string_literal: true

# `seq` is 1-based and monotonic per tenant. Nothing enforced that, and the keyset
# walk in LedgerEvent.verify_chain starts from `last_seq = 0` with `seq > last_seq` —
# so a row forged with seq <= 0 would sit in the table completely unvisited by the
# integrity check. Found by adversarial review, not by a test.
#
# Making it unrepresentable beats detecting it: the same reasoning as the append-only
# triggers. A CHECK constraint is a DB guarantee; a walker that remembers to look is
# an app-layer convention.
class AddSeqPositiveCheckToLedgerEvents < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      ALTER TABLE ledger_events
        ADD CONSTRAINT ledger_events_seq_positive CHECK (seq > 0);
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE ledger_events DROP CONSTRAINT IF EXISTS ledger_events_seq_positive;
    SQL
  end
end
