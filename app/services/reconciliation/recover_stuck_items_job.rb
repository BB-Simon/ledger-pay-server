module Reconciliation
  class RecoverStuckItemsJob
    include Sidekiq::Job

    sidekiq_options queue: :default, retry: 3

    STALE_AFTER = 15.minutes

    def perform
      recover_stale_processing_items
      reenqueue_stale_pending_items
    end

    private

    def recover_stale_processing_items
      cutoff = STALE_AFTER.ago

      ReconciliationRunItem
        .where(status: :processing)
        .where("started_at < ?", cutoff)
        .find_each do |item|
          item.with_lock do
            next unless item.processing?
            next unless item.started_at && item.started_at < cutoff

            item.update!(
              status: :pending,
              started_at: nil
            )
          end

          enqueue_item(item)
        end
    end

    def reenqueue_stale_pending_items
      cutoff = STALE_AFTER.ago

      ReconciliationRunItem
        .where(status: :pending)
        .where("updated_at < ?", cutoff)
        .find_each do |item|
          enqueue_item(item)
        end
    end

    def enqueue_item(item)
      job_class = {
        "payment" => Reconciliation::PaymentJob,
        "refund" => Reconciliation::RefundJob,
        "payout" => Reconciliation::PayoutJob
      }.fetch(item.record_type)

      job_class.perform_async(item.id)

      # Refresh updated_at so a repeatedly failing enqueue is not
      # immediately selected again on every recovery pass.
      item.touch if item.pending?
    rescue StandardError => e
      Rails.logger.error(
        "Reconciliation recovery failed for item #{item.id}: " \
        "#{e.class}: #{e.message}"
      )
    end
  end
end
