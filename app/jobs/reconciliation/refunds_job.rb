module Reconciliation
  class RefundsJob
    include Sidekiq::Job

    def perform
      Reconciliation::Run.call(
        provider: "stripe",
        run_type: "refunds"
      )
    end
  end
end
