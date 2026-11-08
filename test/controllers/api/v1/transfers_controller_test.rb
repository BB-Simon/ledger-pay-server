require "test_helper"

class Api::V1::TransfersControllerTest < ActionDispatch::IntegrationTest
  setup do
    Ledger::Deposit.call(wallet: wallets(:alice_usd), amount: 1_000, reference: "TEST-FUND-ALICE")
    @headers = auth_headers(users(:alice))
  end

  def auth_headers(user)
    raw_token = SecureRandom.hex(32)
    AuthToken.create!(user: user, token_digest: Digest::SHA256.hexdigest(raw_token), expires_at: 1.day.from_now)
    { "Authorization" => "Bearer #{raw_token}" }
  end

  def post_transfer(headers:, amount: 300)
    post "/api/v1/transfers",
      params: { from_wallet_id: wallets(:alice_usd).id, to_wallet_id: wallets(:bob_usd).id, amount: amount },
      headers: headers
  end

  test "transfers money and returns the transaction" do
    post_transfer(headers: @headers.merge("Idempotency-Key" => "key-1"))

    assert_response :created
    body = response.parsed_body
    assert_equal %w[id reference status transaction_type], body.keys.sort
    assert_equal "transfer", body["transaction_type"]
    assert_equal 700, accounts(:alice_usd).reload.balance
    assert_equal 300, accounts(:bob_usd).reload.balance
  end

  test "a retry with the same key returns the same transaction and moves money once" do
    post_transfer(headers: @headers.merge("Idempotency-Key" => "key-2"))
    first_id = response.parsed_body["id"]

    post_transfer(headers: @headers.merge("Idempotency-Key" => "key-2"))

    assert_response :created
    assert_equal first_id, response.parsed_body["id"]
    assert_equal 700, accounts(:alice_usd).reload.balance
  end

  test "a missing Idempotency-Key header is rejected with 422 and moves nothing" do
    assert_no_difference -> { LedgerEntry.count } do
      post_transfer(headers: @headers)
    end

    assert_response :unprocessable_entity
    assert_equal({ "error" => "Idempotency-Key header is required" }, response.parsed_body)
  end

  test "a blank Idempotency-Key header is rejected with 422" do
    post_transfer(headers: @headers.merge("Idempotency-Key" => "  "))

    assert_response :unprocessable_entity
    assert_equal "Idempotency-Key header is required", response.parsed_body["error"]
  end

  test "requires authentication" do
    post_transfer(headers: { "Idempotency-Key" => "key-3" })

    assert_response :unauthorized
  end

  test "can't send from another customer's wallet" do
    post "/api/v1/transfers",
      params: { from_wallet_id: wallets(:bob_usd).id, to_wallet_id: wallets(:alice_usd).id, amount: 100 },
      headers: @headers.merge("Idempotency-Key" => "key-4")

    assert_response :not_found
    assert_equal 0, accounts(:bob_usd).reload.balance
  end
  # M12: amounts that aren't whole numbers of cents are rejected, not truncated.
  [ "10.99", "1e3", "abc", "", "0x1A", " 3 00" ].each do |bad_amount|
    test "rejects the amount #{bad_amount.inspect} without moving money" do
      assert_no_difference -> { LedgerEntry.count } do
        post_transfer(headers: @headers.merge("Idempotency-Key" => "bad-#{bad_amount}"), amount: bad_amount)
      end

      assert_response :unprocessable_entity
      assert_equal "Amount must be a positive integer", response.parsed_body["error"]
    end
  end

  test "accepts an amount sent as a JSON integer" do
    post "/api/v1/transfers",
      params: { from_wallet_id: wallets(:alice_usd).id, to_wallet_id: wallets(:bob_usd).id, amount: 250 }.to_json,
      headers: @headers.merge("Idempotency-Key" => "json-int", "Content-Type" => "application/json")

    assert_response :created
    assert_equal 250, accounts(:bob_usd).reload.balance
  end

  test "rejects an amount sent as a JSON decimal" do
    post "/api/v1/transfers",
      params: { from_wallet_id: wallets(:alice_usd).id, to_wallet_id: wallets(:bob_usd).id, amount: 10.99 }.to_json,
      headers: @headers.merge("Idempotency-Key" => "json-float", "Content-Type" => "application/json")

    assert_response :unprocessable_entity
  end
end
