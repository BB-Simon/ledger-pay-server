require "rails_helper"

# OpenAPI document for the API, built by rswag from the doc specs in
# spec/requests/. Regenerate swagger/v1/swagger.yaml with:
#   RAILS_ENV=test RSWAG_DRY_RUN=0 bin/rails rswag:specs:swaggerize
#
# Schemas mirror each controller's private *_json method. They use
# additionalProperties: false, so a spec fails if an endpoint starts
# returning a field that isn't documented (AGENTS.md: never leak internal
# fields). Fields a controller drops with .compact are not `required`.
module ApiSchemas
  def self.object(properties, required: properties.keys)
    { type: :object, additionalProperties: false, properties: properties, required: required }
  end

  CENTS = { type: :integer, description: "Amount in minor units (cents)" }.freeze
  NULLABLE_STRING = { type: :string, nullable: true }.freeze
  NULLABLE_CENTS = CENTS.merge(nullable: true).freeze
  TIMESTAMP = { type: :string, format: "date-time" }.freeze
  NULLABLE_TIMESTAMP = TIMESTAMP.merge(nullable: true).freeze

  SCHEMAS = {
    Error: object({ error: { type: :string } }),
    ValidationErrors: object({ errors: { type: :array, items: { type: :string } } }),
    RailsNotFound: object(
      { status: { type: :integer, example: 404 }, error: { type: :string, example: "Not Found" } }
    ).merge(description: "Rails' default body for a record that doesn't exist (not the usual { error } shape)"),

    User: object({
      id: { type: :integer },
      email: { type: :string, format: :email },
      status: { type: :string, example: "active" }
    }),
    UserProfile: object({
      id: { type: :integer },
      email: { type: :string, format: :email },
      status: { type: :string },
      created_at: TIMESTAMP,
      updated_at: TIMESTAMP
    }),
    AuthSession: object({
      token: { type: :string, description: "Opaque bearer token. Shown once; only its digest is stored." },
      user: { "$ref" => "#/components/schemas/User" }
    }),
    Kyc: object({
      status: { type: :string, enum: %w[pending verified rejected under_review] },
      verification_level: NULLABLE_STRING,
      verified_at: NULLABLE_TIMESTAMP
    }),

    TransferTransaction: object({
      id: { type: :integer },
      reference: { type: :string },
      status: { type: :string, enum: %w[pending posted failed] },
      transaction_type: { type: :string, example: "transfer" }
    }),
    Payment: object(
      {
        id: { type: :integer },
        amount: CENTS,
        status: { type: :string, enum: %w[pending succeeded failed canceled] },
        currency: { type: :string, example: "USD" },
        provider: { type: :string, example: "stripe" },
        provider_payment_id: { type: :string },
        failure_code: { type: :string },
        failure_message: { type: :string },
        client_secret: { type: :string, description: "Only on create. Confirm the payment with Stripe.js." },
        refunded_amount: CENTS,
        refundable_amount: CENTS
      },
      required: %i[id amount status currency provider refunded_amount refundable_amount]
    ),
    Refund: object(
      {
        id: { type: :integer },
        payment_id: { type: :integer },
        amount: CENTS,
        currency: { type: :string },
        provider: { type: :string },
        provider_refund_id: { type: :string },
        status: { type: :string, enum: %w[pending succeeded failed canceled] },
        reason: { type: :string }
      },
      required: %i[id payment_id amount currency provider status]
    ),
    Withdrawal: object(
      {
        id: { type: :integer },
        wallet_id: { type: :integer },
        amount: CENTS,
        currency: { type: :string },
        provider: { type: :string },
        provider_withdrawal_id: { type: :string },
        status: { type: :string, enum: %w[pending succeeded failed canceled] },
        failure_code: { type: :string },
        failure_message: { type: :string }
      },
      required: %i[id wallet_id amount currency provider status]
    ),

    ReconciliationRecord: object({
      id: { type: :integer },
      provider: { type: :string },
      provider_reference: { type: :string },
      record_type: { type: :string, enum: %w[payment refund payout] },
      internal_type: NULLABLE_STRING,
      internal_id: { type: :integer, nullable: true },
      expected_amount: NULLABLE_CENTS,
      actual_amount: NULLABLE_CENTS,
      currency: NULLABLE_STRING,
      status: { type: :string, enum: %w[matched discrepancy unresolved] },
      discrepancy_type: {
        type: :string, nullable: true,
        enum: [ "missing_internal_record", "missing_provider_record", "amount_mismatch", "currency_mismatch", "status_mismatch", nil ]
      },
      details: { type: :object, nullable: true },
      created_at: TIMESTAMP
    }),
    ReconciliationRun: object({
      id: { type: :integer },
      provider: { type: :string },
      run_type: { type: :string, enum: %w[payments refunds payouts] },
      status: { type: :string, enum: %w[pending running completed failed] },
      total_items: { type: :integer },
      records_checked: { type: :integer },
      matched_count: { type: :integer },
      discrepancy_count: { type: :integer },
      failed_count: { type: :integer },
      started_at: NULLABLE_TIMESTAMP,
      completed_at: NULLABLE_TIMESTAMP,
      error_message: NULLABLE_STRING
    }),
    ReconciliationRunItem: object({
      id: { type: :integer },
      record_type: { type: :string, enum: %w[payment refund payout] },
      internal_type: { type: :string },
      internal_id: { type: :integer, nullable: true },
      provider_reference: NULLABLE_STRING,
      status: { type: :string, enum: %w[pending processing matched discrepancy failed] },
      attempts: { type: :integer },
      started_at: NULLABLE_TIMESTAMP,
      completed_at: NULLABLE_TIMESTAMP,
      error_class: NULLABLE_STRING,
      error_message: NULLABLE_STRING
    })
  }.freeze

  PARAMETERS = {
    IdempotencyKeyRequired: {
      name: "Idempotency-Key", in: :header, required: true, schema: { type: :string },
      description: "Required. A retry with the same key and the same body returns the original result; " \
                   "the same key with a different body gets 422."
    },
    IdempotencyKeyOptional: {
      name: "Idempotency-Key", in: :header, required: false, schema: { type: :string },
      description: "Optional but recommended. A retry with the same key and the same body returns the " \
                   "original record instead of creating another; the same key with a different body gets 422."
    },
    StripeSignature: {
      name: "Stripe-Signature", in: :header, required: true, schema: { type: :string },
      description: "Set by Stripe. Verified against STRIPE_WEBHOOK_SECRET."
    }
  }.freeze
end

RSpec.configure do |config|
  config.openapi_root = Rails.root.join("swagger").to_s
  config.openapi_format = :yaml

  config.openapi_specs = {
    "v1/swagger.yaml" => {
      openapi: "3.0.3",
      info: {
        title: "Ledger Pay API",
        version: "v1",
        description: <<~MARKDOWN
          Wallet and payments API with a double-entry ledger.

          - **Amounts** are integers in minor units (cents). Decimals are rejected with 422.
          - **Auth:** send `Authorization: Bearer <token>`. The token comes from `POST /api/v1/auth/login`.
            It's an opaque token, not a JWT.
          - **Idempotency:** money-moving requests take an `Idempotency-Key` header (required for transfers).
          - **Errors** are `{ "error": "message" }`. Two exceptions: registration validation returns
            `{ "errors": [...] }`, and a record that doesn't exist returns Rails' default
            `{ "status": 404, "error": "Not Found" }`.
          - **Settlement:** payments, refunds and payouts are created `pending`. Stripe webhooks move them to
            their final status; the ledger only changes then.
        MARKDOWN
      },
      servers: [ { url: "http://localhost:3000", description: "Local development" } ],
      tags: [
        { name: "Auth", description: "Register and log in" },
        { name: "Account", description: "The current user and KYC" },
        { name: "Transfers", description: "Wallet-to-wallet transfers" },
        { name: "Payments", description: "Card payments into a wallet, and refunds" },
        { name: "Withdrawals", description: "Payouts from a wallet to a bank account" },
        { name: "Webhooks", description: "Called by Stripe, not by clients" },
        { name: "Admin: Reconciliation", description: "Admin only. Reconciliation against Stripe" }
      ],
      security: [ { bearer_auth: [] } ],
      paths: {},
      components: {
        securitySchemes: {
          bearer_auth: { type: :http, scheme: :bearer, bearerFormat: "opaque token" }
        },
        schemas: ApiSchemas::SCHEMAS.deep_dup,
        parameters: ApiSchemas::PARAMETERS.deep_dup
      }
    }
  }
end
