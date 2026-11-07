module Withdrawals
  # Sends a pending local withdrawal to Stripe as a payout. Safe to call more
  # than once: the idempotency key makes Stripe return the same payout.
  #
  # - Success: stores provider_withdrawal_id. The withdrawal stays pending;
  #   the payout webhook decides whether it succeeded.
  # - StripeErrors::DEFINITE_FAILURES: Stripe didn't create the payout, so the
  #   withdrawal is marked failed (releasing the hold) and the error re-raised.
  # - Any other Stripe error: the outcome is unknown, so the withdrawal stays
  #   pending and the error is re-raised for the caller to retry.
  class CreateProviderWithdrawal
    def self.call(withdrawal:)
      new(withdrawal: withdrawal).call
    end

    def initialize(withdrawal:)
      @withdrawal = withdrawal
    end

    def call
      withdrawal = Withdrawal.find(@withdrawal.id)
      return withdrawal unless withdrawal.pending?
      return withdrawal if withdrawal.provider_withdrawal_id.present?

      raise ArgumentError, "Withdrawal provider must be Stripe" unless
        withdrawal.provider == "stripe"

      payout = Stripe::Payout.create({
        amount: withdrawal.amount,
        currency: withdrawal.currency.code.downcase,
        metadata: {
          withdrawal_id: withdrawal.id
        }
      }, {
        idempotency_key: "withdrawal-#{withdrawal.id}"
      })

      withdrawal.update!(provider_withdrawal_id: payout.id)
      withdrawal
    rescue *StripeErrors::DEFINITE_FAILURES => e
      mark_failed!(e)
      raise
    end

    private

    def mark_failed!(error)
      Withdrawal.transaction do
        withdrawal = Withdrawal.lock.find(@withdrawal.id)
        next unless withdrawal.pending?

        withdrawal.update!(
          status: :failed,
          failure_code: error.code,
          failure_message: error.message.to_s.truncate(500)
        )

        AuditLogs::Record.call(
          action: "withdrawal.failed",
          auditable: withdrawal,
          user: withdrawal.user,
          metadata: {
            stage: "submission",
            amount: withdrawal.amount,
            currency: withdrawal.currency.code,
            error_class: error.class.name
          }
        )
      end
    end
  end
end
