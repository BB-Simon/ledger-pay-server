require "test_helper"

# Customer-versus-admin permissions across the whole API.
#
# The 401 and 403 checks walk the real route table, so a new endpoint is
# covered automatically: forgetting authenticate_user! or require_admin!
# fails here. The 404 checks prove a customer can't reach another
# customer's records and that nothing is created or moved when they try.
class AuthorizationTest < ActionDispatch::IntegrationTest
  PUBLIC_PATHS = %w[
    /api/v1/auth/register
    /api/v1/auth/login
    /api/v1/webhooks/stripe
  ].freeze

  # [verb, path] for every API route, with path parameters filled in.
  def self.api_routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      next unless path.start_with?("/api/v1/")

      [ route.verb, path.gsub(/:\w+/, "1") ]
    end
  end

  def auth_headers(user)
    raw_token = SecureRandom.hex(32)
    AuthToken.create!(user: user, token_digest: Digest::SHA256.hexdigest(raw_token), expires_at: 1.day.from_now)
    { "Authorization" => "Bearer #{raw_token}" }
  end

  def call_route(verb, path, headers: {})
    process(verb.downcase.to_sym, path, headers: headers, as: :json)
  end

  # Any attempt to reach Stripe fails the test: a refused request must stop
  # before an external call.
  def forbid_stripe(&block)
    refuse = ->(_original, *) { flunk "Stripe must not be called" }
    with_class_method(Stripe::PaymentIntent, :create, refuse) do
      with_class_method(Stripe::Refund, :create, refuse) do
        with_class_method(Stripe::Payout, :create, refuse, &block)
      end
    end
  end

  setup do
    @alice = auth_headers(users(:alice))

    @bob_payment = Payment.create!(user: users(:bob), wallet: wallets(:bob_usd), currency: currencies(:usd),
      amount: 1_000, provider: "stripe", provider_payment_id: "pi_bob", status: :succeeded)
    Ledger::Deposit.call(wallet: wallets(:bob_usd), amount: 1_000, reference: "PAYMENT-#{@bob_payment.id}")
    @bob_withdrawal = Withdrawal.create!(user: users(:bob), wallet: wallets(:bob_usd), currency: currencies(:usd),
      amount: 100, provider: "stripe", provider_withdrawal_id: "po_bob", status: :pending)
  end

  test "the route table is what these checks expect" do
    routes = self.class.api_routes

    assert_operator routes.size, :>=, 19
    PUBLIC_PATHS.each { |path| assert routes.any? { |_, route_path| route_path == path }, "#{path} missing" }
  end

  test "every non-public endpoint rejects a request without a token" do
    self.class.api_routes.reject { |_, path| PUBLIC_PATHS.include?(path) }.each do |verb, path|
      call_route(verb, path)

      assert_equal 401, response.status, "#{verb} #{path} should require authentication"
      assert_equal({ "error" => "Authentication required" }, response.parsed_body, "#{verb} #{path}")
    end
  end

  test "every non-public endpoint rejects an expired token" do
    raw_token = SecureRandom.hex(32)
    AuthToken.create!(user: users(:alice), token_digest: Digest::SHA256.hexdigest(raw_token), expires_at: 1.minute.ago)

    self.class.api_routes.reject { |_, path| PUBLIC_PATHS.include?(path) }.each do |verb, path|
      call_route(verb, path, headers: { "Authorization" => "Bearer #{raw_token}" })

      assert_equal 401, response.status, "#{verb} #{path}"
    end
  end

  test "every admin endpoint refuses customers" do
    admin_routes = self.class.api_routes.select { |_, path| path.start_with?("/api/v1/admin/") }
    assert_equal 6, admin_routes.size

    admin_routes.each do |verb, path|
      call_route(verb, path, headers: @alice)

      assert_equal 403, response.status, "#{verb} #{path} should be admin only"
      assert_equal({ "error" => "Admin access required" }, response.parsed_body, "#{verb} #{path}")
    end
  end

  test "admins can use the admin endpoints" do
    admin = auth_headers(users(:admin))

    call_route("GET", "/api/v1/admin/reconciliation_records", headers: admin)
    assert_response :success
    call_route("GET", "/api/v1/admin/reconciliation_runs", headers: admin)
    assert_response :success
  end

  test "a customer can't read another customer's payment, refunds or withdrawal" do
    [
      "/api/v1/payments/#{@bob_payment.id}",
      "/api/v1/payments/#{@bob_payment.id}/refunds",
      "/api/v1/withdrawals/#{@bob_withdrawal.id}"
    ].each do |path|
      get path, headers: @alice

      assert_response :not_found, path
    end
  end

  test "a customer's withdrawal list only contains their own" do
    Withdrawal.create!(user: users(:alice), wallet: wallets(:alice_usd), currency: currencies(:usd),
      amount: 50, provider: "stripe", status: :pending)

    get "/api/v1/withdrawals", headers: @alice

    assert_response :success
    assert_equal [ wallets(:alice_usd).id ], response.parsed_body.map { |withdrawal| withdrawal["wallet_id"] }.uniq
  end

  test "a customer can't move money using another customer's wallet or payment" do
    forbid_stripe do
      assert_no_difference [ -> { Payment.count }, -> { Refund.count }, -> { Withdrawal.count }, -> { LedgerEntry.count } ] do
        post "/api/v1/payments", params: { wallet_id: wallets(:bob_usd).id, amount: 500 }, headers: @alice, as: :json
        assert_response :not_found

        post "/api/v1/payments/#{@bob_payment.id}/refunds", params: { amount: 500 }, headers: @alice, as: :json
        assert_response :not_found

        post "/api/v1/wallets/#{wallets(:bob_usd).id}/withdrawals", params: { amount: 500 }, headers: @alice, as: :json
        assert_response :not_found

        post "/api/v1/transfers", params: { from_wallet_id: wallets(:bob_usd).id, to_wallet_id: wallets(:alice_usd).id, amount: 500 },
          headers: @alice.merge("Idempotency-Key" => "steal"), as: :json
        assert_response :not_found
      end
    end

    assert_equal 1_000, balance_of(:bob_usd)
  end

  test "admins get no extra access to customers' records through customer endpoints" do
    admin = auth_headers(users(:admin))

    get "/api/v1/payments/#{@bob_payment.id}", headers: admin
    assert_response :not_found

    get "/api/v1/withdrawals", headers: admin
    assert_response :success
    assert_equal [], response.parsed_body
  end
end
