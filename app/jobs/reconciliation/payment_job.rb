module Reconciliation
  class PaymentJob
    include Sidekiq::Job

    sidekiq_options retry: 5

    def perform(payment_id)
      payment = Payment.find(payment_id)

      return unless payment.provider == "stripe"
      return if payment.provider_payment_id.blank?

      intent = Stripe::PaymentIntent.retrieve(
        payment.provider_payment_id
      )

      Reconciliation::ReconcilePayment.call(
        payment_intent: intent
      )
    end
  end
end
