module Withdrawals
  # Retries sending a payout to Stripe after an unknown outcome (timeout, 5xx).
  # Uses the same idempotency key every time, so a retry can't pay out twice.
  class SubmitWithdrawalJob
    include Sidekiq::Job

    sidekiq_options queue: :default, retry: 10

    # Stripe may have created the payout, so it's never marked failed
    # automatically: that would release the hold on money that may be gone.
    sidekiq_retries_exhausted do |job, exception|
      withdrawal = Withdrawal.find_by(id: job["args"].first)
      next unless withdrawal&.pending?

      AuditLogs::Record.call(
        action: "withdrawal.submission_stuck",
        auditable: withdrawal,
        user: withdrawal.user,
        metadata: {
          error_class: exception.class.name,
          error_message: exception.message.to_s.truncate(500)
        }
      )
    end

    def perform(withdrawal_id)
      withdrawal = Withdrawal.find_by(id: withdrawal_id)
      return unless withdrawal

      Withdrawals::CreateProviderWithdrawal.call(withdrawal: withdrawal)
    rescue *StripeErrors::DEFINITE_FAILURES
      # Already marked failed by CreateProviderWithdrawal; retrying won't help.
    end
  end
end
