# frozen_string_literal: true

class AccessReviewsController < BrowserController
  before_action -> { require_capability!("grc.read") }, only: :show
  before_action -> { require_capability!("grc.manage") }, only: %i[create attest]

  def show
    @findings = Grc::Analyze.call(tenant: Current.tenant)
    @summary = Grc::Analyze.summary(@findings)
    @reviews = AccessReviewRun.where(tenant_id: Current.tenant.id)
      .includes(:created_by, access_review_attestation: :attested_by).order(created_at: :desc)
  end

  def create
    review = Grc::Reviews.capture!(tenant: Current.tenant, actor: Current.user)
    redirect_to access_review_path(tenant_route_options),
      notice: "Access review captured with #{review.snapshot.dig('summary', 'total')} findings."
  rescue Grc::InvalidReview, ActiveRecord::RecordInvalid => e
    redirect_to access_review_path(tenant_route_options), alert: e.message
  end

  def attest
    review = AccessReviewRun.where(tenant_id: Current.tenant.id).find(params[:id])
    Grc::Reviews.attest!(
      review: review, actor: Current.user,
      outcome: params[:outcome], notes: params[:notes]
    )
    redirect_to access_review_path(tenant_route_options), notice: "Access review attested."
  rescue Grc::InvalidReview, ActiveRecord::RecordInvalid => e
    redirect_to access_review_path(tenant_route_options), alert: e.message
  end
end
