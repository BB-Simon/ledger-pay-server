require "test_helper"

# Bug M6: a user without a KYC profile got a 500 (NoMethodError on nil).
class Api::V1::KycControllerTest < ActionDispatch::IntegrationTest
  def auth_headers(user)
    raw_token = SecureRandom.hex(32)
    AuthToken.create!(user: user, token_digest: Digest::SHA256.hexdigest(raw_token), expires_at: 1.day.from_now)
    { "Authorization" => "Bearer #{raw_token}" }
  end

  test "returns the caller's KYC profile" do
    users(:alice).create_kyc_profile!(status: "verified", verification_level: "basic", verified_at: Time.current)

    get "/api/v1/kyc", headers: auth_headers(users(:alice))

    assert_response :success
    assert_equal "verified", response.parsed_body.dig("kyc", "status")
    assert_equal "basic", response.parsed_body.dig("kyc", "verification_level")
  end

  test "a user without a KYC profile gets 404" do
    get "/api/v1/kyc", headers: auth_headers(users(:alice))

    assert_response :not_found
    assert_equal({ "error" => "KYC profile not found" }, response.parsed_body)
  end

  test "requires authentication" do
    get "/api/v1/kyc"

    assert_response :unauthorized
  end
end
