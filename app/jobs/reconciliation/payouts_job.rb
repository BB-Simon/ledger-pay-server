module Reconciliation
  class PayoutsJob
    include Sidekiq::Job

    def perform
      Reconciliation::Run.call(
        provider: "stripe",
        run_type: "payouts"
      )
    end
  end
end
