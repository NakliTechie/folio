# frozen_string_literal: true

module Api
  module V1
    class PurchaseCreditNotesController < BaseController
      before_action -> { require_capability!("reports.read") }, only: %i[index show]
      before_action -> { require_capability!("bills.create") }, only: %i[create post destroy]
      before_action :set_document, only: %i[show post destroy]

      def index
        render json: {
          purchase_credit_notes: document_scope.order(document_date: :desc).map { |note| document_json(note) }
        }
      end

      def show
        render json: { purchase_credit_note: document_json(@document) }
      end

      def create
        note = PurchaseCreditNotes::BuildDraft.call(
          tenant: Current.tenant,
          purchase_bill_id: params[:purchase_bill_id],
          document_date: params[:document_date],
          external_reference: params[:external_reference],
          reason_code: params[:reason_code],
          narration: params[:narration],
          lines: lines_params
        )
        render json: { purchase_credit_note: document_json(note) }, status: :created
      end

      def post
        entry = Documents::Post.call(
          @document,
          actor: "u:#{current_user.id}",
          authorize: { user: current_user },
          required_capability: "bills.create"
        )
        render json: { purchase_credit_note: document_json(@document.reload), entry_id: entry.id }
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
        Document.where(tenant_id: Current.tenant.id, doc_type: "PC")
      end

      def lines_params
        raw_lines = params[:lines]
        unless raw_lines.is_a?(Array)
          raise PurchaseCreditNotes::InvalidCreditNote, "lines must be an array"
        end

        raw_lines.map do |line|
          unless line.respond_to?(:permit)
            raise PurchaseCreditNotes::InvalidCreditNote, "each line must be an object"
          end

          line.permit(:document_line_id, :quantity).to_h
        end
      end

      def document_json(note)
        source = note.credit_note_for
        {
          id: note.id,
          state: note.state,
          document_number: note.document_number,
          supplier_credit_note_number: note.external_reference,
          source_purchase_document_id: source.id,
          source_purchase_document_type: source.doc_type,
          source_purchase_document_number: source.document_number,
          source_purchase_bill_id: source.doc_type == "PB" ? source.id : nil,
          source_purchase_bill_number: source.doc_type == "PB" ? source.document_number : nil,
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
              source_purchase_bill_line_id: line.credited_document_line_id,
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
