# syntax=docker/dockerfile:1

FROM ruby:3.4.10-slim@sha256:614edae6a80eb2a7cf1984f03a6d814f523a48355e8f96deb5ddd25faa86353e AS base

WORKDIR /rails

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    MALLOC_ARENA_MAX="2"

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libpq5 postgresql-client && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf ~/.bundle "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git

COPY . .

# Asset compilation boots production configuration. These build-only values satisfy the same
# fail-closed validator as runtime without embedding a usable credential in the image.
RUN SECRET_KEY_BASE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    FOLIO_DATABASE_PASSWORD=build-only-database-password \
    FOLIO_APP_HOST=build.folio.test \
    FOLIO_MAIL_FROM=build@folio.test \
    FOLIO_SMTP_ADDRESS=smtp.folio.test \
    FOLIO_SMTP_USERNAME=build-account \
    FOLIO_SMTP_PASSWORD=build-only-smtp-password \
    bin/rails assets:precompile

FROM base

COPY --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --from=build /rails /rails

RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    mkdir -p log storage tmp && \
    chown -R rails:rails db log storage tmp
USER 1000:1000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl --fail --silent --show-error http://127.0.0.1:80/up || exit 1
CMD ["bin/thrust", "bin/rails", "server"]
