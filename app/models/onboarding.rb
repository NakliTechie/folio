# frozen_string_literal: true

# The onboarding namespace (explicit, so Zeitwerk resolves the nested services). Both paths:
# SignUp (self-serve org creation) and Invite (owner invites into an existing org).
module Onboarding
  module_function

  # A unique, URL-safe tenant slug from the org name.
  def slugify(name)
    base = name.to_s.parameterize.presence || "org"
    slug = base
    n = 1
    while Tenant.exists?(slug: slug)
      n += 1
      slug = "#{base}-#{n}"
    end
    slug
  end
end
