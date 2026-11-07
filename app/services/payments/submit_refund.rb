module Payments
  # Sends a pending local refund to Stripe. Safe to call more than once: the
  # idempotency key makes Stripe return the same refund instead of a new one.
  #
  # - Success: stores provider_refund_id. The refund stays pending; the
  #   refund webhook decides whether it succeeded.
  # - PERMANENT_ERRORS: Stripe definitely didn't refund, so the refund is
  #   marked failed (releasing the wallet hold) and the error is re-raised.
  # - Any other Stripe error (timeout, 5xx, rate limit): Stripe may or may not
  #   have refunded, so the refund stays pending and the error is re-raised for
  #   the caller to retry.
  class SubmitRefund
    PERMANENT_ERRORS = StripeErrors::DEFINITE_FAILURES

    def self.call(refund:)
      new(refund: refund).call
    end

    def initialize(refund:)
      @refund = refund
    end

    def call
      refund = Refund.find(@refund.id)
      return refund unless refund.pending?
      return refund if refund.provider_refund_id.present?

      stripe_refund = Stripe::Refund.create(
        {
          payment_intent: refund.payment.provider_payment_id,
          amount: refund.amount,
          metadata: { refund_id: refund.id }
        },
        { idempotency_key: "refund-#{refund.id}" }
      )

      refund.update!(provider_refund_id: stripe_refund.id)
      refund
    rescue *PERMANENT_ERRORS => e
      mark_failed!(e)
      raise
    end

    private

    def mark_failed!(error)
      Refund.transaction do
        refund = Refund.lock.find(@refund.id)
        next unless refund.pending?

        refund.update!(status: :failed)

        AuditLogs::Record.call(
          action: "refund.failed",
          auditable: refund,
          user: refund.payment.user,
          metadata: {
            stage: "submission",
            error_class: error.class.name,
            error_message: error.message.to_s.truncate(500)
          }
        )
      end
    end
  end
end
