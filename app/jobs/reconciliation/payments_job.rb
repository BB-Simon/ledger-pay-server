module Reconciliation
  class PaymentsJob
    include Sidekiq::Job

    def perform
      Payment
        .where(provider: "stripe")
        .where("created_at >= ?", 24.hours.ago)
        .where.not(provider_payment_id: nil)
        .find_each do |payment|
        Reconciliation::PaymentJob.perform_async(
          payment.id
        )
      end
    end
  end
end
