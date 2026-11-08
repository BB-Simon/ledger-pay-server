module Reconciliation
  # Reconciles one run item against Stripe. PaymentJob, RefundJob and
  # PayoutJob all call this; the item's record_type picks the Stripe object.
  #
  # - Claims the item under a lock (skipped if it's finished or another
  #   worker claimed it recently).
  # - Stripe doesn't have the object, or we never got a Stripe id:
  #   missing_provider_record discrepancy.
  # - The local record can't be reconciled at all (deleted, not Stripe):
  #   the item fails right away instead of looping.
  # - Any other error releases the item and raises, so Sidekiq retries.
  class ProcessItem
    CLAIM_TIMEOUT = 15.minutes

    class NotReconcilable < StandardError; end

    TYPES = {
      "payment" => {
        model: Payment,
        provider_id: :provider_payment_id,
        stripe_class: Stripe::PaymentIntent,
        reconcile: ->(object) { ReconcilePayment.call(payment_intent: object) },
        currency: ->(payment) { payment.currency.code }
      },
      "refund" => {
        model: Refund,
        provider_id: :provider_refund_id,
        stripe_class: Stripe::Refund,
        reconcile: ->(object) { ReconcileRefund.call(stripe_refund: object) },
        currency: ->(refund) { refund.payment.currency.code }
      },
      "payout" => {
        model: Withdrawal,
        provider_id: :provider_withdrawal_id,
        stripe_class: Stripe::Payout,
        reconcile: ->(object) { ReconcilePayout.call(stripe_payout: object) },
        currency: ->(withdrawal) { withdrawal.currency.code }
      }
    }.freeze

    # Used as the reference when there's no Stripe id. Refunds and payouts
    # match the idempotency keys sent to Stripe.
    LOCAL_REFERENCE_PREFIX = {
      "payment" => "payment",
      "refund" => "refund",
      "payout" => "withdrawal"
    }.freeze

    def self.call(item_id:)
      new(item_id: item_id).call
    end

    def initialize(item_id:)
      @item_id = item_id
    end

    def call
      @item = ReconciliationRunItem.find(@item_id)
      return unless claim!

      record = reconcile

      Reconciliation::RecordResult.call(
        run_id: @item.reconciliation_run_id,
        record: record
      )

      Reconciliation::CompleteRunItem.call(
        item_id: @item.id,
        status: record.matched? ? :matched : :discrepancy
      )
    rescue NotReconcilable => e
      Reconciliation::CompleteRunItem.call(item_id: @item.id, status: :failed, error: e)
    rescue StandardError
      release!
      raise
    end

    private

    def config
      @config ||= TYPES.fetch(@item.record_type)
    end

    def claim!
      @item.with_lock do
        next false if @item.terminal?
        next false if @item.processing? && @item.started_at && @item.started_at > CLAIM_TIMEOUT.ago

        @item.update!(
          status: :processing,
          started_at: Time.current,
          attempts: @item.attempts + 1
        )

        true
      end
    end

    def release!
      return unless @item

      @item.with_lock do
        @item.update!(status: :pending, started_at: nil) unless @item.terminal?
      end
    end

    def reconcile
      internal = config[:model].find_by(id: @item.internal_id)

      raise NotReconcilable, "#{config[:model].name} #{@item.internal_id} no longer exists" unless internal
      raise NotReconcilable, "#{config[:model].name} #{internal.id} is not a Stripe record" unless
        internal.provider == "stripe"

      provider_id = internal.public_send(config[:provider_id])
      return missing_provider_record(internal, reason: "never_submitted") if provider_id.blank?

      config[:reconcile].call(config[:stripe_class].retrieve(provider_id))
    rescue Stripe::InvalidRequestError => e
      raise unless e.code == "resource_missing"

      missing_provider_record(internal, reason: "not_found_at_provider")
    end

    def missing_provider_record(internal, reason:)
      provider_id = internal.public_send(config[:provider_id])

      Reconciliation::CreateRecord.call(
        provider: "stripe",
        provider_reference: provider_id.presence ||
          "#{LOCAL_REFERENCE_PREFIX.fetch(@item.record_type)}-#{internal.id}",
        record_type: @item.record_type,
        internal: internal,
        expected_amount: internal.amount,
        currency: config[:currency].call(internal).downcase,
        status: :discrepancy,
        discrepancy_type: :missing_provider_record,
        details: {
          reason: reason,
          internal_status: internal.status
        }
      )
    end
  end
end
