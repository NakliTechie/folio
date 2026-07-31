# frozen_string_literal: true

module Api
  module V1
    class TaxRegistrationsController < BaseController
      before_action -> { require_capability!("masters.manage") }, only: %i[create update]
      before_action :set_registration, only: %i[show update]

      def index
        render json: { tax_registrations: scope.includes(:offices).order(:kind, :identifier, :valid_from)
          .map { |registration| registration_json(registration) } }
      end

      def show
        render json: { tax_registration: registration_json(@registration) }
      end

      def create
        registration = TaxRegistrations::Manage.create!(
          tenant: Current.tenant, entity: primary_entity,
          attributes: registration_params.to_h, office_ids: office_ids, actor: current_user
        )
        render json: { tax_registration: registration_json(registration) }, status: :created
      end

      def update
        TaxRegistrations::Manage.update!(
          registration: @registration, attributes: registration_params.to_h,
          office_ids: office_ids, actor: current_user
        )
        render json: { tax_registration: registration_json(@registration.reload) }
      end

      private

      def scope
        TaxRegistration.where(tenant_id: Current.tenant.id)
      end

      def set_registration
        @registration = scope.find(params[:id])
      end

      def primary_entity
        @primary_entity ||= Entity.find_by!(tenant_id: Current.tenant.id, code: "PRIMARY")
      end

      def office_ids
        Array(params[:office_ids]).reject(&:blank?)
      end

      def registration_params
        params.permit(:kind, :identifier, :jurisdiction, :valid_from, :valid_to, :active)
      end

      def registration_json(registration)
        {
          id: registration.id, entity_id: registration.entity_id,
          kind: registration.kind, identifier: registration.identifier,
          jurisdiction: registration.jurisdiction, state_code: registration.state_code,
          valid_from: registration.valid_from, valid_to: registration.valid_to,
          active: registration.active, office_ids: registration.office_ids.sort
        }
      end
    end
  end
end
