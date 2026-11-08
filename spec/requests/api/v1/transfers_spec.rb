require "swagger_helper"

RSpec.describe "Transfers", type: :request do
  let(:Authorization) { bearer_for(users(:alice)) }
  let(:"Idempotency-Key") { "transfer-#{SecureRandom.hex(4)}" }
  let(:body) { { from_wallet_id: wallets(:alice_usd).id, to_wallet_id: wallets(:bob_usd).id, amount: 300 } }

  before { Ledger::Deposit.call(wallet: wallets(:alice_usd), amount: 1_000, reference: "SPEC-FUND-ALICE") }

  path "/api/v1/transfers" do
    post "Transfer money to another wallet" do
      tags "Transfers"
      description "Moves money between two wallets in the same currency. Only money not held by pending " \
                  "withdrawals or refunds can be sent. Both wallets must be active."
      consumes "application/json"
      produces "application/json"
      parameter "$ref" => "#/components/parameters/IdempotencyKeyRequired"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: {
          from_wallet_id: { type: :integer, description: "One of your wallets" },
          to_wallet_id: { type: :integer, description: "Any active wallet in the same currency" },
          amount: { type: :integer, minimum: 1, description: "Cents" }
        },
        required: %w[from_wallet_id to_wallet_id amount]
      }

      response "201", "transferred" do
        schema "$ref" => "#/components/schemas/TransferTransaction"

        run_test! do
          expect(accounts(:bob_usd).reload.balance).to eq(300)
        end
      end

      response "401", "not logged in" do
        schema "$ref" => "#/components/schemas/Error"
        let(:Authorization) { nil }

        run_test!
      end

      response "404", "the source wallet isn't yours, or a wallet doesn't exist" do
        schema "$ref" => "#/components/schemas/RailsNotFound"
        let(:body) { { from_wallet_id: wallets(:bob_usd).id, to_wallet_id: wallets(:alice_usd).id, amount: 100 } }

        run_test!
      end

      response "422", "missing Idempotency-Key, invalid amount, insufficient funds, or a key reused with different parameters" do
        schema "$ref" => "#/components/schemas/Error"
        let(:body) { { from_wallet_id: wallets(:alice_usd).id, to_wallet_id: wallets(:bob_usd).id, amount: 5_000 } }

        run_test! do
          expect(response.parsed_body["error"]).to eq("Insufficient balance in source wallet")
        end
      end
    end
  end
end
