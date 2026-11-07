# How to treat a Stripe error when creating money movements (refunds, payouts).
module StripeErrors
  # Stripe rejected the request, so nothing was created. Safe to mark the
  # local record failed and release any hold on the wallet.
  #
  # Every other Stripe::StripeError (timeouts, 5xx, rate limits) means the
  # outcome is unknown: Stripe may have created it. Keep the record pending
  # and retry with the same idempotency key.
  DEFINITE_FAILURES = [
    Stripe::InvalidRequestError,
    Stripe::CardError,
    Stripe::AuthenticationError,
    Stripe::PermissionError,
    Stripe::IdempotencyError
  ].freeze
end
