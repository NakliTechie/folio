# frozen_string_literal: true

class PartiesController < BrowserController
  before_action -> { require_capability!("masters.manage") },
    only: %i[new create edit update deactivate reactivate]
  before_action :set_party, only: %i[edit update deactivate reactivate]

  def index
    @parties = party_scope.includes(:party_roles, :party_tax_registrations).order(:party_number)
  end

  def new
    @party = party_scope.new(country_code: "IN", active: true)
    @selected_roles = [ "customer" ]
    @tax_registration = @party.party_tax_registrations.new(
      kind: "GSTIN", valid_from: fiscal_year_start, active: true
    )
  end

  def create
    @party = Parties::Manage.create!(
      tenant: Current.tenant,
      attributes: party_params.to_h,
      roles: role_params,
      tax_registration_attributes: tax_registration_params.to_h,
      actor: Current.user
    )
    redirect_to parties_path(tenant_route_options), notice: "#{@party.party_number} · #{@party.name} added."
  rescue ActiveRecord::RecordInvalid => e
    @party = e.record.is_a?(Party) ? e.record : party_scope.new(party_params)
    load_form_state
    @tax_registration = e.record if e.record.is_a?(PartyTaxRegistration)
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    render :new, status: :unprocessable_entity
  end

  def edit
    load_form_state
  end

  def update
    Parties::Manage.update!(
      party: @party,
      attributes: party_params.to_h,
      roles: role_params,
      tax_registration_attributes: tax_registration_params.to_h,
      actor: Current.user
    )
    redirect_to parties_path(tenant_route_options), notice: "#{@party.party_number} · #{@party.name} updated."
  rescue ActiveRecord::RecordInvalid => e
    @party = party_scope.find(params[:id])
    @party.assign_attributes(party_params)
    load_form_state
    @tax_registration = e.record if e.record.is_a?(PartyTaxRegistration)
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    render :edit, status: :unprocessable_entity
  end

  def deactivate
    change_active!(false)
  end

  def reactivate
    change_active!(true)
  end

  private

  def party_scope
    Party.where(tenant_id: Current.tenant.id)
  end

  def set_party
    @party = party_scope.find(params[:id])
  end

  def change_active!(active)
    Parties::Manage.update!(
      party: @party,
      attributes: { active: active },
      roles: @party.role_codes,
      actor: Current.user
    )
    label = active ? "reactivated" : "deactivated for new documents"
    redirect_to parties_path(tenant_route_options), notice: "#{@party.party_number} #{label}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to edit_party_path(@party, tenant_route_options), alert: e.record.errors.full_messages.to_sentence
  end

  def load_form_state
    @selected_roles = params.dig(:party, :roles)&.reject(&:blank?) || @party.role_codes
    @tax_registration = @party.party_tax_registrations.order(valid_from: :desc).first ||
      @party.party_tax_registrations.new(kind: "GSTIN", valid_from: fiscal_year_start, active: true)
  end

  def fiscal_year_start
    entity = Entity.find_by!(tenant_id: Current.tenant.id, code: "PRIMARY")
    return Date.new(Date.current.year, 1, 1) unless entity.fiscal_year_variant == "IN_APR_MAR"

    Date.new(Date.current.month >= 4 ? Date.current.year : Date.current.year - 1, 4, 1)
  end

  def party_params
    params.require(:party).permit(
      :party_number, :name, :email, :phone, :address_line1, :address_line2,
      :city, :postal_code, :state_code, :country_code
    )
  end

  def role_params
    params.require(:party).fetch(:roles, []).reject(&:blank?)
  end

  def tax_registration_params
    params.require(:party).fetch(:tax_registration, {}).permit(
      :kind, :identifier, :valid_from, :valid_to, :active
    )
  end
end
