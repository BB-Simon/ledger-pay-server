---
name: new-endpoint
description: Add or change an Api::V1 endpoint in this Rails API (route, thin controller, service object, JSON response, integration test). Use when asked to add an endpoint, route, controller action, or admin API.
---

# Add an Api::V1 endpoint

Follow AGENTS.md. Use `app/controllers/api/v1/withdrawals_controller.rb` (user-scoped) and `app/controllers/api/v1/admin/reconciliation_runs_controller.rb` (admin) as the reference implementations.

## 0. Before writing code
- Read the related model(s), any existing service in `app/services/<domain>/`, and `config/routes.rb`.
- If this changes an existing endpoint's fields, status codes or behavior, it's a breaking change: stop and ask.
- Anything beyond a small change: propose a short plan (route, controller action, service, response fields, tests) and wait for approval.

## 1. Route (`config/routes.rb`)
- Put it inside `namespace :api { namespace :v1 { ... } }`, and inside `namespace :admin` for admin-only endpoints.
- Prefer `resources ... only: [...]` with nested/member routes. Custom verbs (`post ".../resolve"`) only when no RESTful option fits.
- Check with `bin/rails routes -g <name>`.

## 2. Controller
```ruby
module Api
  module V1
    class ThingsController < ApplicationController
      before_action :authenticate_user!
      # before_action :require_admin!   # admin endpoints

      def create
        wallet = current_user.wallets.find(params[:wallet_id])   # always scope to caller

        thing = Things::CreateThing.call(
          user: current_user,
          wallet: wallet,
          amount: params[:amount].to_i                            # money = integer cents
        )

        render json: thing_json(thing), status: :created
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def index
        things = current_user.things.order(created_at: :desc).limit(100)  # always bounded
        render json: things.map { |t| thing_json(t) }
      end

      private

      def thing_json(thing)
        { id: thing.id, amount: thing.amount, currency: thing.currency.code, status: thing.status }
      end
    end
  end
end
```
Rules:
- The controller only parses params, looks up records scoped to `current_user`, calls one service, and renders. No business logic.
- If an unscoped lookup is intentional (e.g. a transfer destination wallet), add a comment saying why.
- Responses are allowlisted hashes built in a private `*_json` method. Never `render json: model`, and never expose digests, tokens or raw webhook payloads.
- Errors are `{ error: "<message>" }`. 404 comes from `find` raising `RecordNotFound`, and 422 comes from `ArgumentError`.
- Use `includes` for associations used in `*_json` on index actions.
- Public endpoints (no `authenticate_user!`) need explicit approval.
- Money-moving `create` actions must accept the `Idempotency-Key` header and go through an idempotent service (see `Ledger::IdempotentTransfer`).

## 3. Service (`app/services/<domain>/<verb_noun>.rb`)
```ruby
module Things
  class CreateThing
    def self.call(user:, wallet:, amount:)
      new(user:, wallet:, amount:).call
    end

    def initialize(user:, wallet:, amount:)
      @user, @wallet, @amount = user, wallet, amount
    end

    def call
      validate!
      thing = Thing.transaction do
        # lock + re-check if this changes state of an existing record
        Thing.create!(...)
      end
      AuditLogs::Record.call(action: "thing.created", auditable: thing, user: @user, metadata: { amount: @amount })
      thing
    end

    private

    def validate!
      raise ArgumentError, "Amount must be a positive integer" unless @amount.is_a?(Integer) && @amount.positive?
      raise ArgumentError, "Wallet must belong to user" unless @wallet.user_id == @user.id
    end
  end
end
```
- Business-rule failures raise `ArgumentError` with a user-safe message.
- If it moves money, use the `ledger-operation` skill. If it calls Stripe, create the local `pending` record first and pass its id in Stripe `metadata`.

## 4. Tests
Also document the endpoint: add or update its rswag doc spec in `spec/requests/api/v1/...` (every status code the code returns, response schemas from `spec/swagger_helper.rb` with `additionalProperties: false`), then regenerate and commit the YAML with `RAILS_ENV=test RSWAG_DRY_RUN=0 bin/rails rswag:specs:swaggerize`. See `docs/TESTING.md` section 16.

Use the `write-tests` skill. Add an integration test in `test/controllers/api/v1/...` covering:
- the happy path, including status code and exact response keys
- 401 with no token or an expired token
- 403 for non-admins on admin endpoints
- 404 for another user's record (proves the lookup is scoped)
- 422 for invalid input (`{ "error" => ... }`)

## 5. Finish
Run the `verify` skill and report the files changed, commands run and results.
