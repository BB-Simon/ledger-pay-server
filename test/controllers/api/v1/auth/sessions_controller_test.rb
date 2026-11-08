require "test_helper"

class Api::V1::Auth::SessionsControllerTest < ActionDispatch::IntegrationTest
  def login(email:, password: "password")
    post "/api/v1/auth/login", params: { email: email, password: password }
  end

  def assert_rejected
    assert_response :unauthorized
    assert_equal({ "error" => "Invalid email or password" }, response.parsed_body)
  end

  test "valid credentials return a token that authenticates later requests" do
    assert_difference -> { AuthToken.count }, 1 do
      login(email: "alice@example.com")
    end

    assert_response :success
    body = response.parsed_body
    assert_equal({ "id" => users(:alice).id, "email" => "alice@example.com", "status" => "active" }, body["user"])

    # Only the digest is stored, and the raw token works as a bearer token.
    token = AuthToken.last
    assert_equal Digest::SHA256.hexdigest(body["token"]), token.token_digest
    assert_equal users(:alice), token.user

    get "/api/v1/me", headers: { "Authorization" => "Bearer #{body["token"]}" }
    assert_response :success
  end

  test "the email is matched regardless of case and surrounding spaces" do
    login(email: "  Alice@Example.COM ")

    assert_response :success
    assert_equal users(:alice).id, response.parsed_body.dig("user", "id")
  end

  test "a wrong password is rejected without creating a token" do
    assert_no_difference -> { AuthToken.count } do
      login(email: "alice@example.com", password: "wrong")
    end

    assert_rejected
  end

  test "an unknown email is rejected without creating a token" do
    assert_no_difference -> { AuthToken.count } do
      login(email: "nobody@example.com")
    end

    assert_rejected
  end

  test "missing credentials are rejected" do
    post "/api/v1/auth/login"

    assert_rejected
  end

  # M10
  test "login is rate limited per IP" do
    10.times { login(email: "alice@example.com", password: "wrong") }
    assert_response :unauthorized

    login(email: "alice@example.com")

    assert_response :too_many_requests
    assert_equal({ "error" => "Too many requests, try again later" }, response.parsed_body)
  end

  test "a user who isn't active can't log in, with the same error as bad credentials" do
    users(:alice).update!(status: "suspended")

    assert_no_difference -> { AuthToken.count } do
      login(email: "alice@example.com")
    end

    assert_rejected
  end
end
