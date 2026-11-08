module Reconciliation
  # Reconciles one payment run item. The work is in Reconciliation::ProcessItem.
  class PaymentJob
    include Sidekiq::Job

    sidekiq_options retry: 5

    # Without this the item would stay pending, keeping its run open and
    # being re-enqueued by RecoverStuckItemsJob forever.
    sidekiq_retries_exhausted do |job, exception|
      Reconciliation::CompleteRunItem.call(
        item_id: job["args"].first,
        status: :failed,
        error: exception
      )
    end

    def perform(item_id)
      Reconciliation::ProcessItem.call(item_id: item_id)
    end
  end
end
