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
    result = Khata::Bridge.import!(
      tenant: Current.tenant, actor: Current.user, path: upload.tempfile.path,
      filename: upload.original_filename
    )
    notice = result.duplicate ?
      "This exact .khata file was already imported; no changes were made." :
      ".khata imported. Format, chain, signatures, and native ledger reports all passed."
    redirect_to enterprise_export_path(tenant_route_options), notice: notice
  rescue ActionController::ParameterMissing, Khata::Bridge::InvalidImport => e
    redirect_to enterprise_export_path(tenant_route_options), alert: e.message
  end
end
