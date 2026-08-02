# frozen_string_literal: true

require "tempfile"

class KhataImportJob < ApplicationJob
  def perform(upload_id)
    upload = KhataImportUpload.find(upload_id)
    Folio::TenantContext.with(upload.tenant_id) do
      claimed = upload.with_lock do
        next false unless upload.status == "queued" && upload.archive_bytes.present?

        upload.update!(status: "processing", error_message: nil)
        true
      end
      return unless claimed

      file = Tempfile.new([ "folio-khata-upload", ".khata" ])
      file.binmode
      file.write(upload.archive_bytes)
      file.flush
      result = Khata::Bridge.import!(
        tenant: upload.tenant, actor: upload.requested_by, path: file.path,
        filename: upload.source_filename
      )
      upload.update!(
        status: "succeeded", khata_import_run: result.run,
        archive_bytes: nil, error_message: nil
      )
    end
  rescue StandardError => e
    upload&.update!(
      status: "failed", archive_bytes: nil,
      error_message: e.message.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
        .delete("\0").byteslice(0, 1_000)
    )
    Rails.error.report(e, handled: true, context: { khata_import_upload_id: upload_id })
  ensure
    file&.close!
  end
end
