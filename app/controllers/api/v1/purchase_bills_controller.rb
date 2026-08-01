# frozen_string_literal: true

module Api
  module V1
    class PurchaseBillsController < BaseController
      before_action -> { require_capability!("reports.read") }, only: %i[index show]
      before_action -> { require_capability!("bills.create") }, only: %i[create post destroy]
      before_action -> { require_capability!("documents.reverse") }, only: :reverse
      before_action :set_document, only: %i[show post reverse destroy]

      def index
        documents = document_scope.order(document_date: :desc, created_at: :desc)
        render json: { purchase_bills: documents.map { |document| document_json(document) } }
      end

      def show
        render json: { purchase_bill: document_json(@document) }
      end

      def create
        document = PurchaseBills::BuildDraft.call(
          tenant: Current.tenant,
          party_id: params[:party_id],
          tax_registration_id: params[:tax_registration_id],
          document_date: params[:document_date],
          due_date: params[:due_date],
          place_of_supply_state_code: params[:place_of_supply_state_code],
          place_of_supply_override_reason: params[:place_of_supply_override_reason],
          actor: current_user,
          external_reference: params[:external_reference],
          narration: params[:narration],
          tds_section: params[:tds_section],
          lines: lines_params
        )
        render json: { purchase_bill: document_json(document) }, status: :created
      end

      def post
        entry = Documents::Post.call(
          @document,
          actor: "u:#{current_user.id}",
          authorize: { user: current_user },
          required_capability: "bills.create"
        )
        render json: { purchase_bill: document_json(@document.reload), entry_id: entry.id }
      end

      def reverse
        Documents::Reverse.call(
          @document, actor: "u:#{current_user.id}", authorize: { user: current_user }
        )
        render json: { purchase_bill: document_json(@document.reload) }
      rescue Documents::Reverse::NotReversible => e
        render_error(e.message, :conflict)
      end

      def destroy
        Documents::Discard.call!(@document)
        head :no_content
      rescue Documents::Discard::NotDiscardable => e
        render_error(e.message, :conflict)
      end

      private

      def set_document
        @document = document_scope.find(params[:id])
      end

      def document_scope
        Document.where(tenant_id: Current.tenant.id, doc_type: "PB")
      end

      def lines_params
        raw_lines = params[:lines]
        raise PurchaseBills::InvalidBill, "lines must be an array" unless raw_lines.is_a?(Array)

        raw_lines.map do |line|
          raise PurchaseBills::InvalidBill, "each line must be an object" unless line.respond_to?(:permit)

          line.permit(:item_id, :quantity, :unit_price).to_h
        end
      end

      def document_json(document)
        {
          id: document.id,
          state: document.state,
          document_number: document.document_number,
          supplier_invoice_number: document.external_reference,
          posted_entry_id: document.posted_entry_id,
          reversed_by_document_id: document.reversed_by_document_id,
          document_date: document.document_date,
          due_date: document.due_date,
          place_of_supply_state_code: document.place_of_supply_state_code,
          place_of_supply_evidence: document.place_of_supply_evidence,
          supply_type: document.supply_type,
          currency: document.currency,
          subtotal_minor: document.subtotal_minor,
          tax_minor: document.tax_minor,
          total_minor: document.total_minor,
          tax_breakdown: document.tax_breakdown,
          tds: document.tds_section && {
            section: document.tds_section,
            statutory_reference: document.tds_statutory_reference,
            trigger_event: document.tds_trigger_event,
            base_basis: document.tds_base_basis,
            rate_basis_points: document.tds_rate_basis_points,
            gross_minor: document.total_minor,
            gst_minor: document.tax_minor,
            taxable_minor: document.tds_taxable_minor,
            prior_taxable_minor: document.tds_prior_taxable_minor,
            prior_deducted_base_minor: document.tds_prior_deducted_base_minor,
            deductible_base_minor: document.tds_deductible_base_minor,
            tds_minor: document.tds_minor,
            vendor_payable_minor: document.total_minor - document.tds_minor
          },
          vendor: document.party_snapshot,
          buyer_registration: document.tax_registration_snapshot,
          lines: document.document_lines.map do |line|
            {
              line_no: line.line_no,
              item_id: line.item_id,
              item: line.item_snapshot,
              quantity: line.quantity.to_s("F"),
              unit_price_minor: line.unit_price_minor,
              taxable_minor: line.taxable_minor,
              hsn_sac_code: line.hsn_sac_code,
              tax_rate_basis_points: line.tax_rate_basis_points,
              cess_rate_basis_points: line.cess_rate_basis_points,
              tax_components: line.tax_components
            }
          end
        }
      end
    end
  end
end
