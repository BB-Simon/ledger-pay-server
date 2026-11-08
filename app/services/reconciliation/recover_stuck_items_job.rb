require "sidekiq/api"

module Reconciliation
  # Puts reconciliation items back to work when their job was lost:
  # - processing for longer than STALE_AFTER (the worker died): released to
  #   pending, then enqueued;
  # - pending and idle for longer than STALE_AFTER: enqueued.
  # An item is enqueued only if Sidekiq holds no job for it (queued,
  # scheduled, or waiting to retry), so items in retry backoff aren't
  # duplicated.
  class RecoverStuckItemsJob
    include Sidekiq::Job

    sidekiq_options queue: :default, retry: 3

    STALE_AFTER = 15.minutes

    JOB_CLASSES = {
      "payment" => Reconciliation::PaymentJob,
      "refund" => Reconciliation::RefundJob,
      "payout" => Reconciliation::PayoutJob
    }.freeze

    # [job class name, item id] for every reconciliation item job that
    # Sidekiq still holds. Read once per pass.
    def self.jobs_in_sidekiq
      class_names = JOB_CLASSES.values.map(&:name)
      queues = JOB_CLASSES.values.map { |job_class| job_class.get_sidekiq_options["queue"].to_s }.uniq
      sources = [ Sidekiq::RetrySet.new, Sidekiq::ScheduledSet.new ] +
        queues.map { |queue| Sidekiq::Queue.new(queue) }

      sources.each_with_object(Set.new) do |source, held|
        source.each do |job|
          held << [ job.klass, job.args.first ] if class_names.include?(job.klass)
        end
      end
    end

    def perform
      @jobs_in_sidekiq = self.class.jobs_in_sidekiq

      recover_stale_processing_items
      reenqueue_stale_pending_items
    end

    private

    def recover_stale_processing_items
      cutoff = STALE_AFTER.ago

      ReconciliationRunItem
        .where(status: :processing)
        .where("started_at < ?", cutoff)
        .find_each do |item|
          released = item.with_lock do
            next false unless item.processing?
            next false unless item.started_at && item.started_at < cutoff

            item.update!(status: :pending, started_at: nil)
            true
          end

          enqueue_item(item) if released
        end
    end

    def reenqueue_stale_pending_items
      cutoff = STALE_AFTER.ago

      ReconciliationRunItem
        .where(status: :pending)
        .where("updated_at < ?", cutoff)
        .find_each do |item|
          enqueue_item(item)
        end
    end

    def enqueue_item(item)
      job_class = JOB_CLASSES.fetch(item.record_type)
      return if @jobs_in_sidekiq.include?([ job_class.name, item.id ])

      job_class.perform_async(item.id)

      # Refresh updated_at so a repeatedly failing enqueue is not
      # immediately selected again on every recovery pass.
      item.touch if item.pending?
    rescue StandardError => e
      Rails.logger.error(
        "Reconciliation recovery failed for item #{item.id}: " \
        "#{e.class}: #{e.message}"
      )
    end
  end
end
