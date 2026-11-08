require "test_helper"

# ApplicationController#current_user (bugs M8, M9).
class Api::V1::MeControllerTest < ActionDispatch::IntegrationTest
  def auth_headers(user, expires_at: 1.day.from_now)
    raw_token = SecureRandom.hex(32)
    AuthToken.create!(user: user, token_digest: Digest::SHA256.hexdigest(raw_token), expires_at: expires_at)
    { "Authorization" => "Bearer #{raw_token}" }
  end

  def auth_token_queries
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql].include?(%("auth_tokens")) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  test "returns the current user" do
    get "/api/v1/me", headers: auth_headers(users(:alice))

    assert_response :success
    assert_equal users(:alice).id, response.parsed_body.dig("user", "id")
  end

  test "the token is looked up once per request" do
    headers = auth_headers(users(:alice))

    queries = auth_token_queries { get "/api/v1/me", headers: headers }

    assert_response :success
    assert_equal 1, queries
  end

  test "a suspended user's existing token stops working" do
    headers = auth_headers(users(:alice))
    users(:alice).update!(status: "suspended")

    get "/api/v1/me", headers: headers

    assert_response :unauthorized
  end

  test "an expired token is rejected" do
    get "/api/v1/me", headers: auth_headers(users(:alice), expires_at: 1.minute.ago)

    assert_response :unauthorized
  end
end
