module Reconciliation
  class PaymentsJob
    include Sidekiq::Job

    def perform
      Reconciliation::Run.call(
        provider: "stripe",
        run_type: "payments"
      )
    end
  end
end
