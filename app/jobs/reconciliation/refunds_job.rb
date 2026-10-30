module Reconciliation
  class RefundsJob
    include Sidekiq::Job

    def perform
      Reconciliation::Run.call(
        provider: "stripe",
        run_type: "refunds"
      )
    end

    # def perform
    #   Refund
    #     .where(provider: "stripe")
    #     .where("created_at >= ?", 24.hours.ago)
    #     .where.not(provider_refund_id: nil)
    #     .find_each do |refund|
    #     Reconciliation::RefundJob.perform_async(refund.id)
    #   end
    # end
  end
end
