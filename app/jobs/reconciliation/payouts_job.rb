module Reconciliation
  class PayoutsJob
    include Sidekiq::Job

    def perform
      Withdrawal
        .where(provider: "stripe")
        .where("created_at >= ?", 24.hours.ago)
        .where.not(provider_withdrawal_id: nil)
        .find_each do |withdrawal|
        Reconciliation::PayoutJob.perform_async(withdrawal.id)
      end
    end
  end
end
