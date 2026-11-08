require "swagger_helper"

RSpec.describe "Withdrawals", type: :request do
  let(:Authorization) { bearer_for(users(:alice)) }
  let(:wallet) { wallets(:alice_usd) }

  before { Ledger::Deposit.call(wallet: wallet, amount: 1_000, reference: "SPEC-FUND-ALICE") }

  def pending_withdrawal
    Withdrawal.create!(
      user: users(:alice), wallet: wallet, currency: currencies(:usd), amount: 400,
      provider: "stripe", provider_withdrawal_id: "po_doc", status: :pending
    )
  end

  path "/api/v1/wallets/{wallet_id}/withdrawals" do
    parameter name: :wallet_id, in: :path, schema: { type: :integer }

    post "Withdraw to your bank account" do
      tags "Withdrawals"
      description "Holds the amount and sends a Stripe payout. If Stripe doesn't answer, the withdrawal stays " \
                  "pending and is retried in the background. The wallet is debited when Stripe reports the payout paid."
      consumes "application/json"
      produces "application/json"
      parameter "$ref" => "#/components/parameters/IdempotencyKeyOptional"
      parameter name: :body, in: :body, schema: {
        type: :object,
        properties: { amount: { type: :integer, minimum: 1, description: "Cents" } },
        required: %w[amount]
      }
      let(:wallet_id) { wallet.id }
      let(:"Idempotency-Key") { "withdrawal-#{SecureRandom.hex(4)}" }
      let(:body) { { amount: 400 } }

      before do
        allow(Stripe::Payout).to receive(:create).and_return(fake_stripe(Stripe::Payout, id: "po_doc"))
      end

      response "201", "withdrawal created (pending until the payout is paid)" do
        schema "$ref" => "#/components/schemas/Withdrawal"

        run_test!
      end

      response "401", "not logged in" do
        schema "$ref" => "#/components/schemas/Error"
        let(:Authorization) { nil }

        run_test!
      end

      response "404", "the wallet isn't yours" do
        schema "$ref" => "#/components/schemas/RailsNotFound"
        let(:wallet_id) { wallets(:bob_usd).id }

        run_test!
      end

      response "422", "invalid amount, insufficient available balance, or Stripe rejected the payout" do
        schema "$ref" => "#/components/schemas/Error"
        let(:body) { { amount: 5_000 } }

        run_test!
      end
    end
  end

  path "/api/v1/withdrawals" do
    get "List your withdrawals" do
      tags "Withdrawals"
      description "Newest first. Not paginated yet."
      produces "application/json"

      response "200", "your withdrawals" do
        schema type: :array, items: { "$ref" => "#/components/schemas/Withdrawal" }
        before { pending_withdrawal }

        run_test!
      end
    end
  end

  path "/api/v1/withdrawals/{id}" do
    parameter name: :id, in: :path, schema: { type: :integer }

    get "Get one of your withdrawals" do
      tags "Withdrawals"
      produces "application/json"

      response "200", "the withdrawal" do
        schema "$ref" => "#/components/schemas/Withdrawal"
        let(:id) { pending_withdrawal.id }

        run_test!
      end

      response "404", "not found, or not yours" do
        schema "$ref" => "#/components/schemas/RailsNotFound"
        let(:id) { 0 }

        run_test!
      end
    end
  end
end
