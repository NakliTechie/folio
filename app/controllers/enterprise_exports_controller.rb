# frozen_string_literal: true

require "digest"

class EnterpriseExportsController < BrowserController
  before_action -> { require_capability!("exports.read") }, only: %i[show sap_b1_dtw khata]
  before_action -> { require_capability!("khata.import") }, only: :import_khata

  def show
    @entities = Entity.where(tenant_id: Current.tenant.id).order(:code)
    @offices = Office.where(tenant_id: Current.tenant.id).includes(:entity).order(:code)
    @groups = ConsolidationGroup.where(tenant_id: Current.tenant.id).order(:code)
    @khata_import = KhataImportRun.find_by(tenant_id: Current.tenant.id)
    @khata_import_upload = KhataImportUpload.where(tenant_id: Current.tenant.id)
      .select(:id, :tenant_id, :source_filename, :status, :error_message, :created_at, :updated_at)
      .order(id: :desc).first
  end

  def sap_b1_dtw
    result = SapBusinessOne::DtwExport.call(
      tenant: Current.tenant,
      scope: params.require(:scope),
      from_date: params.require(:from_date),
      to_date: params.require(:to_date),
      entity_id: params[:entity_id], office_id: params[:office_id], group_id: params[:group_id]
    )
    send_data(
      result.bytes, filename: result.filename, type: "application/zip", disposition: "attachment"
    )
  rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound,
         SapBusinessOne::InvalidExport => e
    redirect_to enterprise_export_path(tenant_route_options), alert: e.message
  end

  def khata
    result = Khata::Export.call(
      tenant: Current.tenant, entity_id: params.require(:entity_id)
    )
    DomainEvents::Record.call(
      tenant_id: Current.tenant.id, kind: "khata.exported",
      actor: Current.user.email_address, actor_user_id: Current.user.id,
      ref: result.manifest.fetch("workspaceId"),
      payload: {
        "filename" => result.filename, "archiveSha256" => Digest::SHA256.hexdigest(result.bytes),
        "booksSha256" => result.manifest.dig("integrity", "booksHash"),
        "auditHead" => result.manifest.dig("integrity", "auditHead")
      }
    )
    send_data(
      result.bytes, filename: result.filename, type: "application/x-khata",
      disposition: "attachment"
    )
  rescue ActionController::ParameterMissing, ActiveRecord::RecordNotFound,
         Khata::Export::InvalidExport => e
    redirect_to enterprise_export_path(tenant_route_options), alert: e.message
  end

  def import_khata
    upload = params.require(:khata_file)
    unless upload.respond_to?(:tempfile) && upload.respond_to?(:original_filename)
      raise Khata::Bridge::InvalidImport, "Choose a .khata file to import."
    end
    size = File.size(upload.tempfile.path)
    raise Khata::Bridge::InvalidImport, ".khata file is empty." if size.zero?
    if size > Khata::Archive::MAX_ARCHIVE_BYTES
      raise Khata::Bridge::InvalidImport, ".khata file exceeds the 100 MB upload limit."
    end
    if KhataImportUpload.where(tenant_id: Current.tenant.id, status: %w[queued processing]).exists?
      raise Khata::Bridge::InvalidImport, "A .khata import is already queued or processing."
    end
    request = KhataImportUpload.create!(
      tenant: Current.tenant, requested_by: Current.user,
      source_filename: File.basename(upload.original_filename.to_s).byteslice(0, 255),
      archive_sha256: Digest::SHA256.file(upload.tempfile.path).hexdigest,
      archive_bytes: File.binread(upload.tempfile.path)
    )
    if request.enqueue!
      redirect_to enterprise_export_path(tenant_route_options),
        notice: ".khata verification and import were queued. Refresh this page for the result."
    else
      redirect_to enterprise_export_path(tenant_route_options),
        alert: "The .khata import could not be queued. Try again."
    end
  rescue ActionController::ParameterMissing, Khata::Bridge::InvalidImport,
         ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
    redirect_to enterprise_export_path(tenant_route_options), alert: e.message
  end
end
