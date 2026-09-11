module Payments
  class ProcessStripeWebhook
    def self.call(event:)
      new(event).call
    end

    def initialize(event)
      @event = event
    end

    def call
      webhook_event = save_event!

      return webhook_event if webhook_event.processed?

      case @event.type
      when "payment_intent.succeeded"
        process_payment_intent_succeeded!
      else
        Rails.logger.info "Ignore unsuported event #{@event.type}"
      end

      webhook_event.update!(
        status: :processed,
        processed_at: Time.current
      )

      webhook_event
    end

    private

    def save_event!
      WebhookEvent.create!(
        provider: "stripe",
        event_id: @event.id,
        event_type: @event.type,
        payload: @event.to_json,
        status: :pending
      )
    rescue ActiveRecord::RecordNotUnique
      WebhookEvent.find_by!(event_id: @event.id, provider: "stripe")
    end

    def process_payment_intent_succeeded!
      intent = @event.data.object
      payment_id = intent.metadata[:payment_id]

      raise ArgumentError, "Payment ID is missing  from stripe metadata" if payment_id.blank?

      payment = Payment.find(payment_id)
      nil if payment.succeeded?

      validate_payment!(payment, intent)

      Payment.transaction do
        payment.update!(status: :succeeded)

        Ledger::Deposit.call(
          wallet: payment.wallet,
          amount: payment.amount,
          reference: "PAYMENT-#{payment.id}"
        )
      end
    end

    def validate_payment!(payment, intent)
      unless payment.provider == "stripe"
        raise ArgumentError, "Payment provider is not stripe"
      end

      unless payment.provider_payment_id == intent.id
        raise ArgumentError, "Payment provider payment ID does not match"
      end

      unless payment.amount == intent.amount
        raise ArgumentError, "Payment amount does not match"
      end
    end
  end
end
