module Payments
  class ProcessStripeRefundWebhook
    def self.call(event:)
      new(event: event).call
    end

    def initialize(event:)
      @event = event
    end

    def call
      webhook_event = find_or_create_webhook_event

      WebhookEvent.transaction do
        webhook_event.lock!

        return webhook_event if webhook_event.processed?

        case @event.type
        when "refund.created"
          process_refund_created!
        when "refund.updated"
          process_refund_updated!
        when "refund.failed"
          process_refund_failed!
        else
          Rails.logger.info(
            "Ignoring unsupported Stripe refund event: #{@event.type}"
          )
        end

        webhook_event.update!(
          status: :processed,
          processed_at: Time.current
        )
      end

      webhook_event
    end

    private

    def find_or_create_webhook_event
      WebhookEvent.create!(
        provider: "stripe",
        event_id: @event.id,
        event_type: @event.type,
        payload: @event.to_json,
        status: :pending
      )
    rescue ActiveRecord::RecordNotUnique
      WebhookEvent.find_by!(
        provider: "stripe",
        event_id: @event.id
      )
    end

    def find_refund!
      stripe_refund = @event.data.object

      refund_id = stripe_refund.metadata["refund_id"]

      raise ArgumentError, "Refund ID missing from Stripe metadata" if
        refund_id.blank?

      Refund.find(refund_id)
    end

    def validate_refund!(refund, stripe_refund)
      raise ArgumentError, "Refund provider mismatch" unless
        refund.provider == "stripe"

      raise ArgumentError, "Stripe refund ID mismatch" unless
        refund.provider_refund_id == stripe_refund.id

      raise ArgumentError, "Refund amount mismatch" unless
        refund.amount == stripe_refund.amount
    end

    def process_refund_created!
      stripe_refund = @event.data.object
      refund = find_refund!

      validate_refund!(refund, stripe_refund)

      Rails.logger.info(
        "Stripe refund created: #{stripe_refund.id}, " \
        "status=#{stripe_refund.status}"
      )
    end

    def process_refund_updated!
      stripe_refund = @event.data.object
      refund = find_refund!

      validate_refund!(refund, stripe_refund)

      case stripe_refund.status
      when "succeeded"
        process_refund_succeeded!(refund)
      when "failed"
        process_refund_failed!(refund)
      when "canceled"
        process_refund_canceled!(refund)
      end
    end

    def process_refund_succeeded!(refund)
      Refund.transaction do
        refund = Refund.lock.find(refund.id)

        return if refund.succeeded?
        return if refund.failed? || refund.canceled?

        refund.update!(
          status: :succeeded
        )

        Ledger::Refund.call(refund: refund)
      end
    end

    def process_refund_failed!
      stripe_refund = @event.data.object
      refund = find_refund!

      validate_refund!(refund, stripe_refund)

      Refund.transaction do
        refund = Refund.lock.find(refund.id)

        return if refund.succeeded? || refund.failed? || refund.canceled?

        refund.update!(
          status: :failed
        )
      end
    end

    def process_refund_canceled!(refund)
      Refund.transaction do
        refund = Refund.lock.find(refund.id)

        return if refund.succeeded? || refund.failed? || refund.canceled?

        refund.update!(
          status: :canceled
        )
      end
    end
  end
end
