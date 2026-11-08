## Rules — Must-have

### Workflow

- Read the related model, controller, service, and tests before changing code.
- For anything beyond a small fix, propose a short plan and wait for approval.
- Make the smallest change that solves the task; don't refactor unrelated code.
- Every behavior change needs tests; for bugs, write a failing test first.
- Done = relevant tests pass (`bin/rails test <files>`) + `bin/rubocop -a` clean. Report what you ran.
- Don't add, remove, or upgrade gems without asking.
- Never commit, push, or run destructive commands (`db:drop`, `db:reset`, `db:seed:replant` outside test, `git reset --hard`) unless asked.

### Money & ledger (highest priority)

- Amounts are integers in minor units (cents) everywhere: columns, params (`params[:amount].to_i`), Stripe calls. Never use floats or decimals for money.
- Ledger entries are written **only** through `Ledger::PostTransaction`. Never create, update, or delete `LedgerEntry` / `Transaction` rows directly.
- Posted ledger rows are immutable. Fix mistakes with a new compensating transaction (see `Ledger::ReverseWithdrawal`), never by editing or deleting entries.
- Balances are derived from entries (`Account#balance`, `Wallet#available_balance`); don't add a stored balance column without approval.
- Every `Transaction` needs a unique, deterministic `reference` when it's tied to an external object (e.g. `"PAYMENT-#{payment.id}"`) so retries can't double-post.
- System accounts are looked up by code (`STRIPE_CLEARING_<CUR>`, `WITHDRAWAL_CLEARING_<CUR>`). Keep the currency-code casing consistent with existing data.
- When locking several accounts, lock in ascending id order (see `Ledger::Transfer#lock_accounts!`) to avoid deadlocks.
- State transitions on money records (`Payment`, `Refund`, `Withdrawal`, `WebhookEvent`, `ReconciliationRunItem`): open a transaction, re-load with a lock (`Model.lock.find` / `with_lock`), re-check the status guard, then update. Terminal statuses are never overwritten.
- Record significant money and admin actions with `AuditLogs::Record.call(action:, auditable:, user:, metadata:)`, using `"<resource>.<event>"` action names.
- Money-moving endpoints must be idempotent. Follow `Ledger::IdempotentTransfer` / `IdempotencyKey` (unique per user + key, with a request-hash check).

### Stripe

- Create the local record (`pending`) first, then call Stripe with the local id in `metadata` (`payment_id`, `refund_id`, `withdrawal_id`), then store the provider id.
- The ledger is only posted from verified webhook events, never from the API request that created the payment, refund, or payout.
- Webhooks: verify the signature (`Stripe::Webhook.construct_event`), persist to `WebhookEvent` (deduped on `event_id`), and in each handler validate provider, provider id, amount, and currency against the local record before acting. Handlers must be safe to receive twice and out of order.
- New event types are added to the `case` in `Payments::ProcessStripeWebhook`.

### API design

- All endpoints live under `Api::V1` (`app/controllers/api/v1/`) and inherit from `ApplicationController` (`ActionController::API`); never break an existing endpoint's contract.
- RESTful routes where possible; use nested or member routes before inventing custom actions (existing custom routes like `.../resolve` and `.../retry` stay as they are).
- No serializer gem is used. Build responses with explicit, allowlisted hashes in a private `*_json` / `serialize_*` controller method. Never `render json: model` or `to_json` a model.
- Never expose internal fields (password digests, token digests, raw webhook payloads) in responses.
- Status codes: 200, 201 (create), 202 (enqueued), 401, 403, 404, 422 (validation / `ArgumentError`).
- Error shape is `{ "error": "<message>" }`. Services raise `ArgumentError` for business-rule failures, and controllers rescue it and return 422. Don't introduce a different error shape on existing endpoints without asking.
- Index endpoints must be bounded (`limit` or pagination); never return unbounded lists. Ask before adding a pagination gem.
- Changing response fields or behavior of an existing endpoint = breaking change; ask first.

### Authentication

- Every endpoint requires `before_action :authenticate_user!` unless it is explicitly public. The only public endpoints are `auth/register`, `auth/login`, `webhooks/stripe` (which is authenticated by Stripe signature instead), and `/up`.
- Admin endpoints live under `Api::V1::Admin` and also use `before_action :require_admin!`.
- Login uses `has_secure_password`; verify with `User#authenticate`, never compare passwords manually.
- Requests use opaque bearer tokens (`Authorization: Bearer <token>`), NOT JWT. Don't introduce JWT.
- Tokens live in `AuthToken` (`token_digest`, `expires_at`, `user_id`). Only the SHA-256 digest is stored. Generate the raw token with `SecureRandom` and return it to the client once; never store, log, or return it again.
- Look up tokens only by digest (`Digest::SHA256.hexdigest(token)`). Expired tokens are invalid; never extend expiry silently.
- Changes to the auth flow (token format, expiry length, lookup logic, roles) require approval first.

### Security

- Scope lookups to the caller: `current_user.wallets.find(params[:id])`, never `Wallet.find(params[:id])`. Unscoped lookups must be deliberate and commented (e.g. the destination wallet in a transfer).
- Always use strong params; never `permit!`.
- Never interpolate user input into SQL; use hash conditions or bound params.
- Never log tokens, passwords, card data, or PII. Keep `config/initializers/filter_parameter_logging.rb` up to date.
- Never read, print, or edit `.env*`, `config/master.key`, or `config/credentials/*.key`. Secrets come from `ENV` (see CLAUDE.md for the variable names).

### Database & migrations

- Never hand-edit `db/schema.rb`; always generate a migration.
- Never modify a committed migration; add a new one.
- Migrations must be reversible.
- Back validations with DB constraints: `null: false`, foreign keys, unique indexes. Idempotency relies on unique indexes raising `ActiveRecord::RecordNotUnique` (`IdempotencyKey`, `WebhookEvent.event_id`, `Transaction.reference`).
- Index every foreign key and every column used in `where` / `order`.
- Enums are string-backed (`enum :status, { pending: "pending", ... }`); keep new enums the same way, and use the same spelling as existing ones (`canceled`, not `cancelled`).
- Avoid N+1: use `includes` / `preload` for associations used in responses.

### Sidekiq jobs

- Jobs live in `app/jobs/<domain>/` and `include Sidekiq::Job`. Don't use ActiveJob (`ApplicationJob`) for new jobs.
- Jobs must be idempotent: safe to run twice or retry mid-way. For per-item work, claim the row under a lock first (see `Reconciliation::PaymentJob`).
- Pass only simple JSON-safe args (IDs, strings, numbers), never AR objects or symbols.
- Keep `perform` thin: call a service object that holds the logic and is tested on its own.
- Set explicit `sidekiq_options` (`queue`, `retry`) and handle `sidekiq_retries_exhausted` when the job tracks state in the DB.
- Let transient errors (Stripe/network) raise so Sidekiq retries; rescue only permanent errors.
- Use `perform_async` / `perform_in` from request code; never run jobs inline unless asked.
- Enqueue jobs after the DB transaction commits, not inside it.

### Cron / scheduled jobs

- All schedules are defined in `config/initializers/sidekiq_cron.rb` (`Sidekiq::Cron::Job.load_from_hash`); never schedule jobs anywhere else.
- Cron times are UTC; add a plain-words comment next to each new cron expression.
- Cron jobs must be safe if they run late, twice, or overlap. Make the work idempotent and use per-record jobs that claim rows under locks.
- Cron jobs that process many records should enqueue per-record jobs (the `Reconciliation::Run` fan-out pattern), not do everything in one long job.
- Use `find_each` / `in_batches` for record iteration; never load whole tables.
- Never change or remove an existing schedule without asking.

### Testing

- Tests are Minitest (`test/`) with YAML fixtures (`test/fixtures/`), not RSpec/FactoryBot. They run serially by default (`PARALLEL_WORKERS` opts in); don't depend on global state.
- One exception: **RSpec is used only for the rswag API-doc specs** in `spec/requests/`, which generate `swagger/v1/swagger.yaml`. Don't write any other RSpec tests.
- Every new or changed endpoint needs its doc spec updated (schemas mirror the controller's `*_json` method, `additionalProperties: false`), then regenerate and commit the YAML: `RAILS_ENV=test RSWAG_DRY_RUN=0 bin/rails rswag:specs:swaggerize`. CI fails if the committed YAML is stale.
- Integration tests (`ActionDispatch::IntegrationTest`) for every endpoint: happy path, 401, 403, 404, 422, and response shape.
- Service tests cover ledger balance effects: assert entries balance and account balances change by the expected amount.
- Job tests call `perform` directly; test the service logic separately. Use `Sidekiq::Testing.fake!` to assert enqueueing; don't run real Sidekiq in tests.
- Tests never hit Stripe or the network. Minitest 6 has no `stub`: use `with_class_method` from `test/test_helper.rb` (in doc specs, rspec-mocks' `allow(...).to receive`), and build Stripe objects and webhook events with `Stripe::*.construct_from`.
- Add a test that every class referenced in `config/initializers/sidekiq_cron.rb` exists.

## Rules — Nice-to-have

- Model layout order: constants, associations, enums, validations, scopes, callbacks, public methods, private methods.
- No callbacks that call external services or enqueue work; do that in services.
- Use `pluck` / `select` when only a few columns are needed.
- Return timestamps as ISO 8601 UTC.
- Log job start, key counts, and completion with job name and record IDs.

### Communication

- When requirements are unclear, ask instead of guessing.
- After finishing, summarize files changed, why, commands run, and any follow-ups.
- Flag risks or tech debt you notice, but don't fix them unless asked.
