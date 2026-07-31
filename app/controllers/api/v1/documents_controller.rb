# frozen_string_literal: true

module Api
  module V1
    # Documents over the engine: create a draft, simulate/preview, post (RBAC + limit enforced
    # inside Documents::Post via authorize:), reverse. All strictly tenant-scoped — a document of
    # another tenant is simply not found (404).
    class DocumentsController < BaseController
      before_action :set_document, only: %i[show simulate post reverse]
      before_action -> { require_capability!("documents.post") }, only: :create
      before_action -> { require_capability!("documents.simulate") }, only: :simulate
      before_action -> { require_capability!("documents.reverse") }, only: :reverse

      def show
        render json: { document: document_json(@document) }
      end

      def create
        doc = build_document
        render json: { document: document_json(doc) }, status: :created
      end

      def simulate
        sim = Documents::Simulate.call(@document)
        render json: { balanced: sim[:balanced], lines: sim[:lines],
                       offenders: sim[:offenders].map { |(l, s, c), v| { ledger_id: l, slot: s, currency: c, imbalance: v } } }
      end

      def post
        entry = Documents::Post.call(@document, actor: "u:#{current_user.id}", authorize: { user: current_user })
        render json: { document: document_json(@document.reload), entry_id: entry.id }
      end

      def reverse
        Documents::Reverse.call(
          @document, actor: "u:#{current_user.id}", authorize: { user: current_user }
        )
        render json: { document: document_json(@document.reload) }
      rescue Documents::Reverse::NotReversible => e
        render_error(e.message, :conflict)
      end

      private

      def set_document
        @document = Document.where(tenant_id: Current.tenant.id).find(params[:id])
      end

      def build_document
        Documents::BuildDraft.call(
          tenant: Current.tenant,
          doc_type: params[:doc_type],
          fiscal_year: params[:fiscal_year],
          document_date: params[:document_date],
          posting_date: params[:posting_date],
          narration: params[:narration],
          lines: document_lines_params
        )
      end

      def document_lines_params
        raw_lines = params[:lines]
        return [] if raw_lines.nil?
        raise Documents::InvalidDocument, "lines must be an array" unless raw_lines.is_a?(Array)

        raw_lines.reject(&:blank?).map do |line|
          raise Documents::InvalidDocument, "each line must be an object" unless line.respond_to?(:permit)

          line.permit(:account_code, :amount_minor, :currency, :minor_unit_exponent, :narration, extra: {}).to_h
        end
      end

      def document_json(d)
        { id: d.id, doc_type: d.doc_type, state: d.state, document_number: d.document_number,
          posted_entry_id: d.posted_entry_id, reversed_by_document_id: d.reversed_by_document_id,
          fiscal_year: d.fiscal_year, document_date: d.document_date, posting_date: d.posting_date,
          lines: d.document_lines.map do |line|
            { line_no: line.line_no, account_code: line.account_code, amount_minor: line.amount_minor,
              currency: line.currency, minor_unit_exponent: line.minor_unit_exponent }
          end }
      end
    end
  end
end
