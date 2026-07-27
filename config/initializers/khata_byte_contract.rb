# frozen_string_literal: true

# Folio's event hashes must be byte-identical to Bahi's. They are not, by default.
#
# ActiveSupport overrides String#to_json and, with the Rails default
# `escape_html_entities_in_json = true`, encodes `&`, `<` and `>` as &, <
# and >. Plain Ruby's JSON does not. The .khata canonical-JSON contract
# (conformance/spec/canonical-json.md) is defined in terms of plain JSON scalar
# encoding, so under Rails every event whose payload contains one of those three
# characters hashes to a DIFFERENT value than the identical event in Bahi — and the
# two engines silently fork.
#
# This was found by the conformance corpus, not by unit tests, and that is the point:
# it first bites on `{"name":"Health & Glow Pharmacy"}` — a real Indian customer name
# in corpus/files/pharma.khata. Synthetic fixtures with tidy ASCII names pass forever.
#
# The escaping exists to make JSON safe to interpolate into HTML. Folio does not do
# that, so disabling it costs nothing and buys byte-exactness with the format spec.
# If a future surface ever inlines JSON into markup, escape at that call site.
ActiveSupport.escape_html_entities_in_json = false
