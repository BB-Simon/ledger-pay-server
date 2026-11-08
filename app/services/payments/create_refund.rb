module Payments
  class CreateRefund
    def self.call(payment:, amount:, reason:, idempotency_key: nil)
      new(payment, amount, reason, idempotency_key).call
    end

    def initialize(payment, amount, reason, idempotency_key = nil)
      @payment = payment
      @amount = amount
      @reason = reason
      @idempotency_key = idempotency_key
    end

    def call
      replayed = nil
      refund = Payment.transaction do
        @payment = Payment.lock.find(@payment.id)

        raise ArgumentError, "Wallet account is required" unless @payment.wallet.account

        # Same row Ledger::Transfer and CreateWithdrawal lock, so the balance
        # can't change between this check and the refund being held.
        @payment.wallet.account.lock!

        # Before validate!: a replay must return the original refund, not
        # fail because that refund now counts against the refundable amount.
        key = claim_idempotency_key!
        if key&.resource
          replayed = key.resource
          next replayed
        end

        validate!

        created = Refund.create!(
          payment: @payment,
          amount: @amount,
          provider: "stripe",
          status: :pending,
          reason: @reason
        )

        key&.update!(resource: created, status: "completed")
        created
      end

      # Already created and submitted by the original request.
      return { refund: refund.reload } if replayed

      AuditLogs::Record.call(
        action: "refund.created",
        auditable: refund,
        user: refund.payment.user,
        metadata: {
          amount: refund.amount,
          currency: refund.payment.currency.code,
          payment_id: refund.payment_id
        }
      )

      submit_to_stripe(refund)

      { refund: refund.reload }
    end

    # A definite Stripe rejection raises (the refund is already marked failed)
    # and the controller returns 422. An unknown outcome keeps the refund
    # pending and retries in the background with the same idempotency key.
    def submit_to_stripe(refund)
      Payments::SubmitRefund.call(refund: refund)
    rescue *Payments::SubmitRefund::PERMANENT_ERRORS
      raise
    rescue Stripe::StripeError => e
      Rails.logger.warn("Refund #{refund.id} submission outcome unknown, retrying: #{e.class}: #{e.message}")
      Payments::SubmitRefundJob.perform_async(refund.id)
    end

    private
    def claim_idempotency_key!
      return unless @idempotency_key

      IdempotencyKeys::Claim.call(
        user: @payment.user,
        key: @idempotency_key,
        request_hash: IdempotencyKeys::Claim.request_hash("refund", @payment.id, @amount, @reason)
      )
    end

    def validate!
      raise ArgumentError, "Payment must be succeeded" unless
        @payment.succeeded?

      raise ArgumentError, "Payment provider must be Stripe" unless
        @payment.provider == "stripe"

      raise ArgumentError, "Amount must be a positive integer" unless
        @amount.is_a?(Integer) && @amount > 0

      raise ArgumentError, "Wallet must be active" unless
        @payment.wallet.status == "active"

      raise ArgumentError, "Refund amount exceeds refundable amount" unless
        @amount <= refundable_amount

      # The refund is debited from the wallet when Stripe settles it, so the
      # wallet must still hold the money now.
      raise ArgumentError, "Insufficient wallet balance for refund" unless
        @payment.wallet.available_balance >= @amount
    end

    def refundable_amount
      refunded_amount = @payment.refunds
        .where(status: [ :pending, :succeeded ])
        .sum(:amount)

      @payment.amount - refunded_amount
    end
  end
end
