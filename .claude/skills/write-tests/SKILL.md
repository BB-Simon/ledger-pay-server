---
name: write-tests
description: Write Minitest tests for this app (models, services, ledger, controllers/integration, Sidekiq jobs, Stripe webhooks) using fixtures and stubbed Stripe. Use when adding tests, fixing failing tests, or increasing coverage.
---

# Write tests (Minitest + fixtures)

This app uses **Minitest + YAML fixtures** (`test/test_helper.rb`: `fixtures :all`, parallel **threads**). There is no RSpec, FactoryBot or WebMock; don't add them without asking.

## 0. Check the fixtures first
`fixtures :all` loads every file in `test/fixtures/`. Several are still Rails scaffold placeholders (`MyString`, `users.yml` with `{}`, `accounts.yml` with a non-existent `string` column, `wallets.yml` missing `currency`). Any broken fixture breaks **every** test. Run `bin/rails test` once. If fixtures fail to load, fix them before writing tests, using `db/schema.rb` for the real columns, `null: false` constraints and check constraints (e.g. `users.role`).

Suggested baseline fixtures (keep the names stable, since other tests depend on them):
```yaml
# currencies.yml
usd: { code: USD, name: US Dollar, decimal_places: 2 }

# users.yml
alice: { email: alice@example.com, password_digest: <%= BCrypt::Password.create("password", cost: 4) %>, role: customer, status: active }
bob:   { email: bob@example.com,   password_digest: <%= BCrypt::Password.create("password", cost: 4) %>, role: customer, status: active }
admin: { email: admin@example.com, password_digest: <%= BCrypt::Password.create("password", cost: 4) %>, role: admin,    status: active }

# wallets.yml
alice_usd: { user: alice, currency: usd, status: active }
bob_usd:   { user: bob,   currency: usd, status: active }

# accounts.yml  (wallet accounts are liabilities; clearing accounts are assets)
alice_usd: { wallet: alice_usd, currency: usd, account_type: liability, code: WALLET_ALICE_USD, name: Alice USD, status: active }
bob_usd:   { wallet: bob_usd,   currency: usd, account_type: liability, code: WALLET_BOB_USD,   name: Bob USD,   status: active }
stripe_clearing_usd:     { currency: usd, account_type: asset, code: STRIPE_CLEARING_USD,     name: Stripe clearing USD,     status: active }
withdrawal_clearing_usd: { currency: usd, account_type: asset, code: WITHDRAWAL_CLEARING_USD, name: Withdrawal clearing USD, status: active }
```
Delete or replace placeholder fixtures for other tables (`ledger_entries.yml`, `transactions.yml`, etc.) with valid rows, or empty them. Prefer giving accounts a balance in a test via `Ledger::Deposit` / `PostTransaction` over hand-writing ledger fixtures, so balances always add up.

## 1. Shared helpers (add to `test/test_helper.rb` once)
```ruby
require "minitest/mock"
require "sidekiq/testing"
Sidekiq::Testing.fake!

module AuthHelpers
  def auth_headers(user, expires_at: 1.day.from_now)
    raw = SecureRandom.hex(32)
    AuthToken.create!(user: user, token_digest: Digest::SHA256.hexdigest(raw), expires_at: expires_at)
    { "Authorization" => "Bearer #{raw}" }
  end
end

module LedgerHelpers
  def fund!(wallet, amount)
    Ledger::Deposit.call(wallet: wallet, amount: amount, reference: "TEST-FUND-#{SecureRandom.hex(4)}")
  end
end

class ActionDispatch::IntegrationTest
  include AuthHelpers
end

class ActiveSupport::TestCase
  include LedgerHelpers
  setup { Sidekiq::Worker.clear_all }
end
```

## 2. What to test by layer
| Layer | Location | Must assert |
|---|---|---|
| Model | `test/models/` | validations, enums (string values), custom methods such as `Account#balance` sign rules and `Wallet#available_balance` |
| Ledger service | `test/services/ledger/` | exact balance changes, debits == credits, no rows on `ArgumentError`, duplicate reference rejected |
| Other services | `test/services/<domain>/` | state transitions, status guards (terminal states unchanged), audit log created |
| Endpoint | `test/controllers/api/v1/...` (`ActionDispatch::IntegrationTest`) | happy path + response keys, 401 (none/expired token), 403 (non-admin), 404 (other user's record), 422 `{ "error" => ... }` |
| Job | `test/jobs/<domain>/` | call `Job.new.perform(id)` directly; terminal items are skipped; enqueueing via `Job.jobs.size` |
| Cron | `test/initializers/sidekiq_cron_test.rb` | every `"class"` in `config/initializers/sidekiq_cron.rb` constantizes |

## 3. Stripe: never hit the network
```ruby
fake_intent = Stripe::PaymentIntent.construct_from(id: "pi_123", amount: 1000, currency: "usd", status: "succeeded", client_secret: "cs_x")
Stripe::PaymentIntent.stub(:create, fake_intent) do
  result = Payments::CreatePayment.call(user: users(:alice), wallet: wallets(:alice_usd), amount: 1000)
  assert_equal "pi_123", result[:payment].provider_payment_id
end
```
- Use `Stripe::<Resource>.construct_from(...)` for objects and `Stripe::Event.construct_from(...)` for webhook events (see the `stripe-webhook-event` skill).
- Stub the class method that is actually called (`:create`, `:retrieve`). An unstubbed call will fail. That's intended, and you should never use real keys in tests.
- Stripe raising errors: `Stripe::PaymentIntent.stub(:retrieve, ->(*) { raise Stripe::APIConnectionError, "down" }) { ... }`.

## 4. Conventions
- Use the `test "does X when Y" do` style, with one behavior per test.
- Use `assert_difference` / `assert_no_difference` for row counts and balances (`-> { account.reload.balance }`).
- Tests run in parallel threads, so don't mutate constants, ENV or class-level state without restoring it, and don't rely on row order without an explicit `order`.
- For a bug fix, write the failing test first, show it failing, then fix.

## 5. Run
```sh
bin/rails test test/services/ledger/transfer_test.rb      # one file
bin/rails test test/services/ledger/transfer_test.rb:24   # one test
bin/rails test                                            # all
```
Needs Postgres with `DATABASE_PASSWORD` set and `STRIPE_SECRET_KEY` present (any value works, because the initializer `ENV.fetch`es it at boot). Finish with the `verify` skill.
