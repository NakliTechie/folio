# frozen_string_literal: true

class EnterpriseExportsController < BrowserController
  before_action -> { require_capability!("exports.read") }

  def show
    @entities = Entity.where(tenant_id: Current.tenant.id).order(:code)
    @offices = Office.where(tenant_id: Current.tenant.id).includes(:entity).order(:code)
    @groups = ConsolidationGroup.where(tenant_id: Current.tenant.id).order(:code)
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
end
