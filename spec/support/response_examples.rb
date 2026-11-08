# Stores each documented response's real JSON body as its example in the
# generated swagger.yaml (rswag merges the response schema in next to it).
# Only takes effect when the specs actually run:
#   RAILS_ENV=test RSWAG_DRY_RUN=0 bin/rails rswag:specs:swaggerize
#
# The YAML is committed and CI checks it's up to date, so examples must be
# the same on every run: time is frozen for request specs, and the few
# random values are replaced with placeholders. Ids are already stable
# (loading fixtures resets the sequences; swaggerize runs in defined order).
module ResponseExamples
  FROZEN_TIME = Time.utc(2026, 1, 15, 12, 0, 0)

  PLACEHOLDERS = {
    "token" => "<64 hex characters, shown once>",
    "reference" => "8b1d3c52-0d6e-4f3a-9c51-2f7e1a9b6c40"
  }.freeze

  def self.stabilize(value)
    case value
    when Hash then value.to_h { |key, inner| [ key, PLACEHOLDERS.fetch(key) { stabilize(inner) } ] }
    when Array then value.map { |inner| stabilize(inner) }
    else value
    end
  end
end

RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers, type: :request

  config.around(type: :request) do |example|
    travel_to(ResponseExamples::FROZEN_TIME) { example.run }
  end

  config.after(type: :request) do |example|
    next unless example.metadata[:response] && response&.body.present?

    content = (example.metadata[:response][:content] ||= {})
    (content["application/json"] ||= {})[:example] = ResponseExamples.stabilize(JSON.parse(response.body))
  rescue JSON::ParserError
    nil
  end
end
