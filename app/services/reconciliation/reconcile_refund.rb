module Reconciliation
  class ReconcileRefund
    # Local statuses that agree with each Stripe refund status. Any status not
    # listed (pending, requires_action) is still in progress at Stripe.
    EXPECTED_STATUSES = {
      "succeeded" => %w[succeeded],
      "failed" => %w[failed],
      "canceled" => %w[canceled]
    }.freeze
    IN_PROGRESS_STATUSES = %w[pending].freeze

    def self.call(stripe_refund:)
      new(stripe_refund: stripe_refund).call
    end

    def initialize(stripe_refund:)
      @stripe_refund = stripe_refund
    end

    def call
      refund = find_refund

      unless refund
        return Reconciliation::CreateRecord.call(
          provider: "stripe",
          provider_reference: @stripe_refund.id,
          record_type: "refund",
          actual_amount: @stripe_refund.amount,
          currency: @stripe_refund.currency,
          status: :discrepancy,
          discrepancy_type: :missing_internal_record,
          details: {
            provider_status: @stripe_refund.status
          }
        )
      end

      discrepancies = []

      if refund.amount != @stripe_refund.amount
        discrepancies << :amount_mismatch
      end

      if refund.payment.currency.code.downcase != @stripe_refund.currency
        discrepancies << :currency_mismatch
      end

      expected = EXPECTED_STATUSES.fetch(@stripe_refund.status, IN_PROGRESS_STATUSES)
      discrepancies << :status_mismatch unless expected.include?(refund.status)

      if discrepancies.empty?
        Reconciliation::CreateRecord.call(
          provider: "stripe",
          provider_reference: @stripe_refund.id,
          record_type: "refund",
          internal: refund,
          expected_amount: refund.amount,
          actual_amount: @stripe_refund.amount,
          currency: @stripe_refund.currency,
          status: :matched,
          details: {
            provider_status: @stripe_refund.status,
            internal_status: refund.status
          }
        )
      else
        Reconciliation::CreateRecord.call(
          provider: "stripe",
          provider_reference: @stripe_refund.id,
          record_type: "refund",
          internal: refund,
          expected_amount: refund.amount,
          actual_amount: @stripe_refund.amount,
          currency: @stripe_refund.currency,
          status: :discrepancy,
          discrepancy_type: discrepancies.first,
          details: {
            discrepancies: discrepancies,
            provider_status: @stripe_refund.status,
            internal_status: refund.status
          }
        )
      end
    end

    private

    def find_refund
      Refund.find_by(
        provider: "stripe",
        provider_refund_id: @stripe_refund.id
      )
    end
  end
end
