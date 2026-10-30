
module Reconciliation
  class RecordFailure
    def self.call(run_id:, record_id:, record_type:, error:)
      run = ReconciliationRun.find_by(id: run_id)
      return unless run

      provider_reference, expected_amount, currency =
        case record_type
        when "payment"
          record = Payment.find_by(id: record_id)
          return unless record

          [
            record.provider_payment_id,
            record.amount,
            record.currency
          ]
        when "refund"
          record = Refund.find_by(id: record_id)
          return unless record

          [
            record.provider_refund_id,
            record.amount,
            record.currency
          ]
        when "payout"
          record = Withdrawal.find_by(id: record_id)
          return unless record

          [
            record.provider_withdrawal_id,
            record.amount,
            record.currency
          ]
        else
          raise ArgumentError, "Unsupported record type: #{record_type}"
        end

      return if provider_reference.blank?

      run.with_lock do
        existing = run.reconciliation_results.find_by(
          provider_reference: provider_reference
        )

        # Do not replace an existing successful result.
        return existing if existing

        run.reconciliation_results.create!(
          reconciliation_record: nil,
          provider_reference: provider_reference,
          record_type: record_type,
          status: :failed,
          expected_amount: expected_amount,
          actual_amount: nil,
          currency: currency,
          details: {
            error_class: error.class.name,
            error_message: error.message.to_s.truncate(1000)
          }
        )

        run.update!(
          failed_count: run.failed_count + 1
        )

        finalize_run(run)
      end
    end

    def self.finalize_run(run)
      terminal_count = run.records_checked + run.failed_count

      return if terminal_count < run.total_items

      run.update!(
        status: run.failed_count.positive? ? :failed : :completed,
        completed_at: Time.current
      )
    end

    private_class_method :finalize_run
  end
end
