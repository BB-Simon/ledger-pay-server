require "test_helper"

# Bug H11: re-reconciling a resolved discrepancy must not hide a new problem.
class Reconciliation::CreateRecordTest < ActiveSupport::TestCase
  def save(status:, discrepancy_type: nil, actual_amount: 500)
    Reconciliation::CreateRecord.call(
      provider: "stripe", provider_reference: "po_h11", record_type: "payout",
      expected_amount: 500, actual_amount: actual_amount, currency: "usd",
      status: status, discrepancy_type: discrepancy_type
    )
  end

  def resolved_discrepancy(discrepancy_type)
    record = save(status: :discrepancy, discrepancy_type: discrepancy_type)
    Reconciliation::ResolveRecord.call(record: record, admin: users(:admin), notes: "Checked with Stripe")
    record.reload
  end

  test "a different discrepancy on a resolved record reopens it" do
    record = resolved_discrepancy(:amount_mismatch)

    save(status: :discrepancy, discrepancy_type: :status_mismatch)

    record.reload
    assert record.open?
    assert record.discrepancy_type_status_mismatch?
    assert_nil record.resolved_by
    assert_nil record.resolved_at
    assert_nil record.resolution_notes

    log = AuditLog.find_by!(action: "reconciliation.reopened", auditable_type: "ReconciliationRecord", auditable_id: record.id)
    assert_equal "amount_mismatch", log.metadata["previous_discrepancy_type"]
    assert_equal "status_mismatch", log.metadata["discrepancy_type"]
    assert_equal "Checked with Stripe", log.metadata["previous_resolution_notes"]
  end

  test "the same discrepancy found again stays resolved" do
    record = resolved_discrepancy(:amount_mismatch)

    save(status: :discrepancy, discrepancy_type: :amount_mismatch)

    assert record.reload.resolved?
    assert_not AuditLog.exists?(action: "reconciliation.reopened")
  end

  test "a resolved discrepancy that now matches stays resolved" do
    record = resolved_discrepancy(:amount_mismatch)

    save(status: :matched)

    record.reload
    assert record.matched?
    assert record.resolved?
  end

  test "an open record is simply updated" do
    record = save(status: :discrepancy, discrepancy_type: :amount_mismatch)

    save(status: :discrepancy, discrepancy_type: :status_mismatch)

    assert record.reload.open?
    assert record.discrepancy_type_status_mismatch?
    assert_not AuditLog.exists?(action: "reconciliation.reopened")
  end
end
