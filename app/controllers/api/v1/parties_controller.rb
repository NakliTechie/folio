# frozen_string_literal: true

module Api
  module V1
    class PartiesController < BaseController
      before_action -> { require_capability!("masters.manage") }, only: %i[create update]
      before_action :set_party, only: %i[show update]

      def index
        render json: { parties: scope.includes(:party_roles, :party_tax_registrations).order(:party_number)
          .map { |party| party_json(party) } }
      end

      def show
        render json: { party: party_json(@party) }
      end

      def create
        party = Parties::Manage.create!(
          tenant: Current.tenant, attributes: party_params.to_h, roles: role_params,
          tax_registration_attributes: tax_registration_params, actor: current_user
        )
        render json: { party: party_json(party) }, status: :created
      end

      def update
        Parties::Manage.update!(
          party: @party, attributes: party_params.to_h, roles: role_params,
          tax_registration_attributes: tax_registration_params, actor: current_user
        )
        render json: { party: party_json(@party.reload) }
      end

      private

      def scope
        Party.where(tenant_id: Current.tenant.id)
      end

      def set_party
        @party = scope.find(params[:id])
      end

      def party_params
        params.permit(
          :party_number, :name, :active, :email, :phone, :address_line1, :address_line2,
          :city, :postal_code, :state_code, :country_code
        )
      end

      def role_params
        Array(params[:roles]).reject(&:blank?)
      end

      def tax_registration_params
        registration = params[:tax_registration]
        return nil unless registration.respond_to?(:permit)

        registration.permit(:kind, :identifier, :valid_from, :valid_to, :active).to_h
      end

      def party_json(party)
        registration = party.party_tax_registrations.order(valid_from: :desc).first
        {
          id: party.id, party_number: party.party_number, name: party.name, active: party.active,
          roles: party.role_codes, email: party.email, phone: party.phone,
          address_line1: party.address_line1, address_line2: party.address_line2,
          city: party.city, postal_code: party.postal_code,
          state_code: party.state_code, country_code: party.country_code,
          tax_registration: registration && {
            kind: registration.kind, identifier: registration.identifier,
            state_code: registration.state_code, valid_from: registration.valid_from,
            valid_to: registration.valid_to, active: registration.active
          }
        }
      end
    end
  end
end
