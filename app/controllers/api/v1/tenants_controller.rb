# frozen_string_literal: true

module Api
  module V1
    # The caller's current (resolved, membership-scoped) tenant.
    class TenantsController < BaseController
      def show
        render json: { tenant: tenant_json(Current.tenant) }
      end

      private

      def tenant_json(t)
        { id: t.id, name: t.name, slug: t.slug, functional_currency: t.functional_currency }
      end
    end
  end
end
