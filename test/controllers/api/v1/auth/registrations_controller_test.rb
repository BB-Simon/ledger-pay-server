require "test_helper"

class Api::V1::Auth::RegistrationsControllerTest < ActionDispatch::IntegrationTest
  def register(email: "carol@example.com", password: "password123")
    post "/api/v1/auth/register", params: { email: email, password: password }
  end

  test "creates the user with a KYC profile and a USD wallet ready for payments" do
    register

    assert_response :created
    user = User.find_by!(email: "carol@example.com")
    assert_equal({ "user" => { "id" => user.id, "email" => user.email, "status" => "active" } }, response.parsed_body)
    assert user.kyc_profile.pending?

    # M7: without a wallet and a ledger account the user could never pay.
    wallet = user.wallets.sole
    assert_equal "USD", wallet.currency.code
    assert_equal "active", wallet.status
    assert wallet.account.liability?
    assert_equal 0, wallet.available_balance
  end

  test "an invalid registration creates nothing" do
    assert_no_difference [ -> { User.count }, -> { KycProfile.count }, -> { Wallet.count }, -> { Account.count } ] do
      register(email: "")
    end

    assert_response :unprocessable_entity
    assert_includes response.parsed_body["errors"], "Email can't be blank"
  end

  # M6: the user, profile and wallet are created together or not at all.
  test "a failure after the user is saved leaves no half-registered user" do
    failing_wallet = ->(_original, **) { raise ActiveRecord::RecordInvalid.new(Wallet.new) }

    assert_no_difference [ -> { User.count }, -> { KycProfile.count } ] do
      with_class_method(Wallets::Open, :call, failing_wallet) { register }
    end

    assert_response :unprocessable_entity
  end

  # M10
  test "registration is rate limited per IP" do
    10.times { |i| register(email: "user#{i}@example.com") }
    assert_response :created

    register(email: "one-too-many@example.com")

    assert_response :too_many_requests
    assert_equal({ "error" => "Too many requests, try again later" }, response.parsed_body)
    assert_not User.exists?(email: "one-too-many@example.com")
  end
end
