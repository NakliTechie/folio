# frozen_string_literal: true

class BusinessProfilesController < BrowserController
  before_action -> { require_capability!("masters.manage") }
  before_action :load_profile

  def edit; end

  def update
    BusinessProfiles::Manage.update!(
      entity: @entity,
      office: @office,
      entity_attributes: profile_params.fetch(:entity, {}).to_h,
      office_attributes: profile_params.fetch(:office, {}).to_h,
      actor: Current.user
    )
    redirect_to edit_business_profile_path(tenant_route_options),
      notice: "Company details updated for future statutory documents."
  rescue ActiveRecord::RecordInvalid, BusinessProfiles::InvalidProfile => e
    @entity.assign_attributes(profile_params.fetch(:entity, {}))
    @office.assign_attributes(profile_params.fetch(:office, {}))
    flash.now[:alert] = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
    render :edit, status: :unprocessable_entity
  end

  private

  def load_profile
    @entity = Entity.find_by!(tenant_id: Current.tenant.id, code: "PRIMARY")
    @office = Office.find_by!(tenant_id: Current.tenant.id, entity_id: @entity.id, code: "PRIMARY")
  end

  def profile_params
    params.require(:business_profile).permit(
      entity: [ :legal_name ],
      office: %i[name address_line1 address_line2 city postal_code state_code country_code]
    )
  end
end
