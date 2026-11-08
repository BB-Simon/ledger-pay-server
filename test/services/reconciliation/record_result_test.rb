require "test_helper"

# Bug M3: RecordResult only stores the per-run snapshot. Run counters and
# status belong to CompleteRunItem alone.
class Reconciliation::RecordResultTest < ActiveSupport::TestCase
  setup do
    @run = ReconciliationRun.create!(provider: "stripe", run_type: "payouts", status: :running, total_items: 1)
  end

  def reconciliation_record(status:, discrepancy_type: nil, actual_amount: 400)
    Reconciliation::CreateRecord.call(
      provider: "stripe", provider_reference: "po_m3", record_type: "payout",
      expected_amount: 400, actual_amount: actual_amount, currency: "usd",
      status: status, discrepancy_type: discrepancy_type
    )
  end

  test "stores the result without touching run counters or status" do
    result = Reconciliation::RecordResult.call(run_id: @run.id, record: reconciliation_record(status: :matched))

    assert result.matched?
    @run.reload
    assert @run.running?
    assert_equal 0, @run.records_checked
    assert_equal 0, @run.matched_count
    assert_nil @run.completed_at
  end

  test "a retry updates the snapshot to the latest outcome" do
    Reconciliation::RecordResult.call(run_id: @run.id, record: reconciliation_record(status: :matched))

    record = reconciliation_record(status: :discrepancy, discrepancy_type: :amount_mismatch, actual_amount: 999)
    Reconciliation::RecordResult.call(run_id: @run.id, record: record)

    result = @run.reconciliation_results.sole
    assert result.discrepancy?
    assert_equal "amount_mismatch", result.discrepancy_type
    assert_equal 999, result.actual_amount
  end
end
