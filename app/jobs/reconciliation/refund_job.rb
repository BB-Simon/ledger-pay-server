module Reconciliation
  class RefundJob
    include Sidekiq::Job

    sidekiq_options retry: 5

    sidekiq_retries_exhausted do |job, exception|
      refund_id, run_id = job["args"]

      if run_id
        Reconciliation::RecordFailure.call(
          run_id: run_id,
          record_id: refund_id,
          record_type: "refund",
          error: exception
        )
      end
    end

    def perform(item_id)
      item = ReconciliationRunItem.find(item_id)
      claimed = item.with_lock do
        next false if item.terminal?

        if item.processing? &&
            item.started_at &&
            item.started_at > 15.minutes.ago
          next false
        end

        item.update!(
          status: :processing,
          started_at: Time.current,
          attempts: item.attempts + 1
        )

        true
      end

      return unless claimed

      refund = Refund.find(item.internal_id)

      return unless refund.provider == "stripe"
      return if refund.provider_refund_id.blank?

      stripe_refund = Stripe::Refund.retrieve(
        refund.provider_refund_id
      )

      record = Reconciliation::ReconcileRefund.call(
        stripe_refund: stripe_refund
      )

      Reconciliation::RecordResult.call(
        run_id: item.reconciliation_run_id,
        record: record
      )

      Reconciliation::CompleteRunItem.call(
        item_id: item.id,
        status: record.matched? ? :matched : :discrepancy
      )
    rescue StandardError => e
      item&.with_lock do
        item.update!(status: :pending, started_at: nil) unless item.terminal?
      end

      raise e
    end
  end
end
