# frozen_string_literal: true

module Api
  module V1
    class DocumentTypesController < BaseController
      def index
        render json: { document_types: DocumentType.where(tenant_id: Current.tenant.id, active: true).order(:code)
          .map { |d| { id: d.id, code: d.code, label: d.label, posting_rule: d.posting_rule } } }
      end
    end
  end
end
