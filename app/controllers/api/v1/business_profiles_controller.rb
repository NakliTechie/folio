# frozen_string_literal: true

module Api
  module V1
    class BusinessProfilesController < BaseController
      before_action -> { require_capability!("reports.read") }, only: :show
      before_action -> { require_capability!("masters.manage") }, only: :update
      before_action :load_profile

      def show
        render json: { business_profile: profile_json }
      end

      def update
        BusinessProfiles::Manage.update!(
          entity: @entity,
          office: @office,
          entity_attributes: section_params(:entity, :legal_name),
          office_attributes: section_params(
            :office, :name, :address_line1, :address_line2, :city,
            :postal_code, :state_code, :country_code
          ),
          actor: current_user
        )
        render json: { business_profile: profile_json }
      end

      private

      def load_profile
        @entity = Entity.find_by!(tenant_id: Current.tenant.id, code: "PRIMARY")
        @office = Office.find_by!(tenant_id: Current.tenant.id, entity_id: @entity.id, code: "PRIMARY")
      end

      def profile_json
        {
          entity: { id: @entity.id, code: @entity.code, legal_name: @entity.legal_name },
          office: @office.attributes.slice(
            "id", "code", "name", "address_line1", "address_line2", "city",
            "postal_code", "state_code", "country_code"
          )
        }
      end

      def section_params(key, *attributes)
        section = params[key]
        unless section.respond_to?(:permit)
          raise BusinessProfiles::InvalidProfile, "#{key} must be an object"
        end

        section.permit(*attributes).to_h
      end
    end
  end
end
