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
        Documents::Reverse.call(@document, actor: "u:#{current_user.id}")
        render json: { document: document_json(@document.reload) }
      rescue Documents::Reverse::NotReversible => e
        render_error(e.message, :conflict)
      end

      private

      def set_document
        @document = Document.where(tenant_id: Current.tenant.id).find(params[:id])
      end

      def build_document
        type = DocumentType.where(tenant_id: Current.tenant.id).find_by!(code: params[:doc_type])
        ActiveRecord::Base.transaction do
          doc = Document.create!(
            tenant_id: Current.tenant.id, entity_id: 1, office_id: 1,
            doc_type: type.code, document_type_id: type.id, fiscal_year: params[:fiscal_year],
            document_date: params[:document_date], posting_date: params[:posting_date],
            narration: params[:narration], state: "draft"
          )
          Array(params[:lines]).each_with_index do |l, i|
            doc.document_lines.create!(
              tenant_id: Current.tenant.id, line_no: i + 1, account_code: l[:account_code],
              amount_minor: l[:amount_minor], currency: l[:currency] || "INR",
              minor_unit_exponent: l[:minor_unit_exponent] || 2, narration: l[:narration]
            )
          end
          doc
        end
      end

      def document_json(d)
        { id: d.id, doc_type: d.doc_type, state: d.state, document_number: d.document_number,
          posted_entry_id: d.posted_entry_id, reversed_by_document_id: d.reversed_by_document_id,
          lines: d.document_lines.map { |l| { line_no: l.line_no, account_code: l.account_code, amount_minor: l.amount_minor } } }
      end
    end
  end
end
