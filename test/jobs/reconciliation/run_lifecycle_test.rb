require "test_helper"

# A reconciliation run from fan-out to completion: per-item outcomes, run
# counters, per-run snapshots that don't change later, and the admin retry
# flow. Stripe is faked; the jobs run inline by calling perform.
class Reconciliation::RunLifecycleTest < ActiveSupport::TestCase
  setup do
    @payments = %w[pi_ok pi_wrong pi_down].to_h do |intent_id|
      payment = Payment.create!(
        user: users(:alice), wallet: wallets(:alice_usd), currency: currencies(:usd), amount: 1_000,
        provider: "stripe", provider_payment_id: intent_id, status: :succeeded
      )
      [ intent_id, payment ]
    end
  end

  # What Stripe returns for each PaymentIntent id: an amount, or an error.
  def with_stripe(responses, &block)
    fake = lambda do |_original, id, *|
      response = responses.fetch(id)
      raise response if response.is_a?(Exception)

      Stripe::PaymentIntent.construct_from(id: id, amount: response, currency: "usd", status: "succeeded")
    end
    with_class_method(Stripe::PaymentIntent, :retrieve, fake, &block)
  end

  # Runs the queued item jobs the way Sidekiq would. A job that raises is
  # retried by Sidekiq; here it's treated as having used up its retries.
  def drain_item_jobs
    jobs = Reconciliation::PaymentJob.jobs.dup
    Reconciliation::PaymentJob.clear

    jobs.each do |job|
      Reconciliation::PaymentJob.new.perform(*job["args"])
    rescue StandardError => e
      Reconciliation::PaymentJob.sidekiq_retries_exhausted_block.call(job, e)
    end
  end

  def item_for(run, intent_id)
    run.reconciliation_run_items.find_by!(provider_reference: intent_id)
  end

  def result_for(run, intent_id)
    run.reconciliation_results.find_by!(provider_reference: intent_id)
  end

  test "a run reconciles every item and its counters add up" do
    run = Reconciliation::Run.call(run_type: "payments")
    assert run.running?
    assert_equal 3, run.total_items

    with_stripe("pi_ok" => 1_000, "pi_wrong" => 999, "pi_down" => Stripe::APIConnectionError.new("timeout")) do
      drain_item_jobs
    end

    run.reload
    assert item_for(run, "pi_ok").matched?
    assert item_for(run, "pi_wrong").discrepancy?
    assert item_for(run, "pi_down").failed?

    assert_equal 3, run.total_items
    assert_equal 2, run.records_checked
    assert_equal 1, run.matched_count
    assert_equal 1, run.discrepancy_count
    assert_equal 1, run.failed_count
    assert run.failed?, "a run with a failed item ends failed"
    assert_not_nil run.completed_at

    assert ReconciliationRecord.find_by!(provider_reference: "pi_wrong").discrepancy_type_amount_mismatch?
  end

  test "a run where everything matches completes" do
    @payments.except("pi_ok").each_value(&:destroy!)
    run = Reconciliation::Run.call(run_type: "payments")

    with_stripe("pi_ok" => 1_000) { drain_item_jobs }

    run.reload
    assert run.completed?
    assert_equal [ 1, 1, 0, 0 ], [ run.records_checked, run.matched_count, run.discrepancy_count, run.failed_count ]
  end

  test "each run keeps its own snapshot when a later run sees something different" do
    responses = { "pi_ok" => 1_000, "pi_wrong" => 999, "pi_down" => 1_000 }

    first_run = Reconciliation::Run.call(run_type: "payments")
    with_stripe(responses) { drain_item_jobs }

    # Stripe's amount is corrected; the next run finds it matching.
    second_run = Reconciliation::Run.call(run_type: "payments")
    with_stripe(responses.merge("pi_wrong" => 1_000)) { drain_item_jobs }

    assert result_for(first_run, "pi_wrong").discrepancy?, "history isn't rewritten"
    assert_equal 999, result_for(first_run, "pi_wrong").actual_amount
    assert result_for(second_run, "pi_wrong").matched?
    assert ReconciliationRecord.find_by!(provider_reference: "pi_wrong").matched?, "the current record shows the latest outcome"

    assert_equal 1, first_run.reload.discrepancy_count
    assert second_run.reload.completed?
  end

  test "an admin retry of a failed item finishes the run" do
    run = Reconciliation::Run.call(run_type: "payments")
    with_stripe("pi_ok" => 1_000, "pi_wrong" => 1_000, "pi_down" => Stripe::APIConnectionError.new("timeout")) do
      drain_item_jobs
    end
    assert run.reload.failed?

    Reconciliation::RetryRunItem.call(item: item_for(run, "pi_down"), user: users(:admin))
    assert run.reload.running?
    assert_equal 0, run.failed_count

    with_stripe("pi_down" => 1_000) { drain_item_jobs }

    run.reload
    assert item_for(run, "pi_down").matched?
    assert run.completed?
    assert_equal [ 3, 3, 0, 0 ], [ run.records_checked, run.matched_count, run.discrepancy_count, run.failed_count ]
  end

  test "a finished item isn't reconciled again by a duplicate job" do
    run = Reconciliation::Run.call(run_type: "payments")
    item_id = item_for(run, "pi_ok").id
    calls = 0
    counting = lambda do |_original, id, *|
      calls += 1
      Stripe::PaymentIntent.construct_from(id: id, amount: 1_000, currency: "usd", status: "succeeded")
    end

    with_class_method(Stripe::PaymentIntent, :retrieve, counting) do
      2.times { Reconciliation::PaymentJob.new.perform(item_id) }
    end

    assert_equal 1, calls
    assert_equal 1, run.reconciliation_results.where(provider_reference: "pi_ok").count
  end
end
