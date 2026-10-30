module Reconciliation
  class PaymentJob
    include Sidekiq::Job

    sidekiq_options retry: 5

    sidekiq_retries_exhausted do |job, exception|
      item_id = job["args"].first

      Reconciliation::CompleteRunItem.call(
        item_id: item_id,
        status: :failed,
        error: exception
      )
    end

    def perform(item_id)
      item = ReconciliationRunItem.find(item_id)
      # return if item.terminal?

      # item.update!(
      #   status: :processing,
      #   started_at: item.started_at || Time.current,
      #   attempts: item.attempts + 1
      # )

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

      payment = Payment.find(item.internal_id)

      payment_intent = Stripe::PaymentIntent.retrieve(
        payment.provider_payment_id
      )

      record = Reconciliation::ReconcilePayment.call(
        payment_intent: payment_intent
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
