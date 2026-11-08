# Bug report: ledger_pay_server

Audit date: 2026-11-07. Severity levels:
- **Critical**: money can be lost, duplicated or left unrecorded.
- **High**: a flow is broken or stuck, or state is wrong.
- **Medium**: correctness or robustness gap.
- **Low**: cleanup.

Each entry gives the location, what happens, and the fix. Every fix needs a failing test first (AGENTS.md).

## Critical

### C1. An idempotent transfer retry always fails with 422 — FIXED (test: `test/services/ledger/idempotent_transfer_test.rb`)
- **Where:** `app/services/ledger/idempotent_transfer.rb`, `generate_request_hash`
- **What happens:** `[@from_wallet, @to_wallet, @amount].join(":")` calls `to_s` on ActiveRecord objects, which gives `#<Wallet:0x000...>`, a memory address that changes on every request. A retry with the same `Idempotency-Key` and identical params gets a different hash and raises "Idempotency key already exists with a different request hash". Idempotency never works.
- **Fix:** hash stable values: `[@from_wallet.id, @to_wallet.id, @amount].join(":")`.

### C2. A duplicate Idempotency-Key can move money twice — FIXED (test: `test/services/ledger/idempotent_transfer_concurrency_test.rb`)
- **Where:** `app/services/ledger/idempotent_transfer.rb`, `call` / `find_or_create_idempotency_key`
- **What happens:**
  - Request A inserts the key with status `processing`. Request B with the same key hits `RecordNotUnique`, finds A's row with no `ledger_transaction` yet, and runs its own `Ledger::Transfer`. That's two transfers.
  - Separately, the key insert, the transfer and `record.update!` aren't in one DB transaction. A crash between the transfer and the update leaves a key with no transaction, so the next retry transfers again.
- **Fix:** do the key, the transfer and the key update in a single transaction, with the key row locked:
  ```ruby
  IdempotencyKey.transaction do
    record = begin
      IdempotencyKey.transaction(requires_new: true) do
        IdempotencyKey.create!(user: @user, key: @idempotency_key, request_hash:, status: "processing")
      end
    rescue ActiveRecord::RecordNotUnique
      IdempotencyKey.find_by!(user: @user, key: @idempotency_key)
    end
    record.lock!                                   # B waits here until A commits
    raise ArgumentError, "Idempotency key reused with different parameters" if record.request_hash != request_hash
    return record.ledger_transaction if record.ledger_transaction

    transfer = Ledger::Transfer.call(...)
    record.update!(status: "completed", ledger_transaction: transfer)
    AuditLogs::Record.call(...)
    transfer
  end
  ```
  If the transfer fails, the whole transaction rolls back and the key isn't kept, so the client can retry safely.

### C3. Transfers can spend money held by a pending withdrawal — FIXED with fixes 1 and 2 (tests: `test/services/ledger/transfer_test.rb`, `transfer_withdrawal_concurrency_test.rb`). Fix 3 (posting the hold to the ledger) is not done; the settlement-time balance check in `Ledger::Withdraw` is covered by C4.
- **Where:** `app/services/ledger/transfer.rb` `validate_blance!`, and `app/services/withdrawals/create_withdrawal.rb`
- **What happens:**
  - `Transfer` checks `account.balance`, but `CreateWithdrawal` only reserves funds through `Wallet#available_balance` (balance minus pending withdrawals). A user with 100 can withdraw 100 (still pending) and then transfer 100 away.
  - The two services also lock different rows: `Transfer` locks `Account` and `CreateWithdrawal` locks `Wallet`. So even concurrent requests aren't serialized.
  - When `payout.paid` arrives, `Ledger::Withdraw` raises "Insufficient wallet balance". The webhook returns 422 forever, and Stripe has paid out money the ledger never debited.
- **Fix:**
  1. `Transfer` checks `@from_wallet.available_balance >= @amount`.
  2. `CreateWithdrawal` locks `wallet.account` (the same row `Transfer` locks) before its balance check.
  3. A sturdier alternative: post the hold to the ledger when the withdrawal is created (debit the wallet, credit `WITHDRAWAL_CLEARING`), and reverse it if the payout fails. Then the balance itself enforces the hold.

### C4. A refund or payout can settle at Stripe while the ledger refuses to post it — FIXED (tests: `test/services/payments/create_refund_test.rb`, `test/services/ledger/settlement_test.rb`, `test/services/payments/process_stripe_webhook_settlement_test.rb`)
- **Where:** `app/services/ledger/refund.rb` and `app/services/ledger/withdraw.rb` (`validate!` balance checks), and `app/services/payments/create_refund.rb`
- **What happens:**
  - `CreateRefund` never checks the wallet balance. A user can deposit 100, transfer 100 away, then refund the payment. Stripe refunds the card, but `Ledger::Refund` raises "Insufficient wallet balance", the webhook returns 422 forever, and the refund stays `pending`. Money has left the platform with no ledger record.
  - Both ledger services also check the balance **without locking the account**, so they race with `Transfer`, which does lock.
- **Fix:**
  - At creation: lock the wallet account and require `available_balance >= amount`. Count pending refunds in `Wallet#available_balance`, the same way pending withdrawals are counted.
  - At settlement: the money has already moved, so don't block on the balance. Lock the account, post anyway (the balance may go negative), and record an audit log or `ReconciliationRecord` for follow-up.

### C5. Creating a refund isn't idempotent at Stripe, and errors leave orphan refunds — FIXED (test: `test/services/payments/submit_refund_test.rb`)
- **Where:** `app/services/payments/create_refund.rb`
- **What happens:**
  - `Stripe::Refund.create` is called without an `idempotency_key`. If the request times out after Stripe created the refund, the user's retry creates a **second real refund**.
  - Any Stripe error leaves the local refund `pending` with no `provider_refund_id`. It permanently reserves part of `refundable_amount`, and reconciliation skips it because it filters out rows without a provider id.
- **Fix:**
  - Pass `{ idempotency_key: "refund-#{refund.id}" }`, the way `CreateProviderWithdrawal` already does.
  - On a permanent `Stripe::StripeError` (invalid request, card error), mark the refund `failed` and write an audit log.
  - On a connection or timeout error, keep it `pending` and enqueue a retry job that calls Stripe again with the same idempotency key.

### C6. A Stripe error during withdrawal returns 500 and holds funds forever — FIXED (tests: `test/services/withdrawals/submit_withdrawal_test.rb`, `test/controllers/api/v1/withdrawals_controller_test.rb`)
- **Where:** `app/services/withdrawals/create_withdrawal.rb`, `create_provider_withdrawal.rb`, and `withdrawals_controller.rb`
- **What happens:** if `Stripe::Payout.create` raises, the controller only rescues `ArgumentError`, so the response is 500. The withdrawal stays `pending` with no provider id, so `available_balance` stays reduced indefinitely and reconciliation never looks at it.
- **Fix:** the same pattern as C5. A permanent error marks the withdrawal `failed`, which releases the hold. A transient error keeps it pending and enqueues a retry job; the existing idempotency key `withdrawal-#{id}` makes the retry safe. The controller rescues `Stripe::StripeError` and returns `{ error }` with 422 or 502.

## High

### H1. A `refund.updated` event with status `failed` crashes — FIXED (test: `test/services/payments/process_stripe_webhook_test.rb`)
- **Where:** `app/services/payments/process_stripe_webhook.rb`, `process_refund_updated!`
- **What happens:** it calls `process_refund_failed!(refund)`, but that method takes no arguments. Ruby raises an `ArgumentError` (wrong number of arguments), the controller returns 422, and Stripe keeps retrying. The refund stays `pending` and keeps reserving `refundable_amount`.
- **Fix:** split the handler. `process_refund_failed!` (the event entry point) finds and validates the refund, then calls a new `mark_refund_failed!(refund)`, which `process_refund_updated!` can also call.

### H2. A `payout.canceled` event crashes — FIXED (test: `test/services/payments/process_stripe_webhook_test.rb`)
- **Where:** `process_stripe_webhook.rb`, `process_withdrawal_cancelled!`
- **What happens:** it sets `status: :cancelled`, but the enum value is `canceled`. Rails raises `ArgumentError` ("'cancelled' is not a valid status"), Stripe retries forever, and the withdrawal stays `pending`, holding funds.
- **Fix:** use `:canceled`, and rename the method to `process_withdrawal_canceled!`.

### H3. Withdrawal audit logs have no user and no failure reason — FIXED (test: `test/services/payments/process_stripe_webhook_test.rb`)
- **Where:** `process_stripe_webhook.rb`, the withdrawal paid, failed and canceled handlers
- **What happens:**
  - They pass `user: @user`, which is never assigned, so audit rows are saved with `user_id = nil`.
  - On a late failure, `reason: withdrawal.failure_message` is read before the update, so it's always `nil`.
- **Fix:** use `user: withdrawal.user`, and `reason: payout.failure_message`.

### H4. Permanent webhook errors are retried for days and never marked failed — FIXED (tests: `test/services/payments/process_stripe_webhook_errors_test.rb`, `test/controllers/api/v1/webhooks/stripe_controller_test.rb`). A mismatch or missing record raises `ProcessStripeWebhook::InvalidEvent`: the event is marked `failed`, a `webhook_event.failed` audit log is written, and the response is 200. A record whose Stripe id isn't stored yet raises `NotReady` and gets 409, so Stripe retries. Every other error still raises, and Stripe retries it.
- **Where:** `app/controllers/api/v1/webhooks/stripe_controller.rb` and `process_stripe_webhook.rb`
- **What happens:** a validation mismatch (amount, id, provider, missing metadata) raises `ArgumentError`, and a missing record raises `RecordNotFound`. Both roll back and return 422 or 404, so Stripe retries for about 3 days. The `WebhookEvent` stays `pending`, the `failed` status is never used, and nobody is alerted.
- **Fix:**
  - For permanent errors, mark the `WebhookEvent` `failed` with the error message (in a new transaction after the rollback), create a `ReconciliationRecord` or audit entry for an admin, and return 200 so Stripe stops retrying.
  - Let only transient errors (DB deadlock, timeout) return 5xx, so that Stripe retries those.

### H5. Login is broken on bad credentials, and doesn't normalize the email — FIXED (test: `test/controllers/api/v1/auth/sessions_controller_test.rb`)
- **Where:** `app/controllers/api/v1/auth/sessions_controller.rb`
- **What happens:**
  - After `render ... :unauthorized` there's no `return`.
    - Unknown email: `AuthToken.create!(user: nil)` raises `RecordInvalid`, giving a 500.
    - Wrong password: a token is created for that user, then `render` runs a second time and raises `DoubleRenderError`, also a 500.
  - `params[:email.to_s.strip.downcase]` is just `params["email"]` (the `strip`/`downcase` apply to the symbol name, not the value), so `Alice@Example.com` can't log in.
  - The user's `status` isn't checked.
- **Fix:**
  ```ruby
  user = User.find_by(email: params[:email].to_s.strip.downcase)
  unless user&.authenticate(params[:password].to_s) && user.status == "active"
    return render json: { error: "Invalid email or password" }, status: :unauthorized
  end
  ```

### H6. A transfer without an `Idempotency-Key` header returns 500 — FIXED (test: `test/controllers/api/v1/transfers_controller_test.rb`)
- **Where:** `app/controllers/api/v1/transfers_controller.rb`
- **What happens:** the key is `nil`, so `IdempotencyKey.create!` raises `RecordInvalid` ("Key can't be blank"), which isn't rescued.
- **Fix:** check the header in the controller: `return render json: { error: "Idempotency-Key header is required" }, status: :unprocessable_entity if key.blank?`.

### H7. The admin "retry run item" endpoint always returns 404 — FIXED (test: `test/controllers/api/v1/admin/reconciliation_runs_controller_test.rb`)
- **Where:** `app/controllers/api/v1/admin/reconciliation_runs_controller.rb`, `set_item`
- **What happens:** the route is `/reconciliation_runs/:id/items/:item_id/retry`, so `params[:id]` is the **run** id and `params[:run_id]` doesn't exist. `find_by!(id: params[:id], reconciliation_run_id: nil)` never matches.
- **Fix:** `ReconciliationRunItem.find_by!(id: params[:item_id], reconciliation_run_id: params[:id])`.

### H8. Refund and payout reconciliation items never reach `failed`
- **Where:** `app/jobs/reconciliation/refund_job.rb` and `payout_job.rb` (`sidekiq_retries_exhausted`), and `app/services/reconciliation/record_failure.rb`
- **What happens:**
  - The jobs are enqueued with a single argument, `item_id`, but the retries-exhausted hook reads `refund_id, run_id = job["args"]`. So `run_id` is `nil` and nothing is recorded.
  - The `rescue` resets the item to `pending`, so the run never finishes. `RecoverStuckItemsJob` re-enqueues the item every 30 minutes forever, and `RetryRunItem` refuses because the item is never `failed`.
  - `RecordFailure` itself is also broken: its refund branch calls `refund.currency`, which doesn't exist (`NoMethodError`), and its payout branch writes a `Currency` object into a string column.
- **Fix:** copy `PaymentJob`: `Reconciliation::CompleteRunItem.call(item_id: job["args"].first, status: :failed, error: exception)`. Then either delete `RecordFailure` or fix its currency handling (`refund.payment.currency.code`, `withdrawal.currency.code`).

### H9. Refund and payout items get stuck if the record isn't reconcilable
- **Where:** `refund_job.rb` and `payout_job.rb`, the `return unless ...provider == "stripe"` and `return if provider_..._id.blank?` lines
- **What happens:** these early returns happen **after** the item has been claimed as `processing`. The item is never completed, gets reset to `pending` by recovery, and loops forever.
- **Fix:** move the checks before the claim, or complete the item: `CompleteRunItem.call(item_id:, status: :discrepancy)` with a `missing_provider_record` record.

### H10. Reconciliation never compares statuses, so missed webhooks show as "matched"
- **Where:** `app/services/reconciliation/reconcile_payment.rb`, `reconcile_refund.rb`, `reconcile_payout.rb`, and `run.rb`
- **What happens:**
  - Only the amount and currency are compared. A payment that is `succeeded` at Stripe but still `pending` locally (a lost webhook, so the user was never credited) is reported as **matched**. The same applies to refunds and payouts. The `status_mismatch` and `missing_provider_record` enum values are never produced.
  - When Stripe returns 404 for an object, the job retries 5 times and fails instead of recording a discrepancy.
  - Records without a provider id are excluded entirely, so the orphans from C5 and C6 are never surfaced.
  - The 24-hour `created_at` window misses late changes, such as a payout failing days later.
- **Fix:**
  - Map Stripe status to internal status for each type. For example:
    - PaymentIntent: `succeeded`↔`succeeded`, `canceled`↔`canceled`
    - payout: `paid`↔`succeeded`, `failed`↔`failed`, `canceled`↔`canceled`
    - refund: `succeeded`/`failed`/`canceled`, `pending`↔`pending`
  - Add `status_mismatch` when they differ.
  - Rescue `Stripe::InvalidRequestError` with code `resource_missing` and record `missing_provider_record`.
  - Include non-terminal records regardless of age, and treat local records with no provider id that are older than N minutes as discrepancies.

### H11. Re-reconciling a resolved discrepancy hides new problems
- **Where:** `app/services/reconciliation/create_record.rb`
- **What happens:** records are upserted by `(provider, provider_reference)` and `update!(attributes)` overwrites them, but `resolution_status`, `resolved_by` and `resolved_at` are kept. After an admin resolves a discrepancy, a later run that finds a new or different discrepancy still shows the record as `resolved`.
- **Fix:** when `status` or `discrepancy_type` changes, reset `resolution_status: :open` and clear the resolution fields. Write an audit log for the reopen.

### H12. Nothing enforces ledger immutability
- **Where:** `app/models/ledger_entry.rb`, `app/models/transaction.rb`
- **What happens:** posted entries and transactions can be updated or deleted through ActiveRecord or SQL. `AuditLog` already has `readonly?`, but the ledger models don't.
- **Fix:**
  - Add `def readonly? = persisted?` to `LedgerEntry` and `Transaction`.
  - Add a reversible migration that creates a Postgres trigger rejecting `UPDATE`/`DELETE` on `ledger_entries`, and changes to `amount`/`reference`/`currency_id` on `transactions`.

### H13. The test suite can't load — PARTLY FIXED (baseline fixtures for currencies, users, wallets, accounts; other fixture files emptied)
- **Where:** `test/fixtures/*.yml`
- **What happens:** `fixtures :all` loads scaffold placeholders, and any one of these errors stops every test:
  - `accounts.yml` sets a nonexistent `string` column.
  - `currencies.yml` has two rows with code `MyString`, which violates the unique index.
  - `users.yml` rows are `{}`, but `email` and `password_digest` are `null: false`.
  - `wallets.yml` has no `currency`.
- **Fix:** replace the placeholders with valid fixtures (see the `write-tests` skill), and empty the files for tables tests don't need yet.

### H14. CI can't pass
- **Where:** `.github/workflows/ci.yml` and `config/database.yml`
- **What happens:**
  - The test DB config calls `ENV.fetch("DATABASE_PASSWORD")`, but CI only sets `DATABASE_URL`, so loading the config raises `KeyError`.
  - `STRIPE_SECRET_KEY` isn't set in CI, so the app won't boot (`config/initializers/stripe.rb`).
  - Pushes trigger only on `master`, but the default branch is `main`.
- **Fix:**
  - Use `ENV.fetch("DATABASE_PASSWORD", nil)` (or rely on `DATABASE_URL`) in the test env.
  - Set dummy `STRIPE_SECRET_KEY`/`STRIPE_WEBHOOK_SECRET` in the CI job env.
  - Change the trigger branch to `main`.

### H15. The production deploy runs no Sidekiq, no Redis and no Stripe secrets
- **Where:** `config/deploy.yml` and `config/environments/production.rb`
- **What happens:**
  - Kamal only defines a web role. The Redis accessory is commented out, and only `RAILS_MASTER_KEY` is passed.
  - In production the app won't boot (`ENV.fetch("STRIPE_SECRET_KEY")`), and if it did, reconciliation cron jobs would never run.
  - `active_job.queue_adapter = :solid_queue` is configured, but no job uses ActiveJob.
- **Fix:**
  - Add a Redis accessory and a `job` role running `bundle exec sidekiq`.
  - Pass `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `REDIS_URL` and `LEDGER_PAY_SERVER_DATABASE_PASSWORD` as secrets.
  - Remove or document the unused Solid Queue setup.

## Medium

| # | Where | What happens | Fix |
|---|---|---|---|
| M1 | `app/services/reconciliation/recover_stuck_items_job.rb` | Re-enqueues every `pending` item idle for more than 15 min, including items waiting in Sidekiq's retry backoff. That creates duplicate jobs, inflated `attempts` and extra Stripe calls. | Recover only stale `processing` items, or store `enqueued_at` and use a threshold longer than the max retry delay. |
| M2 | `config/initializers/sidekiq_cron.rb` + `run.rb` | Every run re-checks all records from the last 24h, so each payment is fetched from Stripe about 360 times a day, risking rate limits. | Reconcile records that are non-terminal or haven't been reconciled since their last change (a watermark). |
| M3 | `app/services/reconciliation/record_result.rb` | Both `RecordResult` and `CompleteRunItem` change run counters and status. On a retry, `RecordResult` returns the old result row, so the per-run snapshot keeps the stale outcome. | `RecordResult` only upserts the snapshot row (and updates it on retry). Counters and status live only in `CompleteRunItem`. |
| M4 | `run.rb` `candidate_records` | `.to_a` loads every candidate record into memory. | Use `find_each`. |
| M5 | `admin/reconciliation_records_controller.rb#index` | The list is unbounded. | Add `.limit(100)` or pagination, as `reconciliation_runs#index` does. |
| M6 | `auth/registrations_controller.rb`, `kyc_controller.rb` | The user and the KYC profile are created outside one transaction, and `KycController` raises `NoMethodError` (500) when the profile is missing. | Wrap the two creates in a transaction; return 404 when there's no profile. |
| M7 | whole app, `db/seeds.rb` | Nothing creates wallets, wallet accounts, currencies or the `STRIPE_CLEARING_*`/`WITHDRAWAL_CLEARING_*` accounts, so a fresh install can't take a payment (`Deposit` raises `RecordNotFound`). | Seed currencies and clearing accounts idempotently. Create a wallet and a liability account on registration, or add an endpoint for it. |
| M8 | `application_controller.rb#current_user` | `@current_user if defined?(@current_user)` doesn't `return`, so the token is looked up again every time it's called. | `return @current_user if defined?(@current_user)`. |
| M9 | `application_controller.rb` | Users that aren't `active` can still use existing tokens. (Login now checks status, see H5.) | Check `user.status == "active"` in `current_user`. |
| M10 | auth endpoints | No rate limiting on login or registration. | Rails 8: `rate_limit to: 10, within: 1.minute, only: :create`. |
| M11 | `ledger/transfer.rb` | Only account status is checked, so a frozen wallet with an active account can still send or receive. | Check that both `wallet.status == "active"`. |
| M12 | controllers, `params[:amount].to_i` | `"10.99"`→10, `"1e3"`→1, `"abc"`→0. The amount silently changes. | `Integer(params[:amount], exception: false)` and reject anything that isn't an integer. |
| M13 | `payments/create_payment.rb` | No Stripe idempotency key, so a double submit creates two PaymentIntents. | `idempotency_key: "payment-#{payment.id}"`, plus the C5 error handling. |
| M14 | withdrawals and refunds `create` | No `Idempotency-Key` support, so a double submit creates two withdrawals or refunds (both within the limits). | Add the `IdempotencyKey` pattern (after the C2 fix). |
| M15 | `ledger/withdraw.rb` | Requires an active wallet at settlement. If the wallet is frozen while a payout is in flight, the `payout.paid` webhook fails forever. | Don't check wallet status when settling money that has already moved. |
| M16 | `app/models/account.rb#balance` | Loads every entry into Ruby while holding row locks, which gets slower as the ledger grows. | Sum in SQL: `ledger_entries.group(:entry_type).sum(:amount)`. |
| M17 | `app/models/wallet.rb#available_balance` | Raises `NoMethodError` when the wallet has no account. | Raise a clear `ArgumentError`, or make sure every wallet has an account. |
| M18 | `db/schema.rb` `kyc_profiles` | The `user_id` index isn't unique, although the model is `has_one`. | Migration to make the index unique. |

## Low / cleanup
- **L1.** `app/services/payments/process_stripe_refund_webhook.rb` isn't used and has the same arity bug as H1. Delete it.
- **L2.** `Reconciliation::RecoverStuckItemsJob` lives in `app/services/`. Move it to `app/jobs/reconciliation/`.
- **L3.** Commented-out legacy code in the reconciliation jobs, `create_record.rb` and `payment_job.rb`. Remove it.
- **L4.** `User has_many :idempotency_key` should be plural (`:idempotency_keys`).
- **L5.** `Transaction` status `reversed` is never set. Either set it on the original when posting a reversal, or remove it.
- **L6.** `WITHDRAWAL_CLEARING_*` is an asset account that goes negative on every payout. Consider making it a liability or a payable account so balances read naturally.
- **L7.** `Deposit` upcases the currency code but other ledger services don't. This is harmless because `Currency#normalize_code` already upcases, but drop the redundant `.upcase` for consistency.

## Checked and found correct
- Partial and multiple refunds: `CreateRefund` locks the payment and caps the total at the payment amount minus pending and succeeded refunds.
- Webhook dedup: `WebhookEvent` is unique on `(provider, event_id)` and locked; already-processed events return early.
- Status guards in payment, refund and withdrawal handlers block regressions from terminal states. A late `payout.failed` after `paid` posts a single reversal (`WITHDRAWAL-REVERSAL-<id>`), and the reversal itself is idempotent.
- `PostTransaction` validation (balanced, positive integers, active accounts, single currency) and `Transfer`'s deadlock-safe lock order.
- Webhook signature verification returns 400 on a bad signature or bad payload.
- Every customer endpoint scopes lookups to `current_user` (the transfer destination wallet is unscoped on purpose). Admin endpoints use `require_admin!`.

## Suggested fix order
1. H13, H14 (make tests and CI run)
2. C1, C2, C3, C4 (ledger integrity)
3. C5, C6, H1–H4 (Stripe flows)
4. H5–H7 (API bugs)
5. H8–H11 (reconciliation)
6. H12 (immutability)
7. H15 (deploy)
8. Medium items, then Low

Each fix is a separate change with a failing test first; this is the testing plan from your earlier message.
