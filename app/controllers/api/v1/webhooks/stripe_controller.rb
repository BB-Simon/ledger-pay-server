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

          render json: { received: true }, status: :ok

        rescue JSON::ParserError
          render json: { error: "Invalid payload" }, status: :bad_request
        rescue Stripe::SignatureVerificationError
          render json: { error: "Invalid signature" }, status: :bad_request
        end
      end
    end
  end
end
