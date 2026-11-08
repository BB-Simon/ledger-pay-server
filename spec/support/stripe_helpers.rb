# Specs never call Stripe. These build fake Stripe objects and sign webhook
# payloads the way Stripe does.
module StripeHelpers
  WEBHOOK_SECRET = "whsec_test_secret".freeze

  def fake_stripe(klass, **attrs)
    klass.construct_from(attrs)
  end

  # rswag posts JSON bodies as body.to_json, which is deterministic for a
  # Hash, so signing body.to_json signs exactly what is sent.
  def stripe_signature_for(body, secret: WEBHOOK_SECRET)
    now = Time.now
    signature = Stripe::Webhook::Signature.compute_signature(now, body.to_json, secret)
    Stripe::Webhook::Signature.generate_header(now, signature)
  end

  # The webhook controller reads the secret from ENV at request time.
  def with_webhook_secret(secret = WEBHOOK_SECRET)
    original = ENV["STRIPE_WEBHOOK_SECRET"]
    ENV["STRIPE_WEBHOOK_SECRET"] = secret
    yield
  ensure
    ENV["STRIPE_WEBHOOK_SECRET"] = original
  end
end
