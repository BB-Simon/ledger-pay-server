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
  def post_withdrawal_with(amount: 400, headers: {})
    payout = ->(_original, params, *) { Stripe::Payout.construct_from(id: "po_#{SecureRandom.hex(4)}", amount: params[:amount]) }
    with_class_method(Stripe::Payout, :create, payout) do
      post "/api/v1/wallets/#{@wallet.id}/withdrawals", params: { amount: amount }, headers: @headers.merge(headers)
    end
  end

  # M12
  test "a decimal amount is rejected, not truncated" do
    assert_no_difference -> { Withdrawal.count } do
      post_withdrawal_with(amount: "10.99")
    end

    assert_response :unprocessable_entity
  end

  # M14
  test "the same Idempotency-Key returns the original withdrawal instead of creating another" do
    post_withdrawal_with(headers: { "Idempotency-Key" => "wd-1" })
    first = response.parsed_body

    assert_no_difference -> { Withdrawal.count } do
      post_withdrawal_with(headers: { "Idempotency-Key" => "wd-1" })
    end

    assert_response :created
    assert_equal first["id"], response.parsed_body["id"]
    assert_equal 600, Wallet.find(@wallet.id).available_balance
  end

  test "reusing an Idempotency-Key with a different amount is rejected" do
    post_withdrawal_with(headers: { "Idempotency-Key" => "wd-2" })

    assert_no_difference -> { Withdrawal.count } do
      post_withdrawal_with(amount: 100, headers: { "Idempotency-Key" => "wd-2" })
    end

    assert_response :unprocessable_entity
    assert_match(/different request/, response.parsed_body["error"])
  end

  test "without an Idempotency-Key each request creates a withdrawal, as before" do
    assert_difference -> { Withdrawal.count }, 2 do
      2.times { post_withdrawal_with(amount: 100) }
    end
  end
end
