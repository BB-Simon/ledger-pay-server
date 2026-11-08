require "test_helper"

class Api::V1::Admin::ReconciliationRunsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @run = ReconciliationRun.create!(provider: "stripe", run_type: "payments", status: :completed, total_items: 1, failed_count: 1)
    @item = item_in(@run, status: :failed)
  end

  def item_in(run, status:, internal_id: 1)
    run.reconciliation_run_items.create!(
      record_type: "payment", internal_type: "Payment", internal_id: internal_id,
      provider_reference: "pi_#{internal_id}", status: status, attempts: 5
    )
  end

  def auth_headers(user)
    raw_token = SecureRandom.hex(32)
    AuthToken.create!(user: user, token_digest: Digest::SHA256.hexdigest(raw_token), expires_at: 1.day.from_now)
    { "Authorization" => "Bearer #{raw_token}" }
  end

  def retry_item(run_id: @run.id, item_id: @item.id, user: users(:admin))
    post "/api/v1/admin/reconciliation_runs/#{run_id}/items/#{item_id}/retry", headers: auth_headers(user)
  end

  test "an admin can retry a failed item" do
    retry_item

    assert_response :accepted
    body = response.parsed_body
    assert_equal "Retry enqueued", body["message"]
    assert_equal @item.id, body.dig("item", "id")
    assert_equal "pending", body.dig("item", "status")

    assert @run.reload.running?
    assert_equal [ @item.id ], Reconciliation::PaymentJob.jobs.sole["args"]
    assert AuditLog.exists?(action: "reconciliation_item.retry_requested", auditable_id: @item.id, user: users(:admin))
  end

  test "an item from a different run is not found" do
    other_run = ReconciliationRun.create!(provider: "stripe", run_type: "payments", status: :completed)

    retry_item(run_id: other_run.id)

    assert_response :not_found
    assert @item.reload.failed?
    assert_empty Reconciliation::PaymentJob.jobs
  end

  test "an item that isn't failed can't be retried" do
    matched = item_in(@run, status: :matched, internal_id: 2)

    retry_item(item_id: matched.id)

    assert_response :unprocessable_entity
    assert_equal "Only failed items can be retried", response.parsed_body["error"]
  end

  test "customers can't retry items" do
    retry_item(user: users(:alice))

    assert_response :forbidden
    assert @item.reload.failed?
  end

  test "requires authentication" do
    post "/api/v1/admin/reconciliation_runs/#{@run.id}/items/#{@item.id}/retry"

    assert_response :unauthorized
  end
end
