require "sidekiq/cron"

Sidekiq.configure_server do |config|
  config.on(:startup) do
    Sidekiq::Cron::Job.load_from_hash(
      "reconciliation_payments" => {
        "cron" => "*/4 * * * *",
        "class" => "Reconciliation::PaymentsJob",
        "queue" => "default"
      },
      "reconciliation_refunds" => {
        "cron" => "*/7 * * * *",
        "class" => "Reconciliation::RefundsJob",
        "queue" => "default"
      },
      "reconciliation_payouts" => {
        "cron" => "*/10 * * * *",
        "class" => "Reconciliation::PayoutsJob",
        "queue" => "default"
      },
      "reconciliation_recover_stuck_items" => {
        "cron" => "*/30 * * * *",
        "class" => "Reconciliation::RecoverStuckItemsJob",
        "queue" => "default"
      }
    )
  end
end
