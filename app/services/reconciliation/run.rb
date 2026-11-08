
module Reconciliation
  class Run
    RUN_TYPES = %w[payments refunds payouts].freeze

    # Records with a Stripe id: created recently, or still pending at any age
    # (a lost webhook would otherwise never be noticed once it's a day old).
    # Records without a Stripe id: still pending after UNSUBMITTED_AFTER,
    # which is longer than the submission retry jobs keep trying. They're
    # reported as missing_provider_record.
    RECENT_WINDOW = 24.hours
    UNSUBMITTED_AFTER = 6.hours

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
      table = base_scope.table_name
      no_provider_id = { table => { provider_id_column => [ nil, "" ] } }

      submitted = base_scope.where.not(no_provider_id)
      unsubmitted = base_scope.where(no_provider_id)

      submitted.where(table => { created_at: RECENT_WINDOW.ago.. })
        .or(submitted.where(table => { status: "pending" }))
        .or(unsubmitted.where(table => { status: "pending", created_at: ...UNSUBMITTED_AFTER.ago }))
        .to_a
    end

    def base_scope
      case @run_type
      when "payments"
        Payment.where(provider: @provider)
      when "refunds"
        Refund.joins(:payment)
          .where(payments: { provider: @provider }, refunds: { provider: @provider })
      when "payouts"
        Withdrawal.where(provider: @provider)
      end
    end

    def provider_id_column
      {
        "payments" => :provider_payment_id,
        "refunds" => :provider_refund_id,
        "payouts" => :provider_withdrawal_id
      }.fetch(@run_type)
    end

    def item_record_type
      {
        "payments" => "payment",
        "refunds" => "refund",
        "payouts" => "payout"
      }.fetch(@run_type)
    end

    def provider_reference_for(record)
      record.public_send(provider_id_column)
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
