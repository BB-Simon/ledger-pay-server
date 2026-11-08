require "test_helper"

# Bug H4: a webhook that can never succeed must be recorded as failed and
# acknowledged (so Stripe stops retrying), while temporary problems must keep
# raising so Stripe redelivers the event.
class Payments::ProcessStripeWebhookErrorsTest < ActiveSupport::TestCase
  setup do
    @wallet = wallets(:alice_usd)
    Ledger::Deposit.call(wallet: @wallet, amount: 1_000, reference: "TEST-FUND-ALICE")
  end

  def pending_withdrawal(provider_withdrawal_id: "po_h4")
    Withdrawal.create!(
      user: users(:alice), wallet: @wallet, currency: currencies(:usd), amount: 400,
      provider: "stripe", provider_withdrawal_id: provider_withdrawal_id, status: :pending
    )
  end

  def payout_paid_event(withdrawal_id:, amount: 400, id: "evt_h4_#{SecureRandom.hex(4)}")
    Stripe::Event.construct_from(
      id: id, type: "payout.paid",
      data: { object: { id: "po_h4", object: "payout", amount: amount, currency: "usd", status: "paid",
                        metadata: { withdrawal_id: withdrawal_id.to_s } } }
    )
  end

  def process(event)
    Payments::ProcessStripeWebhook.call(event: event)
  end

  def failure_log(webhook_event)
    AuditLog.find_by!(action: "webhook_event.failed", auditable_type: "WebhookEvent", auditable_id: webhook_event.id)
  end

  test "an event that doesn't match the local record is marked failed and nothing moves" do
    withdrawal = pending_withdrawal
    event = payout_paid_event(withdrawal_id: withdrawal.id, amount: 999)

    webhook_event = assert_no_difference -> { LedgerEntry.count } do
      process(event)
    end

    assert webhook_event.reload.failed?
    assert withdrawal.reload.pending?
    log = failure_log(webhook_event)
    assert_equal "Withdrawal amount mismatch", log.metadata["error"]
    assert_equal "payout.paid", log.metadata["event_type"]
    assert_equal event.id, log.metadata["event_id"]
  end

  test "an event without our metadata is marked failed" do
    event = Stripe::Event.construct_from(
      id: "evt_no_meta", type: "payout.paid",
      data: { object: { id: "po_other", object: "payout", amount: 400, currency: "usd", metadata: {} } }
    )

    assert process(event).reload.failed?
  end

  test "an event for a record that doesn't exist is marked failed" do
    webhook_event = process(payout_paid_event(withdrawal_id: 0))

    assert webhook_event.reload.failed?
    assert_match(/not found/, failure_log(webhook_event).metadata["error"])
  end

  test "an event that arrives before the Stripe id is saved raises so Stripe retries it" do
    # C5/C6: after a timeout, the retry job stores the provider id later.
    withdrawal = pending_withdrawal(provider_withdrawal_id: nil)
    event = payout_paid_event(withdrawal_id: withdrawal.id)

    assert_raises(Payments::ProcessStripeWebhook::NotReady) { process(event) }

    assert WebhookEvent.find_by!(event_id: event.id).pending?
    assert_equal 0, AuditLog.where(action: "webhook_event.failed").count

    # The retry job stores the id, then Stripe redelivers the event.
    withdrawal.update!(provider_withdrawal_id: "po_h4")
    assert process(event).reload.processed?
    assert withdrawal.reload.succeeded?
  end

  test "a temporary error raises and leaves the event pending for Stripe to retry" do
    withdrawal = pending_withdrawal
    event = payout_paid_event(withdrawal_id: withdrawal.id)
    deadlock = ->(_original, **) { raise ActiveRecord::Deadlocked, "deadlock detected" }

    with_class_method(Ledger::Withdraw, :call, deadlock) do
      assert_raises(ActiveRecord::Deadlocked) { process(event) }
    end

    assert WebhookEvent.find_by!(event_id: event.id).pending?
    assert withdrawal.reload.pending?
  end

  test "a failed event is processed if it's sent again after the data is fixed" do
    withdrawal = pending_withdrawal
    event = payout_paid_event(withdrawal_id: withdrawal.id, amount: 500)
    assert process(event).reload.failed?

    withdrawal.update!(amount: 500)

    assert process(event).reload.processed?
    assert withdrawal.reload.succeeded?
  end
end
