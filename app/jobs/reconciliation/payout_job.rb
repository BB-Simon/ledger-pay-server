module Reconciliation
  class PayoutJob
    include Sidekiq::Job

    sidekiq_options retry: 5

    def perform(withdrawal_id)
      withdrawal = Withdrawal.find(withdrawal_id)

      return unless withdrawal.provider == "stripe"
      return if withdrawal.provider_withdrawal_id.blank?

      stripe_payout = Stripe::Payout.retrieve(
        withdrawal.provider_withdrawal_id
      )

      Reconciliation::ReconcilePayout.call(
        stripe_payout: stripe_payout
      )
    end
  end
end
