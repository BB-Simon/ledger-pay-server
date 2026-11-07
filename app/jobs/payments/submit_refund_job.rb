module Payments
  # Retries sending a refund to Stripe after an unknown outcome (timeout, 5xx).
  # Uses the same idempotency key every time, so a retry can't refund twice.
  class SubmitRefundJob
    include Sidekiq::Job

    sidekiq_options queue: :default, retry: 10

    # Stripe may have created the refund, so it's never marked failed
    # automatically: that would release the hold on money that may be gone.
    sidekiq_retries_exhausted do |job, exception|
      refund = Refund.find_by(id: job["args"].first)
      next unless refund&.pending?

      AuditLogs::Record.call(
        action: "refund.submission_stuck",
        auditable: refund,
        user: refund.payment.user,
        metadata: {
          error_class: exception.class.name,
          error_message: exception.message.to_s.truncate(500)
        }
      )
    end

    def perform(refund_id)
      refund = Refund.find_by(id: refund_id)
      return unless refund

      Payments::SubmitRefund.call(refund: refund)
    rescue *Payments::SubmitRefund::PERMANENT_ERRORS
      # SubmitRefund already marked the refund failed; retrying won't help.
    end
  end
end
