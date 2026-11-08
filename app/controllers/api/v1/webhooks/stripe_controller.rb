module Api
  module V1
    module Webhooks
      class StripeController < ApplicationController
        def create
          payload = request.body.read

          signature = request.headers["Stripe-Signature"]

          event = Stripe::Webhook.construct_event(
            payload,
            signature,
            ENV.fetch("STRIPE_WEBHOOK_SECRET")
          )
          Rails.logger.info "Stripe webhook received: #{event.id} #{event.type}"

          # Events that can never be applied come back marked failed (and
          # audit-logged), and are still acknowledged so Stripe stops retrying.
          Payments::ProcessStripeWebhook.call(event: event)

          render json: { received: true }, status: :ok

        # Any non-2xx makes Stripe redeliver the event later.
        rescue Payments::ProcessStripeWebhook::NotReady => e
          Rails.logger.warn "Stripe webhook #{event.id} not ready: #{e.message}"
          render json: { error: e.message }, status: :conflict

        rescue JSON::ParserError
          render json: { error: "Invalid payload" }, status: :bad_request
        rescue Stripe::SignatureVerificationError
          render json: { error: "Invalid signature" }, status: :bad_request
        rescue ArgumentError => e
          Rails.logger.error "Stripe webhook argument error: #{e.message}"
          render json: { error: e.message }, status: :unprocessable_entity
        end
      end
    end
  end
end
