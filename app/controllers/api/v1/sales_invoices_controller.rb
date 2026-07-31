# frozen_string_literal: true

module Api
  module V1
    class SalesInvoicesController < BaseController
      before_action -> { require_capability!("reports.read") }, only: %i[index show]
      before_action -> { require_capability!("invoices.create") }, only: %i[create post]
      before_action -> { require_capability!("documents.reverse") }, only: :reverse
      before_action :set_document, only: %i[show post reverse]

      def index
        documents = document_scope.order(document_date: :desc, created_at: :desc)
        render json: { sales_invoices: documents.map { |document| document_json(document) } }
      end

      def show
        render json: { sales_invoice: document_json(@document) }
      end

      def create
        document = SalesInvoices::BuildDraft.call(
          tenant: Current.tenant,
          party_id: params[:party_id],
          tax_registration_id: params[:tax_registration_id],
          document_date: params[:document_date],
          due_date: params[:due_date],
          place_of_supply_state_code: params[:place_of_supply_state_code],
          external_reference: params[:external_reference],
          narration: params[:narration],
          lines: lines_params
        )
        render json: { sales_invoice: document_json(document) }, status: :created
      end

      def post
        entry = Documents::Post.call(
          @document,
          actor: "u:#{current_user.id}",
          authorize: { user: current_user },
          required_capability: "invoices.create"
        )
        render json: { sales_invoice: document_json(@document.reload), entry_id: entry.id }
      end

      def reverse
        Documents::Reverse.call(
          @document, actor: "u:#{current_user.id}", authorize: { user: current_user }
        )
        render json: { sales_invoice: document_json(@document.reload) }
      rescue Documents::Reverse::NotReversible => e
        render_error(e.message, :conflict)
      end

      private

      def set_document
        @document = document_scope.find(params[:id])
      end

      def document_scope
        Document.where(tenant_id: Current.tenant.id, doc_type: "SI")
      end

      def lines_params
        raw_lines = params[:lines]
        raise SalesInvoices::InvalidInvoice, "lines must be an array" unless raw_lines.is_a?(Array)

        raw_lines.map do |line|
          raise SalesInvoices::InvalidInvoice, "each line must be an object" unless line.respond_to?(:permit)

          line.permit(:item_id, :quantity, :unit_price).to_h
        end
      end

      def document_json(document)
        {
          id: document.id,
          state: document.state,
          document_number: document.document_number,
          posted_entry_id: document.posted_entry_id,
          reversed_by_document_id: document.reversed_by_document_id,
          document_date: document.document_date,
          due_date: document.due_date,
          place_of_supply_state_code: document.place_of_supply_state_code,
          supply_type: document.supply_type,
          currency: document.currency,
          subtotal_minor: document.subtotal_minor,
          tax_minor: document.tax_minor,
          total_minor: document.total_minor,
          tax_breakdown: document.tax_breakdown,
          party: document.party_snapshot,
          seller_registration: document.tax_registration_snapshot,
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
