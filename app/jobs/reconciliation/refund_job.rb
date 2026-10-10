module Reconciliation
  class RefundJob
    include Sidekiq::Job

    sidekiq_options retry: 5

    def perform(refund_id)
      refund = Refund.find(refund_id)

      return unless refund.provider == "stripe"
      return if refund.provider_refund_id.blank?

      stripe_refund = Stripe::Refund.retrieve(
        refund.provider_refund_id
      )

      Reconciliation::ReconcileRefund.call(
        stripe_refund: stripe_refund
      )
    end
  end
end
