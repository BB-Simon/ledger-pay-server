module Payments
  class ProcessStripeWebhook
    # The event can never be applied: it doesn't match our records, or has no
    # record at all. Redelivery won't help, so the event is marked failed.
    class InvalidEvent < ArgumentError; end

    # The local record exists but hasn't stored its Stripe id yet (a retry job
    # is still submitting it). Stripe should redeliver the event later.
    class NotReady < StandardError; end

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
        when "refund.created"
          process_refund_created!
        when "refund.updated"
          process_refund_updated!
        when "refund.failed"
          process_refund_failed!
        when "payout.paid"
          process_withdrawal_paid!
        when "payout.failed"
          process_withdrawal_failed!
        when "payout.canceled"
          process_withdrawal_canceled!

        else
          Rails.logger.info "Ignore unsupported event #{@event.type}"
        end

        webhook_event.update!(
          status: :processed,
          processed_at: Time.current
        )
      end

      webhook_event
    rescue InvalidEvent => e
      mark_failed!(webhook_event, e)
    end

    private

    # Runs after the processing transaction has rolled back, so nothing the
    # handler did is kept. Any other error (deadlock, timeout, a bug) is left
    # to raise: the event stays pending and Stripe redelivers it.
    def mark_failed!(webhook_event, error)
      Rails.logger.error("Stripe webhook #{@event.id} (#{@event.type}) failed: #{error.message}")

      WebhookEvent.transaction do
        webhook_event.lock!

        # A concurrent delivery of the same event may have succeeded meanwhile.
        unless webhook_event.processed?
          webhook_event.update!(status: :failed)

          # TODO: Nothing alerts anyone or lists failed webhook events yet, apart
          # from the audit log. An admin endpoint for them, or an alert, would
          # make the audit log useful.
          AuditLogs::Record.call(
            action: "webhook_event.failed",
            auditable: webhook_event,
            metadata: {
              event_id: @event.id,
              event_type: @event.type,
              error: error.message.to_s.truncate(500)
            }
          )
        end
      end

      webhook_event
    end

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

        AuditLogs::Record.call(
          action: "payment.succeeded",
          auditable: payment,
          user: payment.user,
          metadata: {
            amount: payment.amount,
            currency: payment.currency.code,
            provider_payment_id: payment.provider_payment_id
          }
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

        payment.update!(
          status: :failed,
          failure_code: intent.last_payment_error&.code,
          failure_message: intent.last_payment_error&.message
        )

        AuditLogs::Record.call(
          action: "payment.failed",
          auditable: payment,
          user: payment.user,
          metadata: {
            failure_code: payment.failure_code,
            failure_message: payment.failure_message
          }
        )
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

        AuditLogs::Record.call(
          action: "payment.canceled",
          auditable: payment,
          user: payment.user,
          metadata: {
            provider_payment_id: payment.provider_payment_id
          }
        )
      end
    end

    def validate_payment!(payment, intent)
      unless payment.provider == "stripe"
        raise InvalidEvent, "Payment provider is not stripe"
      end

      raise NotReady, "Payment #{payment.id} not submitted to Stripe yet" if
        payment.provider_payment_id.blank?

      unless payment.provider_payment_id == intent.id
        raise InvalidEvent, "Payment provider payment ID does not match"
      end

      unless payment.amount == intent.amount
        raise InvalidEvent, "Payment amount does not match"
      end
    end

    def find_payment_from_intent!(intent)
      payment_id = intent.metadata["payment_id"]

      raise InvalidEvent, "Payment ID is missing  from stripe metadata" if payment_id.blank?

      Payment.find_by(id: payment_id) ||
        raise(InvalidEvent, "Payment #{payment_id} from Stripe metadata not found")
    end

    def find_refund!
      stripe_refund = @event.data.object

      refund_id = stripe_refund.metadata["refund_id"]

      raise InvalidEvent, "Refund ID missing from Stripe metadata" if
        refund_id.blank?

      Refund.find_by(id: refund_id) ||
        raise(InvalidEvent, "Refund #{refund_id} from Stripe metadata not found")
    end

    def validate_refund!(refund, stripe_refund)
      raise InvalidEvent, "Refund provider mismatch" unless
        refund.provider == "stripe"

      raise NotReady, "Refund #{refund.id} not submitted to Stripe yet" if
        refund.provider_refund_id.blank?

      raise InvalidEvent, "Stripe refund ID mismatch" unless
        refund.provider_refund_id == stripe_refund.id

      raise InvalidEvent, "Refund amount mismatch" unless
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
       process_refund_failed!
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

        AuditLogs::Record.call(
          action: "refund.succeeded",
          auditable: refund,
          user: refund.payment.user,
          metadata: {
            amount: refund.amount,
            currency: refund.payment.currency.code,
            provider_refund_id: refund.provider_refund_id
          }
        )
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

        AuditLogs::Record.call(
          action: "refund.failed",
          auditable: refund,
          user: refund.payment.user,
          metadata: {
            provider_refund_id: refund.provider_refund_id
          }
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

    def process_withdrawal_paid!
      payout = @event.data.object

      withdrawal = find_withdrawal_from_payout!(payout)

      Rails.logger.info "Withdrawal: #{withdrawal.provider_withdrawal_id} - Payout: #{payout.id}"

      validate_withdrawal!(withdrawal, payout)

      Withdrawal.transaction do
        withdrawal = Withdrawal.lock.find(withdrawal.id)

        return if withdrawal.succeeded?

        return if withdrawal.failed? || withdrawal.canceled?

        withdrawal.update!(
          status: :succeeded
        )

        Ledger::Withdraw.call(
          withdrawal: withdrawal
        )

        AuditLogs::Record.call(
          action: "withdrawal.succeeded",
          auditable: withdrawal,
          user: withdrawal.user,
          metadata: {
            amount: withdrawal.amount,
            currency: withdrawal.currency.code
          }
        )
      end
    end

    def process_withdrawal_failed!
      payout = @event.data.object

      withdrawal = find_withdrawal_from_payout!(payout)

      validate_withdrawal!(withdrawal, payout)

      Withdrawal.transaction do
        withdrawal = Withdrawal.lock.find(withdrawal.id)

        return if withdrawal.failed? || withdrawal.canceled?

        if withdrawal.succeeded?
          Ledger::ReverseWithdrawal.call(
            withdrawal: withdrawal
          )

          AuditLogs::Record.call(
            action: "withdrawal.reversed",
            auditable: withdrawal,
            user: withdrawal.user,
            metadata: {
              amount: withdrawal.amount,
              currency: withdrawal.currency.code,
              reversal_reference: withdrawal.reversal_reference,
              reason: payout.failure_message
            }
          )
        end

        AuditLogs::Record.call(
          action: "withdrawal.failed",
          auditable: withdrawal,
          user: withdrawal.user,
          metadata: {
            amount: withdrawal.amount,
            currency: withdrawal.currency.code,
            late_failure: withdrawal.succeeded?
          }
        )

        withdrawal.update!(
          status: :failed,
          failure_code: payout.failure_code,
          failure_message: payout.failure_message
        )
      end
    end

    def process_withdrawal_canceled!
      payout = @event.data.object

      withdrawal = find_withdrawal_from_payout!(payout)

      validate_withdrawal!(withdrawal, payout)

      Withdrawal.transaction do
        withdrawal = Withdrawal.lock.find(withdrawal.id)

        return if withdrawal.succeeded? ||
                  withdrawal.failed? ||
                  withdrawal.canceled?

        withdrawal.update!(
          status: :canceled
        )

        AuditLogs::Record.call(
          action: "withdrawal.canceled",
          auditable: withdrawal,
          user: withdrawal.user,
          metadata: {
            amount: withdrawal.amount,
            currency: withdrawal.currency.code
          }
        )
      end
    end

    def find_withdrawal_from_payout!(payout)
      withdrawal_id = payout.metadata["withdrawal_id"]

      raise InvalidEvent, "Withdrawal ID missing from Stripe metadata" if
        withdrawal_id.blank?

      Withdrawal.find_by(id: withdrawal_id) ||
        raise(InvalidEvent, "Withdrawal #{withdrawal_id} from Stripe metadata not found")
    end

    def validate_withdrawal!(withdrawal, payout)
      raise InvalidEvent, "Withdrawal provider mismatch" unless
        withdrawal.provider == "stripe"

      raise NotReady, "Withdrawal #{withdrawal.id} not submitted to Stripe yet" if
        withdrawal.provider_withdrawal_id.blank?

      raise InvalidEvent, "Stripe payout ID mismatch" unless
        withdrawal.provider_withdrawal_id == payout.id

      raise InvalidEvent, "Withdrawal amount mismatch" unless
        withdrawal.amount == payout.amount

      raise InvalidEvent, "Withdrawal currency mismatch" unless
        withdrawal.currency.code.downcase == payout.currency
    end
  end
end
