module Reconciliation
  class ReconcilePayment
    # Local statuses that agree with each PaymentIntent status. After a failed
    # attempt Stripe goes back to requires_payment_method, which we record as
    # failed. Any status not listed is still in progress at Stripe.
    EXPECTED_STATUSES = {
      "succeeded" => %w[succeeded],
      "canceled" => %w[canceled],
      "requires_payment_method" => %w[pending failed]
    }.freeze
    IN_PROGRESS_STATUSES = %w[pending].freeze

    def self.call(payment_intent:)
      new(payment_intent: payment_intent).call
    end

    def initialize(payment_intent:)
      @payment_intent = payment_intent
    end

    def call
      payment = find_payment

      unless payment
        return create_missing_internal_record
      end

      discrepancies = []

      if payment.amount != @payment_intent.amount
        discrepancies << "amount_mismatch"
      end

      if payment.currency.code.downcase != @payment_intent.currency
        discrepancies << "currency_mismatch"
      end

      expected = EXPECTED_STATUSES.fetch(@payment_intent.status, IN_PROGRESS_STATUSES)
      discrepancies << "status_mismatch" unless expected.include?(payment.status)

      if discrepancies.empty?
        create_matched_record(payment)
      else
        create_discrepancy_record(
          payment: payment,
          discrepancies: discrepancies
        )
      end
    end

    private

    def find_payment
      Payment.find_by(
        provider: "stripe",
        provider_payment_id: @payment_intent.id
      )
    end

    def create_missing_internal_record
      Reconciliation::CreateRecord.call(
        provider: "stripe",
        provider_reference: @payment_intent.id,
        record_type: "payment",
        status: :discrepancy,
        discrepancy_type: :missing_internal_record,
        actual_amount: @payment_intent.amount,
        currency: @payment_intent.currency,
        details: {
          provider_status: @payment_intent.status
        }
      )
    end

    def create_matched_record(payment)
      Reconciliation::CreateRecord.call(
        provider: "stripe",
        provider_reference: @payment_intent.id,
        record_type: "payment",
        internal: payment,
        actual_amount: @payment_intent.amount,
        currency: @payment_intent.currency,
        status: :matched,
        details: {
          provider_status: @payment_intent.status,
          internal_status: payment.status
        }
      )
    end

    def create_discrepancy_record(payment:, discrepancies:)
      Reconciliation::CreateRecord.call(
        provider: "stripe",
        provider_reference: @payment_intent.id,
        record_type: "payment",
        internal: payment,
        expected_amount: payment.amount,
        actual_amount: @payment_intent.amount,
        currency: @payment_intent.currency,
        status: :discrepancy,
        discrepancy_type: discrepancies.first,
        details: {
          discrepancies: discrepancies,
          provider_status: @payment_intent.status,
          internal_status: payment.status
        }
      )
    end
  end
end
