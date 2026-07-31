# frozen_string_literal: true

class TaxRegistrationsController < BrowserController
  before_action -> { require_capability!("masters.manage") }
  before_action :set_registration, only: %i[edit update deactivate reactivate]

  def index
    @registrations = registration_scope.includes(:entity, :offices).order(:kind, :identifier, :valid_from)
  end

  def new
    @registration = registration_scope.new(kind: "GSTIN", valid_from: fiscal_year_start, active: true)
    load_form
  end

  def create
    @registration = TaxRegistrations::Manage.create!(
      tenant: Current.tenant, entity: primary_entity,
      attributes: registration_params.to_h,
      office_ids: office_ids,
      actor: Current.user
    )
    redirect_to tax_registrations_path(tenant_route_options),
      notice: "#{@registration.kind} #{@registration.identifier} added."
  rescue ActiveRecord::RecordInvalid => e
    @registration = e.record.is_a?(TaxRegistration) ? e.record : registration_scope.new(registration_params)
    load_form
    flash.now[:alert] = e.record.errors.full_messages.to_sentence
    render :new, status: :unprocessable_entity
  end

  def edit
    load_form
  end

  def update
    TaxRegistrations::Manage.update!(
      registration: @registration,
      attributes: registration_params.to_h,
      office_ids: office_ids,
      actor: Current.user
    )
    redirect_to tax_registrations_path(tenant_route_options),
      notice: "#{@registration.kind} #{@registration.identifier} updated."
  rescue ActiveRecord::RecordInvalid => e
    @registration = registration_scope.find(params[:id])
    @registration.assign_attributes(registration_params)
    load_form
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

  def registration_scope
    TaxRegistration.where(tenant_id: Current.tenant.id)
  end

  def set_registration
    @registration = registration_scope.find(params[:id])
  end

  def primary_entity
    @primary_entity ||= Entity.find_by!(tenant_id: Current.tenant.id, code: "PRIMARY")
  end

  def load_form
    @offices = Office.where(tenant_id: Current.tenant.id, entity_id: primary_entity.id).order(:code)
    @selected_office_ids = if params.dig(:tax_registration, :office_ids)
      office_ids.map(&:to_i)
    elsif @registration.persisted?
      @registration.office_ids
    else
      @offices.map(&:id)
    end
    @registration_kinds = Jurisdictions.fetch!(primary_entity.jurisdiction_profile).registration_kinds
  end

  def fiscal_year_start
    today = business_date
    return Date.new(today.year, 1, 1) unless primary_entity.fiscal_year_variant == "IN_APR_MAR"

    Date.new(today.month >= 4 ? today.year : today.year - 1, 4, 1)
  end

  def change_active!(active)
    TaxRegistrations::Manage.update!(
      registration: @registration,
      attributes: { active: active },
      office_ids: @registration.office_ids,
      actor: Current.user
    )
    label = active ? "reactivated" : "deactivated for new documents"
    redirect_to tax_registrations_path(tenant_route_options),
      notice: "#{@registration.kind} #{@registration.identifier} #{label}."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to edit_tax_registration_path(@registration, tenant_route_options),
      alert: e.record.errors.full_messages.to_sentence
  end

  def office_ids
    params.require(:tax_registration).fetch(:office_ids, []).reject(&:blank?)
  end

  def registration_params
    params.require(:tax_registration).permit(
      :kind, :identifier, :jurisdiction, :valid_from, :valid_to
    )
  end
end
