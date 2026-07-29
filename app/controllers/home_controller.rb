# frozen_string_literal: true

# The authenticated landing. Minimal for now — the app UI (Phase C) replaces it; it exists so
# there is a `root_url` for the auth flow to return to after login.
class HomeController < ApplicationController
  def show
  end
end
