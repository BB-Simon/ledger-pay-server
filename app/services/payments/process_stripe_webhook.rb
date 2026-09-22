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

      WebhookEvent.transaction do
        webhook_event.lock!

        return webhook_event if webhook_event.processed?

        case @event.type
        when "payment_intent.succeeded"
          process_payment_intent_succeeded!

        when "payment_intent.payment_failed"
          process_payment_intent_payment_failed!

        when "payment_intent.canceled"
          process_payment_intent_canceled!

        else
          Rails.logger.info "Ignore unsuported event #{@event.type}"
        end

        webhook_event.update!(
          status: :processed,
          processed_at: Time.current
        )
      end


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
      payment = find_payment_from_intent!(intent)

      Payment.transaction do
        payment = Payment.lock.find(payment.id)
        return if payment.succeeded?

        validate_payment!(payment, intent)

        payment.update!(status: :succeeded)

        Ledger::Deposit.call(
          wallet: payment.wallet,
          amount: payment.amount,
          reference: "PAYMENT-#{payment.id}"
        )
      end
    end

    def process_payment_intent_payment_failed!
      intent = @event.data.object

      payment = find_payment_from_intent!(intent)

      Payment.transaction do
        payment = Payment.lock.find(payment.id)

        return if payment.succeeded? || payment.failed? || payment.canceled?

        validate_payment!(payment, intent)

        payment.update!(status: :failed)
      end
    end

    def process_payment_intent_canceled!
      intent = @event.data.object

      payment = find_payment_from_intent!(intent)

      Payment.transaction do
        payment = Payment.lock.find(payment.id)

        return if payment.succeeded? || payment.failed? || payment.canceled?

        validate_payment!(payment, intent)

        payment.update!(status: :canceled)
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

    def find_payment_from_intent!(intent)
      payment_id = intent.metadata[:payment_id]

      raise ArgumentError, "Payment ID is missing  from stripe metadata" if payment_id.blank?

      Payment.find(payment_id)
    end
  end
end
