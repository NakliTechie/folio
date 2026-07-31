# frozen_string_literal: true

module Api
  module V1
    class CreditNotesController < BaseController
      before_action -> { require_capability!("reports.read") }, only: %i[index show]
      before_action -> { require_capability!("invoices.create") }, only: %i[create post]
      before_action :set_document, only: %i[show post]

      def index
        render json: { credit_notes: document_scope.order(document_date: :desc).map { |note| document_json(note) } }
      end

      def show
        render json: { credit_note: document_json(@document) }
      end

      def create
        note = CreditNotes::BuildDraft.call(
          tenant: Current.tenant,
          invoice_id: params[:invoice_id],
          document_date: params[:document_date],
          reason_code: params[:reason_code],
          narration: params[:narration],
          lines: lines_params
        )
        render json: { credit_note: document_json(note) }, status: :created
      end

      def post
        entry = Documents::Post.call(
          @document,
          actor: "u:#{current_user.id}",
          authorize: { user: current_user },
          required_capability: "invoices.create"
        )
        render json: { credit_note: document_json(@document.reload), entry_id: entry.id }
      end

      private

      def set_document
        @document = document_scope.find(params[:id])
      end

      def document_scope
        Document.where(tenant_id: Current.tenant.id, doc_type: "CN")
      end

      def lines_params
        raw_lines = params[:lines]
        raise CreditNotes::InvalidCreditNote, "lines must be an array" unless raw_lines.is_a?(Array)

        raw_lines.map do |line|
          raise CreditNotes::InvalidCreditNote, "each line must be an object" unless line.respond_to?(:permit)

          line.permit(:document_line_id, :quantity).to_h
        end
      end

      def document_json(note)
        {
          id: note.id,
          state: note.state,
          document_number: note.document_number,
          source_invoice_id: note.credit_note_for_document_id,
          source_invoice_number: note.credit_note_for.document_number,
          document_date: note.document_date,
          reason_code: note.reason_code,
          currency: note.currency,
          subtotal_minor: note.subtotal_minor,
          tax_minor: note.tax_minor,
          total_minor: note.total_minor,
          tax_breakdown: note.tax_breakdown,
          lines: note.document_lines.map do |line|
            {
              line_no: line.line_no,
              source_invoice_line_id: line.credited_document_line_id,
              item: line.item_snapshot,
              quantity: line.quantity.to_s("F"),
              taxable_minor: line.taxable_minor,
              tax_components: line.tax_components
            }
          end
        }
      end
    end
  end
end
