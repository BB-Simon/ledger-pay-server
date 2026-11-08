require "test_helper"

# Bug M1: recovery must not re-enqueue items that Sidekiq still holds
# (queued, scheduled, or waiting to retry), only ones whose job was lost.
class Reconciliation::RecoverStuckItemsJobTest < ActiveSupport::TestCase
  setup do
    @run = ReconciliationRun.create!(provider: "stripe", run_type: "payments", status: :running, total_items: 1)
  end

  def item(status:, idle_for:, started_at: nil, internal_id: 1)
    item = @run.reconciliation_run_items.create!(
      record_type: "payment", internal_type: "Payment", internal_id: internal_id,
      status: status, started_at: started_at
    )
    item.update_columns(updated_at: idle_for.ago)
    item
  end

  # Sidekiq's queues and retry/scheduled sets live in Redis; tests stub the
  # lookup and say which items still have a job there.
  def recover(jobs_in_sidekiq: [])
    held = Set.new(jobs_in_sidekiq.map { |item| [ "Reconciliation::PaymentJob", item.id ] })

    with_class_method(Reconciliation::RecoverStuckItemsJob, :jobs_in_sidekiq, ->(_original) { held }) do
      Reconciliation::RecoverStuckItemsJob.new.perform
    end
  end

  def enqueued_item_ids
    Reconciliation::PaymentJob.jobs.map { |job| job["args"].first }
  end

  # The tests below stub jobs_in_sidekiq, so check the real lookup's
  # dependencies are loaded (they come from sidekiq/api, not sidekiq).
  test "the Sidekiq API used to find held jobs is loaded" do
    assert_nothing_raised { [ Sidekiq::RetrySet, Sidekiq::ScheduledSet, Sidekiq::Queue ] }
  end

  test "a pending item whose job is still waiting in Sidekiq isn't enqueued again" do
    backing_off = item(status: :pending, idle_for: 20.minutes)

    recover(jobs_in_sidekiq: [ backing_off ])

    assert_empty enqueued_item_ids
  end

  test "a pending item whose job was lost is enqueued again" do
    lost = item(status: :pending, idle_for: 20.minutes)

    recover

    assert_equal [ lost.id ], enqueued_item_ids
  end

  test "a recently updated pending item is left alone" do
    item(status: :pending, idle_for: 1.minute)

    recover

    assert_empty enqueued_item_ids
  end

  test "an item stuck in processing is released and enqueued again" do
    stuck = item(status: :processing, idle_for: 20.minutes, started_at: 20.minutes.ago)

    recover

    assert stuck.reload.pending?
    assert_nil stuck.started_at
    assert_equal [ stuck.id ], enqueued_item_ids
  end

  test "an item stuck in processing that still has a job waiting is released but not enqueued twice" do
    stuck = item(status: :processing, idle_for: 20.minutes, started_at: 20.minutes.ago)

    recover(jobs_in_sidekiq: [ stuck ])

    assert stuck.reload.pending?
    assert_empty enqueued_item_ids
  end
end
