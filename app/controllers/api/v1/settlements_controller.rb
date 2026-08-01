# frozen_string_literal: true

module Api
  module V1
    class SettlementsController < BaseController
      KINDS = ::SettlementsController::KINDS.freeze

      before_action -> { require_capability!("reports.read") }, only: %i[index show]
      before_action -> { require_capability!("payments.create") }, only: %i[create post reset reallocate]
      before_action :set_document, only: %i[show post reset reallocate]

      def index
        documents = document_scope.order(document_date: :desc, created_at: :desc)
        render json: { settlements: documents.map { |document| document_json(document) } }
      end

      def show
        render json: { settlement: document_json(@document) }
      end

      def create
        document = Settlements::BuildDraft.call(
          tenant: Current.tenant,
          doc_type: KINDS.fetch(params[:kind].to_s) do
            raise Settlements::InvalidSettlement, "choose receipt or payment"
          end,
          document_date: params[:document_date],
          bank_account_code: params[:bank_account_code],
          narration: params[:narration],
          allocations: allocations_params
        )
        render json: { settlement: document_json(document) }, status: :created
      end

      def post
        entry = Documents::Post.call(
          @document,
          actor: "u:#{current_user.id}",
          authorize: { user: current_user },
          required_capability: "payments.create"
        )
        render json: { settlement: document_json(@document.reload), entry_id: entry.id }
      end

      def reset
        allocation = Settlements::ResetAllocation.call(
          document: @document, allocation_id: params[:allocation_id],
          actor: "u:#{current_user.id}", user: current_user,
          reset_on: [ business_date, @document.document_date ].max
        )
        render json: { allocation: allocation_json(allocation) }
      end

      def reallocate
        reallocation = Settlements::Reallocate.call(
          document: @document, allocation_id: params[:allocation_id],
          target_entry_line_id: params[:target_entry_line_id],
          clearing_mode: params[:clearing_mode],
          actor: "u:#{current_user.id}", user: current_user,
          applied_on: [ business_date, @document.document_date ].max
        )
        render json: {
          reallocation: {
            id: reallocation.id, target: reallocation.target_snapshot,
            amount_minor: reallocation.amount_minor,
            clearing_mode: reallocation.clearing_mode, applied: true
          }
        }
      end

      private

      def set_document
        @document = document_scope.find(params[:id])
      end

      def document_scope
        Document.where(tenant_id: Current.tenant.id, doc_type: KINDS.values)
      end

      def allocations_params
        raw = params[:allocations]
        raise Settlements::InvalidSettlement, "allocations must be an array" unless raw.is_a?(Array)

        raw.map do |allocation|
          unless allocation.respond_to?(:permit)
            raise Settlements::InvalidSettlement, "each allocation must be an object"
          end

          allocation.permit(:target_entry_line_id, :amount, :clearing_mode).to_h
        end
      end

      def document_json(document)
        {
          id: document.id,
          kind: KINDS.key(document.doc_type),
          state: document.state,
          document_number: document.document_number,
          document_date: document.document_date,
          currency: document.currency,
          total_minor: document.total_minor,
          party: document.party_snapshot,
          bank_account_code: document.document_lines.first.account_code,
          allocations: document.document_allocations.map { |allocation| allocation_json(allocation) }
        }
      end

      def allocation_json(allocation)
        reallocation = allocation.settlement_reallocation
        {
          id: allocation.id,
          line_no: allocation.line_no,
          target: allocation.target_snapshot,
          amount_minor: allocation.amount_minor,
          clearing_mode: allocation.clearing_mode,
          status: reallocation ? "reapplied" : allocation.reset? ? "unapplied" : "applied",
          reallocation_target: reallocation&.target_snapshot
        }.compact
      end
    end
  end
end
