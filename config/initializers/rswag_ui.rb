# Swagger UI at /api-docs, reading the file served by rswag-api. Development
# and test only (see config/routes.rb).
if defined?(Rswag::Ui)
  Rswag::Ui.configure do |config|
    config.openapi_endpoint "/api-docs/v1/swagger.yaml", "Ledger Pay API v1"
  end
end
