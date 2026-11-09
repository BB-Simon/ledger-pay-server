# Builds Stripe webhook events for local records and runs them through the
# real processor, the way POST /api/v1/webhooks/stripe does after verifying
# the signature.
module StripeEventHelpers
  def stripe_event(type, object, id: "evt_#{SecureRandom.hex(8)}")
    Stripe::Event.construct_from(id: id, type: type, data: { object: object })
  end

  def deliver(event)
    Payments::ProcessStripeWebhook.call(event: event)
  end

  def payment_intent_object(payment, status:, amount: payment.amount, **extra)
    { id: payment.provider_payment_id, object: "payment_intent", amount: amount, currency: "usd",
      status: status, metadata: { payment_id: payment.id.to_s } }.merge(extra)
  end

  def refund_object(refund, status:, amount: refund.amount)
    { id: refund.provider_refund_id, object: "refund", amount: amount, currency: "usd",
      status: status, metadata: { refund_id: refund.id.to_s } }
  end

  def payout_object(withdrawal, status:, amount: withdrawal.amount, **extra)
    { id: withdrawal.provider_withdrawal_id, object: "payout", amount: amount, currency: "usd",
      status: status, metadata: { withdrawal_id: withdrawal.id.to_s } }.merge(extra)
  end
end
