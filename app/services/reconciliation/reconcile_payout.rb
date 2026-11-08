module Reconciliation
  class ReconcilePayout
    # Local statuses that agree with each Stripe payout status. Any status not
    # listed (pending, in_transit) is still in progress at Stripe.
    EXPECTED_STATUSES = {
      "paid" => %w[succeeded],
      "failed" => %w[failed],
      "canceled" => %w[canceled]
    }.freeze
    IN_PROGRESS_STATUSES = %w[pending].freeze

    def self.call(stripe_payout:)
      new(stripe_payout: stripe_payout).call
    end

    def initialize(stripe_payout:)
      @stripe_payout = stripe_payout
    end

    def call
      withdrawal = find_withdrawal

      unless withdrawal
        return Reconciliation::CreateRecord.call(
          provider: "stripe",
          provider_reference: @stripe_payout.id,
          record_type: "payout",
          actual_amount: @stripe_payout.amount,
          currency: @stripe_payout.currency,
          status: :discrepancy,
          discrepancy_type: :missing_internal_record,
          details: {
            provider_status: @stripe_payout.status
          }
        )
      end

      discrepancies = []

      if withdrawal.amount != @stripe_payout.amount
        discrepancies << :amount_mismatch
      end

      if withdrawal.currency.code.downcase != @stripe_payout.currency
        discrepancies << :currency_mismatch
      end

      expected = EXPECTED_STATUSES.fetch(@stripe_payout.status, IN_PROGRESS_STATUSES)
      discrepancies << :status_mismatch unless expected.include?(withdrawal.status)

      if discrepancies.empty?
        Reconciliation::CreateRecord.call(
          provider: "stripe",
          provider_reference: @stripe_payout.id,
          record_type: "payout",
          internal: withdrawal,
          expected_amount: withdrawal.amount,
          actual_amount: @stripe_payout.amount,
          currency: @stripe_payout.currency,
          status: :matched,
          details: {
            provider_status: @stripe_payout.status,
            internal_status: withdrawal.status
          }
        )
      else
        Reconciliation::CreateRecord.call(
          provider: "stripe",
          provider_reference: @stripe_payout.id,
          record_type: "payout",
          internal: withdrawal,
          expected_amount: withdrawal.amount,
          actual_amount: @stripe_payout.amount,
          currency: @stripe_payout.currency,
          status: :discrepancy,
          discrepancy_type: discrepancies.first,
          details: {
            discrepancies: discrepancies,
            provider_status: @stripe_payout.status,
            internal_status: withdrawal.status
          }
        )
      end
    end

    private

    def find_withdrawal
      Withdrawal.find_by(
        provider: "stripe",
        provider_withdrawal_id: @stripe_payout.id
      )
    end
  end
end
