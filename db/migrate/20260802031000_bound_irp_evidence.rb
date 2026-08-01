# frozen_string_literal: true

class BoundIrpEvidence < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      ALTER TABLE einvoice_submissions
        ADD CONSTRAINT chk_einvoice_submission_evidence_size CHECK (
          octet_length(COALESCE(signed_invoice, '')) <= 1048576 AND
          octet_length(COALESCE(signed_qr_code, '')) <= 1048576 AND
          octet_length(COALESCE(provider_response::text, '')) <= 262144 AND
          octet_length(COALESCE(error_message, '')) <= 2048
        );
      ALTER TABLE einvoice_cancellations
        ADD CONSTRAINT chk_einvoice_cancellation_evidence_size CHECK (
          octet_length(COALESCE(provider_response::text, '')) <= 262144 AND
          octet_length(COALESCE(error_message, '')) <= 2048
        );
    SQL
  end

  def down
    execute <<~SQL
      ALTER TABLE einvoice_cancellations
        DROP CONSTRAINT IF EXISTS chk_einvoice_cancellation_evidence_size;
      ALTER TABLE einvoice_submissions
        DROP CONSTRAINT IF EXISTS chk_einvoice_submission_evidence_size;
    SQL
  end
end
