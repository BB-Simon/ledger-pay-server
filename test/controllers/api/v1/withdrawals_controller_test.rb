require "test_helper"

class Api::V1::WithdrawalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @wallet = wallets(:alice_usd)
    Ledger::Deposit.call(wallet: @wallet, amount: 1_000, reference: "TEST-FUND-ALICE")

    raw_token = SecureRandom.hex(32)
    AuthToken.create!(user: users(:alice), token_digest: Digest::SHA256.hexdigest(raw_token), expires_at: 1.day.from_now)
    @headers = { "Authorization" => "Bearer #{raw_token}" }
  end

  def post_withdrawal(stripe_result)
    with_class_method(Stripe::Payout, :create, stripe_result) do
      post "/api/v1/wallets/#{@wallet.id}/withdrawals", params: { amount: 400 }, headers: @headers
    end
  end

  test "a Stripe rejection returns 422 with the error shape, not a 500" do
    post_withdrawal(->(_original, *) { raise Stripe::InvalidRequestError.new("No external account", "destination") })

    assert_response :unprocessable_entity
    assert_equal "No external account", response.parsed_body["error"]
    assert @wallet.withdrawals.sole.failed?
  end

  test "an unknown Stripe outcome returns 201 with a pending withdrawal" do
    post_withdrawal(->(_original, *) { raise Stripe::APIConnectionError, "read timeout" })

    assert_response :created
    assert_equal "pending", response.parsed_body["status"]
  end
end
