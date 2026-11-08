require "test_helper"

class Api::V1::Admin::ReconciliationRecordsControllerTest < ActionDispatch::IntegrationTest
  def auth_headers(user)
    raw_token = SecureRandom.hex(32)
    AuthToken.create!(user: user, token_digest: Digest::SHA256.hexdigest(raw_token), expires_at: 1.day.from_now)
    { "Authorization" => "Bearer #{raw_token}" }
  end

  def create_records(count, status: "matched", record_type: "payment", created_at: Time.current)
    now = Time.current
    rows = Array.new(count) do |i|
      { provider: "stripe", provider_reference: "ref_#{record_type}_#{status}_#{SecureRandom.hex(4)}_#{i}",
        record_type: record_type, status: status, created_at: created_at + i.seconds, updated_at: now }
    end
    ReconciliationRecord.insert_all!(rows)
  end

  # Bug M5: the list must be bounded.
  test "returns at most 100 records, newest first" do
    create_records(105, created_at: 1.day.ago)
    newest = ReconciliationRecord.order(created_at: :desc).first

    get "/api/v1/admin/reconciliation_records", headers: auth_headers(users(:admin))

    assert_response :success
    body = response.parsed_body
    assert_equal 100, body.size
    assert_equal newest.id, body.first["id"]
  end

  test "filters by status and record type" do
    create_records(2, status: "matched", record_type: "payment")
    create_records(3, status: "discrepancy", record_type: "payout")

    get "/api/v1/admin/reconciliation_records", params: { status: "discrepancy", record_type: "payout" },
      headers: auth_headers(users(:admin))

    assert_response :success
    assert_equal 3, response.parsed_body.size
    assert(response.parsed_body.all? { |record| record["status"] == "discrepancy" })
  end

  test "customers can't list records" do
    get "/api/v1/admin/reconciliation_records", headers: auth_headers(users(:alice))

    assert_response :forbidden
  end

  test "requires authentication" do
    get "/api/v1/admin/reconciliation_records"

    assert_response :unauthorized
  end
end
