
module Reconciliation
  class Run
    RUN_TYPES = %w[payments refunds payouts].freeze

    def self.call(provider: "stripe", run_type:)
      new(provider: provider, run_type: run_type).call
    end

    def initialize(provider:, run_type:)
      @provider = provider
      @run_type = run_type.to_s
    end

    def call
      raise ArgumentError, "Unsupported provider" unless @provider == "stripe"
      raise ArgumentError, "Unsupported run type" unless RUN_TYPES.include?(@run_type)

      run = ReconciliationRun.create!(
        provider: @provider,
        run_type: @run_type,
        status: :running,
        started_at: Time.current
      )

      items = []

      ReconciliationRun.transaction do
        candidate_records.each do |record|
          items << run.reconciliation_run_items.create!(
            record_type: item_record_type,
            internal_type: record.class.name,
            internal_id: record.id,
            provider_reference: provider_reference_for(record),
            status: :pending
          )
        end

        run.update!(total_items: items.size)
      end

      if items.empty?
        run.update!(status: :completed, completed_at: Time.current)
        return run
      end

      items.each do |item|
        begin
          job_class.perform_async(item.id)
        rescue StandardError => e
          Reconciliation::CompleteRunItem.call(
            item_id: item.id,
            status: :failed,
            error: e
          )
        end
      end

      run.reload
    rescue StandardError => e
      if run&.persisted?
        run.update!(
          status: :failed,
          completed_at: Time.current,
          error_message: "#{e.class}: #{e.message}"
        )
      end

      raise
    end

    private

    def candidate_records
      cutoff = 24.hours.ago

      case @run_type
      when "payments"
        Payment.where(provider: @provider)
          .where(created_at: cutoff..)
          .where.not(provider_payment_id: [ nil, "" ])
          .to_a

      when "refunds"
        Refund.joins(:payment)
          .where(payments: { provider: @provider })
          .where(refunds: { created_at: cutoff.. })
          .where.not(provider_refund_id: [ nil, "" ])
          .to_a

      when "payouts"
        Withdrawal.where(provider: @provider)
          .where(created_at: cutoff..)
          .where.not(provider_withdrawal_id: [ nil, "" ])
          .to_a
      end
    end

    def item_record_type
      {
        "payments" => "payment",
        "refunds" => "refund",
        "payouts" => "payout"
      }.fetch(@run_type)
    end

    def provider_reference_for(record)
      case @run_type
      when "payments" then record.provider_payment_id
      when "refunds" then record.provider_refund_id
      when "payouts" then record.provider_withdrawal_id
      end
    end

    def job_class
      {
        "payments" => Reconciliation::PaymentJob,
        "refunds" => Reconciliation::RefundJob,
        "payouts" => Reconciliation::PayoutJob
      }.fetch(@run_type)
    end
  end
end
