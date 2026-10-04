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
          process_withdrawal_cancelled!

        else
          Rails.logger.info "Ignore unsupported event #{@event.type}"
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
      payment_id = intent.metadata["payment_id"]

      raise ArgumentError, "Payment ID is missing  from stripe metadata" if payment_id.blank?

      Payment.find(payment_id)
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
          user: @user,
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
              reason: withdrawal.failure_message
            }
          )
        end

        AuditLogs::Record.call(
          action: "withdrawal.failed",
          auditable: withdrawal,
          user: @user,
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

    def process_withdrawal_cancelled!
      payout = @event.data.object

      withdrawal = find_withdrawal_from_payout!(payout)

      validate_withdrawal!(withdrawal, payout)

      Withdrawal.transaction do
        withdrawal = Withdrawal.lock.find(withdrawal.id)

        return if withdrawal.succeeded? ||
                  withdrawal.failed? ||
                  withdrawal.canceled?

        withdrawal.update!(
          status: :cancelled
        )

        AuditLogs::Record.call(
          action: "withdrawal.canceled",
          auditable: withdrawal,
          user: @user,
          metadata: {
            amount: withdrawal.amount,
            currency: withdrawal.currency.code
          }
        )
      end
    end

    def find_withdrawal_from_payout!(payout)
      withdrawal_id = payout.metadata["withdrawal_id"]

      raise ArgumentError, "Withdrawal ID missing from Stripe metadata" if
        withdrawal_id.blank?

      Withdrawal.find(withdrawal_id)
    end

    def validate_withdrawal!(withdrawal, payout)
      raise ArgumentError, "Withdrawal provider mismatch" unless
        withdrawal.provider == "stripe"

      raise ArgumentError, "Stripe payout ID mismatch" unless
        withdrawal.provider_withdrawal_id == payout.id

      raise ArgumentError, "Withdrawal amount mismatch" unless
        withdrawal.amount == payout.amount

      raise ArgumentError, "Withdrawal currency mismatch" unless
        withdrawal.currency.code.downcase == payout.currency
    end
  end
end
