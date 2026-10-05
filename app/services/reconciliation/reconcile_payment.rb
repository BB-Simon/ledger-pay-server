module Reconciliation
  class ReconcilePayment
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
      ReconciliationRecord.create!(
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
      ReconciliationRecord.create!(
        provider: "stripe",
        provider_reference: @payment_intent.id,
        record_type: "payment",
        internal_type: "Payment",
        internal_id: payment.id,
        expected_amount: payment.amount,
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
      ReconciliationRecord.create!(
        provider: "stripe",
        provider_reference: @payment_intent.id,
        record_type: "payment",
        internal_type: "Payment",
        internal_id: payment.id,
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
