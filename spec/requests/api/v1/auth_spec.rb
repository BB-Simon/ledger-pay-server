require "swagger_helper"

RSpec.describe "Auth", type: :request do
  path "/api/v1/auth/register" do
    post "Register a new user" do
      tags "Auth"
      description "Creates the user with a pending KYC profile and a USD wallet. Rate limited to 10 requests a minute per IP."
      security []
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          email: { type: :string, format: :email, example: "carol@example.com" },
          password: { type: :string, format: :password, example: "password123" }
        },
        required: %w[email password]
      }

      response "201", "user registered" do
        schema type: :object, additionalProperties: false,
          properties: { user: { "$ref" => "#/components/schemas/User" } }, required: %w[user]
        let(:body) { { email: "carol@example.com", password: "password123" } }

        run_test!
      end

      response "422", "invalid email or password" do
        schema "$ref" => "#/components/schemas/ValidationErrors"
        let(:body) { { email: "", password: "password123" } }

        run_test!
      end

      response "429", "too many requests from this IP" do
        schema "$ref" => "#/components/schemas/Error"
        let(:body) { { email: "one-too-many@example.com", password: "password123" } }

        before do
          10.times { |i| post "/api/v1/auth/register", params: { email: "user#{i}@example.com", password: "password123" } }
        end

        run_test!
      end
    end
  end

  path "/api/v1/auth/login" do
    post "Log in" do
      tags "Auth"
      description "Returns a bearer token valid for 7 days. Every failure gets the same 401, so responses don't reveal " \
                  "which emails exist. Rate limited to 10 requests a minute per IP."
      security []
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          email: { type: :string, format: :email, example: "alice@example.com" },
          password: { type: :string, format: :password, example: "password" }
        },
        required: %w[email password]
      }

      response "200", "logged in" do
        schema "$ref" => "#/components/schemas/AuthSession"
        let(:body) { { email: "alice@example.com", password: "password" } }

        run_test!
      end

      response "401", "wrong email or password, or the account isn't active" do
        schema "$ref" => "#/components/schemas/Error"
        let(:body) { { email: "alice@example.com", password: "wrong" } }

        run_test!
      end

      response "429", "too many requests from this IP" do
        schema "$ref" => "#/components/schemas/Error"
        let(:body) { { email: "alice@example.com", password: "password" } }

        before do
          10.times { post "/api/v1/auth/login", params: { email: "alice@example.com", password: "wrong" } }
        end

        run_test!
      end
    end
  end
end
