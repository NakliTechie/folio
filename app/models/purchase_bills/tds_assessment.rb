# frozen_string_literal: true

module PurchaseBills
  # Builds and verifies the immutable TDS assessment attached to a purchase bill. Every bill
  # with a TDS nature gets a snapshot, even below threshold; those zero-deduction snapshots
  # are what make a later aggregate-threshold crossing complete and reproducible.
  module TdsAssessment
    SNAPSHOT_ATTRIBUTES = %i[
      tds_section tds_statutory_reference tds_base_basis tds_trigger_event
      tds_rate_basis_points tds_taxable_minor tds_prior_taxable_minor
      tds_prior_deducted_base_minor tds_deductible_base_minor tds_minor
    ].freeze

    module_function

    def build(tenant:, entity:, party:, on:, gross_minor:, gst_minor:, section:)
      return empty_snapshot if section.blank?

      base = Taxes::India::Tds::Base.for_invoice(
        gross_minor: gross_minor,
        gst_minor: gst_minor,
        gst_separately_stated: true
      )
      rate = Taxes::India::Tds::Schedule.resolve(
        section: section,
        deductee_category: Taxes::India::Pan.deductee_category(vendor_pan(party, on)) || :other,
        on: on
      )
      prior = prior_totals(
        tenant_id: tenant.id,
        party_id: party.id,
        section: section,
        on: on,
        fiscal_year: Documents.fiscal_year(on, variant: entity.fiscal_year_variant),
        threshold_period: rate.threshold_period
      )
      result = Taxes::India::Tds::Deduction.compute(
        section: section,
        on: on,
        amount_minor: base.taxable_minor,
        pan: vendor_pan(party, on),
        period_taxable_to_date_minor: prior.fetch(:taxable_minor),
        prior_deducted_base_minor: prior.fetch(:deducted_base_minor)
      )
      if result.tds_minor >= gross_minor
        raise InvalidBill,
          "catch-up TDS exceeds this bill; post a larger credit or use the governed advance workflow"
      end

      {
        tds_section: section,
        tds_statutory_reference: result.statutory_reference,
        tds_base_basis: base.basis,
        tds_trigger_event: base.trigger_event,
        tds_rate_basis_points: result.rate_basis_points,
        tds_taxable_minor: base.taxable_minor,
        tds_prior_taxable_minor: prior.fetch(:taxable_minor),
        tds_prior_deducted_base_minor: prior.fetch(:deducted_base_minor),
        tds_deductible_base_minor: result.deductible_base_minor,
        tds_minor: result.tds_minor
      }
    rescue Taxes::India::Tds::UnknownSection, Taxes::India::Tds::InvalidInput => e
      raise InvalidBill, "TDS section #{section} is unavailable: #{e.message}"
    end

    def rebuild_from_frozen(document)
      return empty_snapshot if document.tds_section.blank?

      entity = Entity.find_by!(tenant_id: document.tenant_id, id: document.entity_id)
      build_from_values(
        tenant_id: document.tenant_id,
        entity: entity,
        party_id: document.party_id,
        party_pan: pan_from_gstin(document.party_snapshot.fetch("gstin")),
        on: document.document_date,
        gross_minor: document.total_minor,
        gst_minor: document.tax_minor,
        section: document.tds_section,
        exclude_document_id: document.id
      )
    end

    def matches_frozen?(document)
      expected = rebuild_from_frozen(document)
      SNAPSHOT_ATTRIBUTES.all? do |attribute|
        document.public_send(attribute) == expected.fetch(attribute)
      end
    end

    def assert_no_dependent_bills!(document)
      return if document.reverses_document_id.present? || document.tds_section.blank?

      category = Taxes::India::Pan.deductee_category(
        pan_from_gstin(document.party_snapshot.fetch("gstin"))
      ) || :other
      rate = Taxes::India::Tds::Schedule.resolve(
        section: document.tds_section, deductee_category: category, on: document.document_date
      )
      scope = Document.where(
        tenant_id: document.tenant_id, party_id: document.party_id, doc_type: "PB",
        state: "posted", tds_section: document.tds_section
      ).where(reverses_document_id: nil).where.not(id: document.id)
      scope = if rate.threshold_period == :month
        scope.where(document_date: document.document_date.beginning_of_month..document.document_date.end_of_month)
      else
        scope.where(fiscal_year: document.fiscal_year)
      end
      dependent = scope.where("document_date >= ?", document.document_date)
        .order(:document_date, :id).first
      return unless dependent

      raise Documents::Reverse::NotReversible,
        "reverse later TDS-assessed bill #{dependent.document_number} first; its frozen threshold assessment depends on this bill"
    end

    def empty_snapshot
      {
        tds_section: nil,
        tds_statutory_reference: nil,
        tds_base_basis: nil,
        tds_trigger_event: nil,
        tds_rate_basis_points: 0,
        tds_taxable_minor: 0,
        tds_prior_taxable_minor: 0,
        tds_prior_deducted_base_minor: 0,
        tds_deductible_base_minor: 0,
        tds_minor: 0
      }
    end

    def vendor_pan(party, on)
      registration = party.party_tax_registrations.in_force_on(on)
        .where(kind: "GSTIN").order(valid_from: :desc).first
      pan_from_gstin(registration&.identifier)
    end

    def pan_from_gstin(gstin)
      gstin[2, 10] if gstin.present? && gstin.length >= 12
    end

    def build_from_values(tenant_id:, entity:, party_id:, party_pan:, on:, gross_minor:, gst_minor:,
                          section:, exclude_document_id: nil)
      base = Taxes::India::Tds::Base.for_invoice(
        gross_minor: gross_minor,
        gst_minor: gst_minor,
        gst_separately_stated: true
      )
      rate = Taxes::India::Tds::Schedule.resolve(
        section: section,
        deductee_category: Taxes::India::Pan.deductee_category(party_pan) || :other,
        on: on
      )
      prior = prior_totals(
        tenant_id: tenant_id,
        party_id: party_id,
        section: section,
        on: on,
        fiscal_year: Documents.fiscal_year(on, variant: entity.fiscal_year_variant),
        threshold_period: rate.threshold_period,
        exclude_document_id: exclude_document_id
      )
      result = Taxes::India::Tds::Deduction.compute(
        section: section,
        on: on,
        amount_minor: base.taxable_minor,
        pan: party_pan,
        period_taxable_to_date_minor: prior.fetch(:taxable_minor),
        prior_deducted_base_minor: prior.fetch(:deducted_base_minor)
      )
      {
        tds_section: section,
        tds_statutory_reference: result.statutory_reference,
        tds_base_basis: base.basis,
        tds_trigger_event: base.trigger_event,
        tds_rate_basis_points: result.rate_basis_points,
        tds_taxable_minor: base.taxable_minor,
        tds_prior_taxable_minor: prior.fetch(:taxable_minor),
        tds_prior_deducted_base_minor: prior.fetch(:deducted_base_minor),
        tds_deductible_base_minor: result.deductible_base_minor,
        tds_minor: result.tds_minor
      }
    end

    def prior_totals(tenant_id:, party_id:, section:, on:, fiscal_year:, threshold_period:,
                     exclude_document_id: nil)
      scope = Document.where(
        tenant_id: tenant_id,
        party_id: party_id,
        doc_type: "PB",
        state: %w[posted reversed],
        tds_section: section
      ).where.not(posted_entry_id: nil)
      scope = scope.where.not(id: exclude_document_id) if exclude_document_id
      scope = if threshold_period == :month
        scope.where(document_date: on.beginning_of_month..on.end_of_month)
      else
        scope.where(fiscal_year: fiscal_year)
      end

      if scope.where("document_date > ?", on).exists?
        raise InvalidBill,
          "TDS-assessed purchase bills must be posted in supplier-invoice date order"
      end

      rows = scope.where("document_date <= ?", on).to_a
      {
        taxable_minor: rows.sum { |row| document_sign(row) * row.tds_taxable_minor },
        deducted_base_minor: rows.sum { |row| document_sign(row) * row.tds_deductible_base_minor }
      }.tap do |totals|
        if totals.values.any?(&:negative?)
          raise InvalidBill, "prior TDS assessment history is internally inconsistent"
        end
      end
    end

    def document_sign(document) = document.reverses_document_id.present? ? -1 : 1
  end
end
