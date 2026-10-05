module Reconciliation
  class ReconcilePayout
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
