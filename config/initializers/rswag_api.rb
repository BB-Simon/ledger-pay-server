# Serves the generated OpenAPI file (swagger/v1/swagger.yaml) at
# /api-docs/v1/swagger.yaml. The rswag gems are development/test only, so
# this does nothing in production (see config/routes.rb).
if defined?(Rswag::Api)
  Rswag::Api.configure do |config|
    config.openapi_root = Rails.root.join("swagger").to_s
  end
end
