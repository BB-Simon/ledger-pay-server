require "swagger_helper"

RSpec.describe "Account", type: :request do
  let(:Authorization) { bearer_for(users(:alice)) }

  path "/api/v1/me" do
    get "Current user" do
      tags "Account"
      produces "application/json"

      response "200", "the logged-in user" do
        schema type: :object, additionalProperties: false,
          properties: { user: { "$ref" => "#/components/schemas/UserProfile" } }, required: %w[user]

        run_test!
      end

      response "401", "missing, unknown or expired token, or the user isn't active" do
        schema "$ref" => "#/components/schemas/Error"
        let(:Authorization) { "Bearer not-a-real-token" }

        run_test!
      end
    end
  end

  path "/api/v1/kyc" do
    get "Current user's KYC profile" do
      tags "Account"
      produces "application/json"

      response "200", "the KYC profile" do
        schema type: :object, additionalProperties: false,
          properties: { kyc: { "$ref" => "#/components/schemas/Kyc" } }, required: %w[kyc]
        before { users(:alice).create_kyc_profile!(status: "pending") }

        run_test!
      end

      response "401", "not logged in" do
        schema "$ref" => "#/components/schemas/Error"
        let(:Authorization) { nil }

        run_test!
      end

      response "404", "the user has no KYC profile" do
        schema "$ref" => "#/components/schemas/Error"

        run_test!
      end
    end
  end
end
