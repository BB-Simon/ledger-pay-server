# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Rails 8.1 **API-only** app (Ruby 4.0.6, PostgreSQL) for a wallet/payments service. It has a double-entry ledger, Stripe payments, refunds and payouts (withdrawals), and scheduled reconciliation against Stripe. Development happens on Windows (`bin/*` shebangs use `ruby.exe`).

## Commands

```sh
bin/setup                                   # install gems, prepare DB
bin/dev                                     # = bin/rails server
bundle exec sidekiq                         # background worker + cron (needs Redis)
bin/rails test                              # full test suite (Minitest, parallel, fixtures :all)
bin/rails test test/models/payment_test.rb  # single file
bin/rails test test/models/payment_test.rb:12   # single test by line
bin/rubocop                                 # lint (rubocop-rails-omakase)
bin/brakeman --no-pager                     # security scan
bin/bundler-audit                           # gem CVE audit
bin/ci                                      # runs the full local CI pipeline in config/ci.rb
```

Required env vars (loaded from `.env` via dotenv-rails in dev/test): `DATABASE_PASSWORD` (also `DATABASE_USERNAME/HOST/PORT`, defaulting to postgres@127.0.0.1:5432), `STRIPE_SECRET_KEY` (read with `ENV.fetch` at boot in `config/initializers/stripe.rb`, so the app won't boot without it), `STRIPE_WEBHOOK_SECRET`, and `REDIS_URL`.

## Architecture

### Layering

Controllers (`app/controllers/api/v1/**`) stay thin. They parse params and call service objects in `app/services/<domain>/`. Every service uses the same shape: `self.call(**kwargs)` → `new(...).call`. **Validation failures raise `ArgumentError`**, and controllers `rescue ArgumentError` and return 422. Keep this convention when adding services.

Auth is a hand-rolled bearer token. `ApplicationController#current_user` SHA256-hashes the `Authorization: Bearer` token and looks up `AuthToken.token_digest`. Use `before_action :authenticate_user!` and `require_admin!` (`User#role` enum). Admin endpoints are under `Api::V1::Admin`.

### Double-entry ledger (`app/services/ledger/`)

- `Wallet` (user-facing) has one `Account`. `Account` has many `LedgerEntry`, and those entries are grouped under a `Transaction` via FK `ledger_transaction_id`. Don't confuse the `Transaction` model with `ActiveRecord` `.transaction` blocks.
- `Ledger::PostTransaction` is the **only** place that writes ledger entries. It enforces at least 2 entries, positive integer amounts, active accounts, a single currency, and debits == credits. All other ledger services (`Deposit`, `Transfer`, `Withdraw`, `Refund`, `ReverseWithdrawal`) build entry lists and delegate to it.
- Amounts are **integers in minor units** (cents). Balances are derived, not stored: `Account#balance` sums entries according to account type (asset/expense increase with debits). `Wallet#available_balance` subtracts pending withdrawals.
- External money flows go through system clearing accounts that are looked up by code: `STRIPE_CLEARING_<CUR>` and `WITHDRAWAL_CLEARING_<CUR>`. These must exist in the DB because `db/seeds.rb` doesn't create them. `Deposit` upcases the currency code but the other services don't, so watch for case mismatches.
- `Transfer` takes row locks on both accounts in id order to avoid deadlocks. `IdempotentTransfer` wraps it using `IdempotencyKey` (unique per user + key, with a request-hash check) from the `Idempotency-Key` header.
- Significant state changes call `AuditLogs::Record.call(action:, auditable:, user:, metadata:)`.

### Stripe flow

- Create: `Payments::CreatePayment`, `Payments::CreateRefund`, and `Withdrawals::CreateWithdrawal` → `CreateProviderWithdrawal` create a local `pending` record first, then call Stripe with the local id in Stripe `metadata` (`payment_id` / `refund_id` / `withdrawal_id`).
- Settle: `POST /api/v1/webhooks/stripe` → `Payments::ProcessStripeWebhook`. It stores each event in `WebhookEvent` (unique on event_id, so redelivered events are deduped), locks it, and dispatches on `event.type`. Handlers look up the local record from metadata, re-lock it, check that provider id/amount/currency match, update status, and **only then post to the ledger**: deposits on `payment_intent.succeeded`, refunds on refund success, and withdrawals on `payout.paid`. `ReverseWithdrawal` runs on a late `payout.failed`. Handlers are idempotent through status guards.
- `Payments::ProcessStripeRefundWebhook` is currently unused. Refund events are handled in `ProcessStripeWebhook`.

### Reconciliation (`app/services/reconciliation/`, `app/jobs/reconciliation/`)

- Background jobs use **Sidekiq** (`include Sidekiq::Job`, `perform_async`), not ActiveJob. Cron schedules are in `config/initializers/sidekiq_cron.rb`: payments every 4 min, refunds every 7, payouts every 10, and stuck-item recovery every 30.
- Fan-out: `Reconciliation::PaymentsJob` / `RefundsJob` / `PayoutsJob` → `Reconciliation::Run` creates a `ReconciliationRun` plus one `ReconciliationRunItem` for each record from the last 24h that has a provider id, then enqueues a per-item job (`PaymentJob` / `RefundJob` / `PayoutJob`).
- Per-item jobs claim the item under a lock (`pending` → `processing`, which is skipped if another worker claimed it within the last 15 min). They fetch the Stripe object, call `ReconcilePayment` / `ReconcileRefund` / `ReconcilePayout` (which create a `ReconciliationRecord` that is matched or a discrepancy with a `discrepancy_type`), then `RecordResult` and `CompleteRunItem`. When retries are exhausted, the item is marked `failed`.
- `CompleteRunItem` is the only thing that moves an item to a terminal status. It recomputes run counters and the run status under a run lock, and never overwrites a terminal item.
- `Reconciliation::RecoverStuckItemsJob` lives in `app/services/reconciliation/` even though it is a job. It resets stale `processing` items and re-enqueues stale `pending` ones.
- Admins can resolve discrepancies (`ResolveRecord`) and retry run items (`RetryRunItem`) through the admin endpoints.

## Notes

- Test coverage is mostly empty model-test stubs plus one empty admin controller test, so most behavior is untested.
- GitHub CI (`.github/workflows/ci.yml`) runs brakeman, bundler-audit, rubocop, and `bin/rails db:test:prepare test`. It triggers on PRs and on pushes to `master`, while the default branch is `main`.
- Known bugs (not fixed yet; don't copy these patterns):
  - `Auth::SessionsController#create` renders 401 on bad credentials but doesn't `return`, so execution continues.
  - In `Payments::ProcessStripeWebhook`: `process_refund_failed!` is called with an argument it doesn't accept; payout cancel sets `:cancelled` but the enum is `canceled`; and withdrawal audit logs pass `@user`, which is never set.

Project rules (workflow, money/ledger invariants, API, auth, jobs, testing) are in AGENTS.md:

@AGENTS.md
