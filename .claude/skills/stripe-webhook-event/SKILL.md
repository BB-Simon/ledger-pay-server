---
name: stripe-webhook-event
description: Handle a new Stripe webhook event type or change an existing handler in Payments::ProcessStripeWebhook, including any ledger posting and tests. Use for any Stripe event, payment, refund, or payout status sync work.
---

# Handle a Stripe webhook event

Entry point: `POST /api/v1/webhooks/stripe` → `Api::V1::Webhooks::StripeController` (verifies the signature with `STRIPE_WEBHOOK_SECRET`) → `Payments::ProcessStripeWebhook`. That service:
1. saves the event to `WebhookEvent` (unique on `event_id`, so redeliveries are deduped)
2. locks the `WebhookEvent` and returns if it is already `processed`
3. dispatches on `@event.type` in the `case` statement
4. marks the event `processed`

`Payments::ProcessStripeRefundWebhook` is unused, so don't add handlers there.

## 1. Add the handler
Add a `when "<event.type>"` branch and a private `process_<thing>_<event>!` method. Handler template:
```ruby
def process_payout_paid!
  payout = @event.data.object
  withdrawal = find_withdrawal_from_payout!(payout)       # local id from Stripe metadata
  validate_withdrawal!(withdrawal, payout)                # provider, provider id, amount, currency

  Withdrawal.transaction do
    withdrawal = Withdrawal.lock.find(withdrawal.id)      # re-load under lock
    return if withdrawal.succeeded? || withdrawal.failed? || withdrawal.canceled?   # status guard

    withdrawal.update!(status: :succeeded)
    Ledger::Withdraw.call(withdrawal: withdrawal)          # ledger posting in the same transaction
    AuditLogs::Record.call(action: "withdrawal.succeeded", auditable: withdrawal,
                           user: withdrawal.user, metadata: { amount: withdrawal.amount })
  end
end
```

## 2. Rules
- **Find the local record through metadata** (`payment_id`, `refund_id`, `withdrawal_id`) that we set when calling Stripe. Missing metadata → `ArgumentError`, which makes the controller return 422.
- **Validate before acting**: provider == "stripe", the stored provider id matches the Stripe object id, the amount matches, and the currency matches (`code.downcase` vs Stripe's lowercase currency).
- **Idempotent and order-safe**: Stripe retries events and can deliver them out of order. Guard on the current status, and never move a terminal status back unless it's a deliberate late reversal (e.g. `payout.failed` after `paid` → `Ledger::ReverseWithdrawal`).
- **Ledger posts only here**: money enters or leaves the ledger only after a verified success event, with a fixed reference (`"PAYMENT-#{id}"`). If a new money flow is needed, use the `ledger-operation` skill.
- `return` inside `Model.transaction do` commits the transaction. That's fine for status guards, but don't `return` after a partial write.
- Use the enum spelling exactly (`canceled`, not `cancelled`), and pass `user: record.user` to audit logs (`@user` is not set in this service).
- Make sure every method signature matches how it's called. `process_refund_failed!` is currently called with an argument it doesn't accept; don't repeat that mistake.
- Unknown events are logged and marked processed. Don't raise for them, or Stripe will retry forever.
- If the event needs to be enabled in the Stripe dashboard or CLI, tell the user.

## 3. Tests (`test/services/payments/process_stripe_webhook_test.rb`)
Build events without the network:
```ruby
def stripe_event(type:, object:, id: "evt_#{SecureRandom.hex(8)}")
  Stripe::Event.construct_from(id: id, type: type, data: { object: object })
end

event = stripe_event(type: "payment_intent.succeeded", object: {
  id: payment.provider_payment_id, object: "payment_intent",
  amount: payment.amount, currency: "usd", metadata: { payment_id: payment.id.to_s }
})
Payments::ProcessStripeWebhook.call(event: event)
```
Cover:
- the happy path: status updated, ledger balances changed, audit log created
- the same event delivered twice: one `WebhookEvent`, ledger posted once
- a different event id for an already-terminal record: no change
- mismatched amount, currency or provider id, and missing metadata → `ArgumentError`, nothing posted
- an out-of-order sequence where relevant (e.g. failed after succeeded)

For the controller test, stub signature verification: `Stripe::Webhook.stub(:construct_event, event) { post "/api/v1/webhooks/stripe", ... }`, and test that a bad signature returns 400.

Finish with the `verify` skill.
