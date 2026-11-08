# Testing guide: how this app's tests work and why

This guide is for someone new to Rails testing. It explains the test tools this
project uses, then walks through the test setup and every test written while
fixing bugs C1–C6 (see `docs/BUGS.md`). It covers what each test does and why
it's written that way.

Contents:

1. [The big picture](#1-the-big-picture)
2. [Running tests](#2-running-tests)
3. [Anatomy of a test file](#3-anatomy-of-a-test-file)
4. [Assertions cheat sheet](#4-assertions-cheat-sheet)
5. [`test_helper.rb`, line by line](#5-test_helperrb-line-by-line)
6. [Fixtures](#6-fixtures)
7. [Transactional tests: why every test starts clean](#7-transactional-tests-why-every-test-starts-clean)
8. [Faking Stripe: `with_class_method`](#8-faking-stripe-with_class_method)
9. [Testing Sidekiq jobs](#9-testing-sidekiq-jobs)
10. [Concurrency tests (race conditions)](#10-concurrency-tests-race-conditions)
11. [Integration (controller) tests](#11-integration-controller-tests)
12. [Walkthrough of every test file](#12-walkthrough-of-every-test-file)
13. [The workflow: failing test first](#13-the-workflow-failing-test-first)
14. [Common mistakes](#14-common-mistakes)
15. [Writing your next test](#15-writing-your-next-test)

---

## 1. The big picture

### Tools

| Tool | What it does here |
|---|---|
| **Minitest** | The test framework built into Rails. A test is a Ruby class with methods; assertions check results. (RSpec is the popular alternative; this project doesn't use it.) |
| **Fixtures** | YAML files in `test/fixtures/` that describe rows loaded into the test database before tests run. |
| **Test database** | A separate PostgreSQL database (`ledger_pay_server_test`), so tests never touch your development data. |
| **`Sidekiq::Testing`** | Makes `perform_async` store jobs in an in-memory array instead of sending them to Redis. |
| **`with_class_method`** | Our own small helper (in `test_helper.rb`) for temporarily replacing a method, mainly used to fake Stripe. |

### Kinds of tests

```
test/
├── test_helper.rb                 # shared setup, loaded by every test file
├── fixtures/*.yml                 # baseline data
├── models/                        # model tests (mostly empty stubs today)
├── services/                      # service tests  ← most of our tests
│   ├── ledger/
│   ├── payments/
│   └── withdrawals/
└── controllers/api/v1/            # integration tests: real HTTP requests
```

- **Service tests** (`ActiveSupport::TestCase`) call a service directly, e.g.
  `Ledger::Transfer.call(...)`, and check the database afterwards. Most of the
  business logic lives in services, so most tests are here.
- **Integration tests** (`ActionDispatch::IntegrationTest`) send a real HTTP
  request through routing, the controller, and the service, then check the
  status code and JSON. They test the API contract.
- **Job tests** call a Sidekiq job's `perform` method directly. Ours live in the
  service test files because they test one flow end to end.

### The golden rule for this app

In a money app, the most important thing to check is **the ledger balance**.
Almost every test ends with something like:

```ruby
assert_equal 700, accounts(:alice_usd).reload.balance
```

If a bug moves money twice, loses money, or posts money it shouldn't, this line
catches it.

---

## 2. Running tests

The test database must exist and have every migration applied. Run this once,
and again after adding migrations:

```sh
bin/rails db:test:prepare
```

Then:

```sh
bin/rails test                                               # everything
bin/rails test test/services/ledger/transfer_test.rb         # one file
bin/rails test test/services/ledger/transfer_test.rb:355     # the test on/around line 355
bin/rails test test/services -n /pending/                    # tests whose name matches /pending/
bin/rails test -v                                            # print each test name and time
bin/rails test --seed 12345                                  # reproduce a specific random order
```

How to read the result:

```
38 runs, 118 assertions, 0 failures, 0 errors, 0 skips
```

- **runs**: number of tests.
- **assertions**: number of checks made.
- **failure**: an assertion was false (the code gave the wrong answer).
- **error**: an exception nobody expected was raised (the code crashed).

Minitest runs tests **in random order** on purpose. If a test only passes when
another test runs before it, the tests depend on each other, and random order
exposes that. When a failure seems random, rerun with the `--seed` shown in
the output to get the same order.

You also need PostgreSQL running and the env vars from `CLAUDE.md`
(`DATABASE_PASSWORD`, `STRIPE_SECRET_KEY`, …). The app won't boot without
`STRIPE_SECRET_KEY`, even in tests. Tests never call Stripe, so any value works.

---

## 3. Anatomy of a test file

Here is a small, complete example, simplified from `transfer_test.rb`:

```ruby
require "test_helper"                          # 1. load Rails + shared setup

class Ledger::TransferTest < ActiveSupport::TestCase   # 2. a test class
  setup do                                      # 3. runs before EACH test
    Ledger::Deposit.call(wallet: wallets(:alice_usd), amount: 1_000, reference: "TEST-FUND-ALICE")
  end

  def transfer(amount)                          # 4. a plain helper method
    Ledger::Transfer.call(
      from_wallet: Wallet.find(wallets(:alice_usd).id),
      to_wallet: Wallet.find(wallets(:bob_usd).id),
      amount: amount,
      reference: SecureRandom.uuid
    )
  end

  test "moves the amount from sender to recipient" do   # 5. one test
    transfer(300)                                        #    act

    assert_equal 700, accounts(:alice_usd).reload.balance   # assert
    assert_equal 300, accounts(:bob_usd).reload.balance
  end
end
```

1. **`require "test_helper"`** boots Rails in the `test` environment and loads
   our shared setup. Every test file starts with this line.
2. **The class name** follows the class under test plus `Test`. The parent class
   decides the test type: `ActiveSupport::TestCase` for services and models,
   `ActionDispatch::IntegrationTest` for HTTP endpoints.
3. **`setup`** runs before *each* test, not once per file. Each test gets fresh
   data: here, Alice always starts with 1,000 cents. There is also `teardown`,
   which runs after each test.
4. **Helper methods** are ordinary Ruby methods. They keep tests short and
   readable.
5. **`test "..." do`** defines one test. The string should say what *should*
   happen, so a failure reads like a sentence:
   `"cannot spend money held by a pending withdrawal"`.

Most tests follow the **Arrange → Act → Assert** pattern:

- **Arrange**: set up the situation (deposit money, create a pending withdrawal).
- **Act**: do the one thing being tested (attempt a transfer).
- **Assert**: check the result (balance unchanged, error raised).

---

## 4. Assertions cheat sheet

These are the assertions used in our tests. The **expected value comes first**,
then the actual value. Getting the order wrong makes failure messages
confusing.

| Assertion | Passes when | Example from our tests |
|---|---|---|
| `assert x` | `x` is truthy | `assert refund.reload.failed?` |
| `assert_equal expected, actual` | `expected == actual` | `assert_equal 700, account.balance` |
| `assert_nil x` | `x` is `nil` | `assert_nil withdrawal.provider_withdrawal_id` |
| `assert_empty x` | `x.empty?` | `assert_empty Payments::SubmitRefundJob.jobs` |
| `assert_match regex, string` | the regex matches | `assert_match(/Insufficient balance/, error.message)` |
| `assert_kind_of Class, x` | `x.is_a?(Class)` | `assert_kind_of ArgumentError, transfer_error` |
| `assert_raises(Error) { ... }` | the block raises that error; **returns the error** so you can inspect it | `error = assert_raises(ArgumentError) { transfer(1_001) }` |
| `assert_difference -> { expr }, n do ... end` | `expr` changed by exactly `n` (default 1) during the block | `assert_difference -> { LedgerEntry.count }, 2 do ... end` |
| `assert_no_difference -> { expr } do ... end` | `expr` didn't change | `assert_no_difference -> { Transaction.count } do ... end` |
| `assert_response :created` | HTTP status matches (integration tests only) | `assert_response :unprocessable_entity` |

You can add a message as the last argument. It's shown when the assertion fails:

```ruby
assert_equal 600, available, "the hold stays because Stripe may have refunded"
```

A handy Rails method used in many asserts is **`.sole`**. It returns the only
record and **raises if there are zero or more than one**. So
`@wallet.withdrawals.sole.failed?` also checks that exactly one withdrawal
was created.

---

## 5. `test_helper.rb`, line by line

```ruby
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
```
These are Rails defaults. They boot the app in test mode, connect to the test
database, and load Minitest with Rails' extras such as fixtures and
`assert_difference`.

```ruby
require "sidekiq/testing"
Sidekiq::Testing.fake!
```
**Why:** our services call `SubmitRefundJob.perform_async(...)`. Without this,
that call would try to push to Redis. In fake mode, jobs go into an in-memory
array, `SubmitRefundJob.jobs`, which tests can inspect. Nothing runs
automatically. See [section 9](#9-testing-sidekiq-jobs).

```ruby
setup { Sidekiq::Job.clear_all }
```
**Why:** the fake job arrays are global and aren't part of the database, so
the transaction rollback doesn't clear them. Without this line, jobs queued by
one test would still be there in the next test, and
`assert_empty ...jobs` would fail at random depending on test order.

```ruby
parallelize(workers: ENV.fetch("PARALLEL_WORKERS", 1).to_i, with: :threads)
```
Rails can run tests in several threads at once. We default to **1 (serial)**
for two reasons:

- `with_class_method` swaps a method **globally**. If one thread replaces
  `Stripe::Refund.create` while another thread runs a different test, the other
  test would see the fake.
- The concurrency tests in [section 10](#10-concurrency-tests-race-conditions)
  commit real data and open extra DB connections. Running them next to other
  tests would make them interfere.

The suite takes about 3 seconds, so serial is fine. You can still try
`PARALLEL_WORKERS=4 bin/rails test`.

```ruby
fixtures :all
```
Load every file in `test/fixtures/` and make `users(:alice)`,
`wallets(:alice_usd)` and so on available. See [section 6](#6-fixtures).

```ruby
def with_class_method(klass, name, replacement)
  ...
end
```
Our method-faking helper. It has its own section,
[section 8](#8-faking-stripe-with_class_method).

---

## 6. Fixtures

### What they are

A fixture file is YAML that describes rows of one table. The file name matches
the table: `users.yml` → `users`. Before tests run, Rails deletes everything in
those tables and inserts the fixture rows.

```yaml
# test/fixtures/users.yml
<% password_digest = BCrypt::Password.create("password", cost: BCrypt::Engine::MIN_COST) %>
alice:
  email: alice@example.com
  password_digest: <%= password_digest %>
  role: customer
  status: active
```

- **`alice:`** is the **label**. In a test, `users(:alice)` returns this row as
  a `User` object.
- **`<% ... %>` and `<%= ... %>`** are ERB, the same template tags as in views.
  Fixture files are run through ERB first, so you can compute values. Here we
  create a real bcrypt hash of `"password"`, so `user.authenticate("password")`
  works. `MIN_COST` makes hashing fast; the normal cost is deliberately slow.
- **No `id:`** is needed. Rails derives a stable id from the label.

### Associations by label

```yaml
# test/fixtures/wallets.yml
alice_usd:
  user: alice        # ← a label, not an id
  currency: usd
  status: active
```

`user: alice` means "this wallet's `user_id` is the id of the `alice` row in
users.yml". Rails works this out from the `belongs_to :user` association, so
you never write ids by hand.

### Our baseline data and why

| File | Rows | Why they exist |
|---|---|---|
| `currencies.yml` | `usd` | Every wallet, account and payment needs a currency. The code is `USD` (upper case) because `Currency#normalize_code` stores codes in upper case. |
| `users.yml` | `alice`, `bob` (customers), `admin` | Two customers make transfers possible (Alice → Bob). The admin is for future admin-endpoint and permission tests. |
| `wallets.yml` | `alice_usd`, `bob_usd` | One wallet per customer. |
| `accounts.yml` | `alice_usd`, `bob_usd` (liability), `stripe_clearing_usd`, `withdrawal_clearing_usd` (asset) | Each wallet needs a ledger account. The two clearing accounts are required because `Ledger::Deposit`, `Withdraw` and `Refund` look them up **by code** (`STRIPE_CLEARING_USD`) and raise if they're missing. |

Why the wallet accounts are **liability** and the clearing accounts are
**asset**: from the platform's point of view, money in a user's wallet is
money the platform *owes* the user (a liability), while money sitting at
Stripe is something the platform *has* (an asset). `Account#balance` uses the
type to decide whether debits or credits increase the balance.

### Why most fixture files are empty

Rails generated placeholder fixtures (`code: MyString` and so on) when the
models were created. Those placeholders **broke every test**:

- two currencies had the same code, which violates a unique index;
- users had no email, which violates `NOT NULL`;
- `accounts.yml` used a column that doesn't exist;
- and so on (bug H13).

Because `fixtures :all` loads every file, one bad file stops the whole suite.
We replaced the needed ones with valid rows and emptied the rest, leaving a
comment like this:

```yaml
# Intentionally empty. Tests create these rows through services so ledger
# balances and states stay consistent. Add rows here only if they are valid.
```

### Why money isn't in fixtures

You might wonder why there isn't a `ledger_entries.yml` with Alice's 1,000
cents. Instead, tests do this:

```ruby
Ledger::Deposit.call(wallet: wallets(:alice_usd), amount: 1_000, reference: "TEST-FUND-ALICE")
```

**Why:** the ledger has rules: every transaction balances, entries only go
through `Ledger::PostTransaction`, and amounts are positive. Hand-written
entries in YAML skip all of those rules, and it's easy to write one-sided
entries that no real code path could produce. Going through the real service
guarantees the starting state is one the app could actually be in. The same
applies to payments, refunds and withdrawals: tests create them with
`Payment.create!(...)` and so on, showing exactly the state each test needs.

---

## 7. Transactional tests: why every test starts clean

By default, Rails wraps **every test in a database transaction and rolls it
back** at the end:

```
BEGIN
  setup        → deposit 1,000 to Alice
  test body    → transfer 300 to Bob
  assertions
ROLLBACK       → the deposit and the transfer disappear
```

So each test starts from the fixtures only, no matter what earlier tests did.
That's why every test can deposit `"TEST-FUND-ALICE"` with the same reference,
even though `Transaction.reference` is unique: the previous test's row was
rolled back.

This is also very fast, because nothing is ever committed.

**The catch:** data inside an uncommitted transaction is only visible to
*that one database connection*. Concurrency tests need several connections to
see the same data, so they turn this off. See
[section 10](#10-concurrency-tests-race-conditions).

---

## 8. Faking Stripe: `with_class_method`

### Why fake at all

Tests must never call the real Stripe API:

- it's slow and needs the network;
- it could create real refunds or payouts;
- we can't make real Stripe time out or reject on demand.

We need to make `Stripe::Refund.create` return what *we* want: a success, a
rejection, or a timeout.

### Why not `stub` from Minitest

Older guides, and `AGENTS.md`, show `Stripe::Refund.stub(:create, fake) { ... }`.
That comes from `minitest/mock`. This project uses **Minitest 6**, which moved
mocks and stubs into a separate gem (`minitest-mock`) that isn't installed.
Instead of adding a gem, we wrote a seven-line helper.

### How it works

```ruby
def with_class_method(klass, name, replacement)
  original = klass.method(name)                    # 1. save the real method
  klass.define_singleton_method(name) do |*args, **kwargs|
    replacement.call(original, *args, **kwargs)    # 2. route calls to our lambda
  end
  yield                                            # 3. run the test code
ensure
  klass.define_singleton_method(name, original)    # 4. ALWAYS put it back
end
```

1. `klass.method(:create)` returns a `Method` object, a handle to the real
   method that we can call later.
2. `define_singleton_method` replaces the class method. Every call now goes to
   our `replacement` lambda, which **receives the original method as its first
   argument**, followed by the real arguments.
3. `yield` runs the block the test passed in.
4. `ensure` runs even if the test fails or raises, so the real method is
   always restored. Without it, one failing test would leave Stripe faked for
   every later test.

Passing `original` to the lambda lets one helper cover three uses:

```ruby
# a) Replace completely: return a fake Stripe object
fake = ->(_original, params, opts = {}) { Stripe::Refund.construct_from(id: "re_123") }

# b) Simulate an error
timeout = ->(_original, *) { raise Stripe::APIConnectionError, "read timeout" }

# c) Wrap the real method: do something extra, then call the real one
slow = ->(original, **kwargs) { sleep 0.5; original.call(**kwargs) }
```

The `_` prefix in `_original` is a Ruby convention for "I receive this but
don't use it". `*` on its own means "accept any arguments and ignore them".

### Building fake Stripe objects

```ruby
Stripe::Refund.construct_from(id: "re_c5", amount: 400, status: "pending")
```

`construct_from` is the Stripe gem's own way to build an object from a hash,
the same way it does from an API response. Our code can call `refund.id` and
`refund.status` on it as if it came from Stripe. Webhook events are built the
same way with `Stripe::Event.construct_from`.

### Recording calls to check what was sent

```ruby
def stripe_refund_create(error: nil)
  lambda do |_original, params, opts = {}|
    @stripe_calls << { params: params, opts: opts }   # remember every call
    raise error if error
    Stripe::Refund.construct_from(id: "re_c5", amount: params[:amount], status: "pending")
  end
end
```

This fake does two jobs:

- It **records** each call in `@stripe_calls`, so a test can assert *what* was
  sent:
  `assert_equal "refund-#{refund.id}", @stripe_calls.sole[:opts][:idempotency_key]`.
  The same check also proves Stripe was called *exactly once* (`.sole`) or
  never (`@stripe_refund_calls == 0`).
- It **behaves** however the test chooses: raise the given error, or return a
  fake refund.

`params, opts = {}` matches how the Stripe gem is called:
`Stripe::Refund.create({ ...params }, { idempotency_key: ... })`, with two
positional hashes.

### Which Stripe errors we simulate and why

The C5 and C6 fixes depend on telling two kinds of Stripe error apart, so the
tests use one of each:

| Error | Meaning | What the app must do | Used in tests as |
|---|---|---|---|
| `Stripe::InvalidRequestError` (and the other entries in `StripeErrors::DEFINITE_FAILURES`) | Stripe **definitely refused**; nothing was created | Mark the refund or withdrawal `failed`, release the hold | `rejection` |
| `Stripe::APIConnectionError`, `Stripe::APIError` | **Unknown**: a timeout or 5xx. Stripe *may* have done it | Keep it `pending`, keep the hold, retry later with the same idempotency key | `timeout` |

---

## 9. Testing Sidekiq jobs

With `Sidekiq::Testing.fake!` (from `test_helper.rb`):

```ruby
Withdrawals::SubmitWithdrawalJob.perform_async(42)
Withdrawals::SubmitWithdrawalJob.jobs        # => [{ "args" => [42], "class" => "...", ... }]
```

Nothing runs; the job is only recorded. That gives us two kinds of test.

**1. Was the job scheduled?**

```ruby
assert_equal [ withdrawal.id ], Withdrawals::SubmitWithdrawalJob.jobs.sole["args"]
assert_empty Withdrawals::SubmitWithdrawalJob.jobs        # …or: was NOT scheduled
```

**2. Does the job do the right thing?** Call `perform` directly, as AGENTS.md
asks:

```ruby
Withdrawals::SubmitWithdrawalJob.new.perform(withdrawal.id)
```

This is just a method call. It runs immediately in the test, so you can
assert on the result right after.

**Testing what happens when retries run out.** Sidekiq calls the
`sidekiq_retries_exhausted` block after the last failed retry. Waiting for 10
real retries isn't practical, so the test calls the block directly with the
same arguments Sidekiq would pass (the job hash and the exception):

```ruby
Withdrawals::SubmitWithdrawalJob.sidekiq_retries_exhausted_block.call(
  { "args" => [ withdrawal.id ] }, timeout
)
assert withdrawal.reload.pending?     # still holding funds, NOT marked failed
assert AuditLog.exists?(action: "withdrawal.submission_stuck", ...)
```

**Testing that a job lets an error escape.** Sidekiq only retries a job that
raises, so for an unknown outcome we check that the error does get out of
`perform`:

```ruby
assert_raises(Stripe::APIError) { Withdrawals::SubmitWithdrawalJob.new.perform(withdrawal.id) }
```

---

## 10. Concurrency tests (race conditions)

These are the hardest tests in the suite. They're also among the most
important for a money app, because bugs C2 and C3 were race conditions: two
requests arriving at the same moment.

### The problem they test

Bug C2: two requests with the same `Idempotency-Key` arrive together.

```
Request A: insert key ─── transfer ───────────── link key → transaction
Request B:          find key (not linked yet!) ─── transfer AGAIN  ← money moved twice
```

A normal test runs one thing at a time, so it can't reproduce this. We need
two things running at once, with A paused at exactly the right moment.

### Ingredient 1: turn off transactional tests

```ruby
self.use_transactional_tests = false
```

Each thread uses its **own database connection**. If the setup deposit sat
inside an uncommitted test transaction, the other threads' connections
couldn't see it. With this off, everything is really committed, so we must
clean up by hand:

```ruby
teardown do
  AuditLog.delete_all
  IdempotencyKey.delete_all
  LedgerEntry.delete_all
  Transaction.delete_all
end
```

Only tables the test writes to are cleaned; fixture rows such as users and
wallets are left alone. The order matters because of foreign keys: entries
reference transactions, so entries are deleted first.

### Ingredient 2: threads, each with its own connection

```ruby
first = Thread.new do
  ActiveRecord::Base.connection_pool.with_connection do
    Ledger::IdempotentTransfer.call(...)
  end
end
first.value     # wait for the thread and return its result (re-raises its errors)
```

`with_connection` checks a connection out of Rails' pool for the thread and
returns it afterwards. Two threads then behave like two separate web requests.

### Ingredient 3: forcing the bad timing

If you start two threads, you can't control which runs first or where they
overlap. Most runs would miss the race, and the test would pass by luck. So we
**pause the first thread at the dangerous moment**:

```ruby
first_in_transfer = Queue.new                       # a thread-safe signal

slow_first_transfer = lambda do |original, **kwargs|
  if Thread.current[:pause_in_transfer]             # only the FIRST thread pauses
    first_in_transfer << true                       # signal: "I'm inside the transfer"
    sleep 0.5                                       # hold the critical section open
  end
  original.call(**kwargs)                           # then do the real transfer
end

with_class_method(Ledger::Transfer, :call, slow_first_transfer) do
  first = Thread.new do
    Thread.current[:pause_in_transfer] = true
    transfer
  end

  first_in_transfer.pop        # BLOCK until the first thread is inside the transfer
  second = Thread.new { transfer }    # now start the second request

  [ first.value, second.value ]
end
```

Step by step:

1. Thread A starts and marks itself with a thread-local flag
   (`Thread.current[:pause_in_transfer]`). The fake is global, so the flag is
   how we make only A pause.
2. A creates its idempotency key, enters `Ledger::Transfer.call`, pushes to the
   queue, and sleeps.
3. The main thread was waiting on `first_in_transfer.pop`. It wakes up, knowing
   A is now in the dangerous window, and starts thread B.
4. **Before the fix**, B finds the unlinked key and transfers again, so Alice
   ends at 400 instead of 700. **After the fix**, B tries to `lock!` the key
   row, and Postgres makes it wait until A commits. B then sees the linked
   transaction and returns it.
5. The assertions check for one transfer, the same transaction id returned to
   both requests, and a balance of 700.

`Queue#pop` is what makes this reliable: we *know* A is in the critical
section before B starts. `sleep 0.5` gives B time to reach the lock while A is
still holding it.

### The other concurrency tests

- **`idempotent_transfer_concurrency_test.rb`, second test.** This one isn't
  about threads; it needs `use_transactional_tests = false` for another reason.
  It checks that when something fails *after* the transfer (we make the audit
  log raise `ActiveRecord::ConnectionFailed`), the transfer **and** the key are
  both rolled back, and a retry then works. It sits in this non-transactional
  class so it checks what was really committed to the database, not what a
  rollback looks like inside the test's own wrapping transaction.
- **`transfer_withdrawal_concurrency_test.rb` (C3).** It pauses a withdrawal
  *after its balance check* by wrapping `Withdrawal.create!`, then fires a
  transfer. Before the fix the two services locked different rows, so the
  transfer went through and spent money already promised to the withdrawal.
  After the fix both lock the same account row, so the transfer waits, then
  sees the hold and is rejected.

---

## 11. Integration (controller) tests

`test/controllers/api/v1/withdrawals_controller_test.rb` sends a real HTTP
request through routing → `ApplicationController` auth → `WithdrawalsController`
→ the service → the JSON response.

```ruby
class Api::V1::WithdrawalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @wallet = wallets(:alice_usd)
    Ledger::Deposit.call(wallet: @wallet, amount: 1_000, reference: "TEST-FUND-ALICE")

    raw_token = SecureRandom.hex(32)
    AuthToken.create!(user: users(:alice), token_digest: Digest::SHA256.hexdigest(raw_token), expires_at: 1.day.from_now)
    @headers = { "Authorization" => "Bearer #{raw_token}" }
  end
```

**Logging in.** The app stores only the SHA-256 *digest* of a token, never
the token itself (see `ApplicationController#current_user`). So the test
creates a random raw token, saves its digest in `auth_tokens`, and sends the
raw token in the header, just like a real logged-in client. This is quicker
than calling the login endpoint and doesn't depend on it (login has its own
bug, H5).

```ruby
  test "a Stripe rejection returns 422 with the error shape, not a 500" do
    with_class_method(Stripe::Payout, :create, ->(_original, *) { raise Stripe::InvalidRequestError.new("No external account", "destination") }) do
      post "/api/v1/wallets/#{@wallet.id}/withdrawals", params: { amount: 400 }, headers: @headers
    end

    assert_response :unprocessable_entity                         # status 422
    assert_equal "No external account", response.parsed_body["error"]  # error shape
    assert @wallet.withdrawals.sole.failed?                       # DB side effect
  end
```

- `post path, params:, headers:` sends the request. `get`, `patch` and
  `delete` work the same way.
- `assert_response` checks the status by name (`:created` = 201,
  `:unprocessable_entity` = 422, `:unauthorized` = 401, `:not_found` = 404).
- `response.parsed_body` is the JSON response parsed into a hash.
- Also check the **database side effect**, not just the response. A 422 that
  leaves money held would still be a bug.

AGENTS.md asks for integration tests of every endpoint to cover the happy
path, 401, 403, 404, 422 and the response shape. This file only covers the two
C6 cases so far; the rest is listed as follow-up work.

---

## 12. Walkthrough of every test file

### `test/services/ledger/idempotent_transfer_test.rb` (bug C1)

**The bug:** the request hash used `Wallet#to_s`, which looks like
`#<Wallet:0x000...>` and includes a memory address. Every request got a
different hash, so every retry was rejected as "a different request".

| Test | What it proves |
|---|---|
| retrying with the same key and same params returns the original transaction | The core idempotency promise: no new `Transaction`, the same id comes back, and balances moved once. |
| reusing a key with a different amount is rejected without moving money | The safety check still works: the same key with different params is an error, and the balance is untouched. |
| different keys create separate transfers | We didn't break normal use: two keys give two transfers. |

**Key detail:** the helper does `Wallet.find(...)` on **every call**, so each
call has *new Ruby objects*, like a new HTTP request would. If the test reused
the same `Wallet` object, its memory address would match both times and the
bug would stay hidden. A test that doesn't reproduce real conditions can pass
while the bug is still there.

### `test/services/ledger/idempotent_transfer_concurrency_test.rb` (bug C2)

Covered in [section 10](#10-concurrency-tests-race-conditions): two
simultaneous requests move money once, and a failure after the transfer rolls
back both the money and the key.

### `test/services/ledger/transfer_test.rb` (bug C3, plus basics)

| Test | What it proves |
|---|---|
| moves the amount from sender to recipient with balanced entries | Basic transfer, **and** the double-entry rule: total debits = total credits. |
| rejects a transfer that exceeds the balance without changing anything | Insufficient funds → `ArgumentError`, and `assert_no_difference` on `LedgerEntry.count` proves nothing was written. |
| cannot spend money held by a pending withdrawal | **The C3 bug.** 1,000 balance with 800 held leaves 200 available, so a 300 transfer must fail. |
| can spend the part of the balance that isn't held | The fix isn't too strict: the remaining 200 can be spent. |
| funds are released for spending once the withdrawal fails | A failed withdrawal no longer holds money. |

The last two are **boundary tests**. When you fix a "too permissive" bug, check
that you didn't make the code too strict.

### `test/services/ledger/transfer_withdrawal_concurrency_test.rb` (bug C3)

Covered in [section 10](#10-concurrency-tests-race-conditions). It proves that a
withdrawal and a transfer happening at the same moment can't both spend the
same money.

### `test/services/payments/create_refund_test.rb` (bug C4, creation side)

**The bug:** a refund could be created even after the user had transferred the
money away. Stripe would refund the card, but the ledger couldn't record it.

| Test | What it proves |
|---|---|
| creates a pending refund within the payment and wallet limits | Happy path: Stripe called once, refund `pending`. |
| rejects a refund when the wallet no longer holds the money, before calling Stripe | **The C4 bug.** Also asserts `@stripe_refund_calls == 0`. Checking *before* calling Stripe matters, because once Stripe has refunded, the money is gone. |
| a pending refund holds its amount so it can't be transferred away | A pending refund reduces `available_balance`, the same way a pending withdrawal does. |
| partial refunds still can't exceed the payment amount | An existing rule still works after the change. |

### `test/services/ledger/settlement_test.rb` (bug C4, settlement side)

**The idea:** when Stripe tells us a refund or payout *already happened*, the
money is gone. Refusing to record it doesn't bring the money back; it only
makes the ledger wrong. So settlement must **always post**, and flag a
negative balance for a person to look at.

| Test | What it proves |
|---|---|
| a refund posts normally when the wallet covers it | Normal case, with no flag. |
| a refund Stripe already paid posts even when the wallet can't cover it, and is flagged | Posts 2 entries, balance goes to −200, and an `account.negative_balance` audit log records the reference and balance. |
| a payout Stripe already paid posts … and is flagged | The same for withdrawals. |

### `test/services/payments/process_stripe_webhook_settlement_test.rb` (bug C4, end to end)

These tests run the **whole webhook processor** with a fake `Stripe::Event`,
proving that the settlement fix works through the real entry point: the
refund/withdrawal becomes `succeeded`, the ledger posts, and the
`WebhookEvent` is marked `processed` instead of failing and being retried
forever.

```ruby
Stripe::Event.construct_from(id: "evt_...", type: "payout.paid", data: { object: { id: "po_settle", ... } })
```

The event's `metadata` (`withdrawal_id`) and `id`/`amount`/`currency` must
match the local record, because the handler validates all of them. That's a
useful thing to remember when writing webhook tests.

### `test/services/payments/submit_refund_test.rb` (bug C5)

**The bug:** refunds were sent to Stripe **without an idempotency key**, so a
retry after a timeout could refund twice. Any Stripe error also left an orphan
`pending` refund that held money forever.

| Test | What it proves |
|---|---|
| sends an idempotency key tied to the local refund | The key is `refund-<id>`, the same on every attempt, so Stripe can recognize a repeat. |
| a definite Stripe rejection marks the refund failed and releases the hold | Rejection → `failed`, available balance back to 1,000, audit log written, **no** retry job. |
| an unknown outcome keeps the refund pending and schedules a retry | Timeout → still `pending`, hold kept (600 available), one retry job queued. |
| the retry job resubmits with the same idempotency key and stores the Stripe id | Both attempts used the **same** key. The refund stays `pending`, because only the webhook decides success. |
| the retry job marks the refund failed on a definite rejection, without raising | A job that raises would be retried by Sidekiq for nothing, so a definite rejection must not raise. |
| the retry job lets an unknown outcome raise so Sidekiq retries it | The opposite: an unknown outcome *must* raise so Sidekiq retries. |
| the retry job does nothing for a refund that's already submitted | The job is idempotent: running it again is harmless. |
| when retries run out the refund stays pending and is flagged for a person | We never guess "failed" (Stripe may have refunded); we raise the alarm instead. |

### `test/services/withdrawals/submit_withdrawal_test.rb` (bug C6)

The same eight scenarios as C5, for payouts. One extra check: a rejection
stores Stripe's error code on the withdrawal (`failure_code: "balance_insufficient"`).
One test runs the job against an already-submitted withdrawal and a `canceled`
one, and asserts Stripe was called only for the two original submissions.

### `test/controllers/api/v1/withdrawals_controller_test.rb` (bug C6, HTTP side)

Covered in [section 11](#11-integration-controller-tests). A rejection returns 422
with `{ "error": ... }` (it used to be a 500), and a timeout returns 201 with a
`pending` withdrawal.

---

## 13. The workflow: failing test first

Every bug was fixed with the same loop, called **red → green**:

1. **Write the test that describes correct behavior.**
2. **Run it and watch it fail (red).** This step is essential. A test you've
   never seen fail might not test anything; it could pass because of a typo or
   a wrong setup. For example, before the C6 fix the new tests gave
   `1 failure, 8 errors`. Seeing that proved the tests actually detect the bug.
3. **Make the smallest code change that fixes it.**
4. **Run it and watch it pass (green).**
5. **Run the whole suite**, several times, because of random order. This
   catches fixes that broke something else, or tests that depend on order.
6. **Run `bin/rubocop`** to check style.

The failure message also helps. `Expected: 700, Actual: 400` tells you exactly
what happened: money moved twice.

---

## 14. Common mistakes

**Forgetting `.reload`.** Ruby objects don't update themselves when the
database changes:

```ruby
refund = create_refund[:refund]
# ...the job marks it failed in the DB...
refund.failed?          # false: still the old in-memory value
refund.reload.failed?   # true: re-read from the DB
```

`accounts(:alice_usd)` returns a cached object, so we write
`accounts(:alice_usd).reload.balance`.

**Reusing objects that should be fresh.** See the C1 note: when a test
imitates separate requests, load fresh records (`Wallet.find(id)`) each time.

**Expected and actual swapped.** `assert_equal actual, expected` still works
when the test passes, but when it fails the message is backwards and
misleading.

**Only checking the response.** For money operations, also check the
balance, the record status, and that nothing extra was written
(`assert_no_difference`).

**Global state leaking between tests.** Anything outside the database survives
the rollback: Sidekiq's fake job arrays, replaced methods, class variables.
That's why `test_helper.rb` clears jobs in `setup` and `with_class_method`
restores in `ensure`.

**Non-transactional tests that don't clean up.** If you set
`use_transactional_tests = false`, delete what you created in `teardown`, or
later tests will see leftover rows (and unique `reference`s will clash).

**Calling the real Stripe.** If a code path calls Stripe and the test didn't
fake it, the test will try to reach the network. Wrap every path that reaches
Stripe in `with_class_method`.

---

## 15. Writing your next test

A template for a service test:

```ruby
require "test_helper"

class Payments::SomethingTest < ActiveSupport::TestCase
  setup do
    @wallet = wallets(:alice_usd)
    Ledger::Deposit.call(wallet: @wallet, amount: 1_000, reference: "TEST-FUND-ALICE")
  end

  test "describes the correct behavior in plain words" do
    # Arrange: build the exact state you need

    # Act: one call
    result = with_class_method(Stripe::Something, :create, ->(_o, *) { Stripe::Something.construct_from(id: "x_1") }) do
      Payments::Something.call(...)
    end

    # Assert: result, DB state, and ledger balance
    assert result.pending?
    assert_equal 1_000, accounts(:alice_usd).reload.balance
  end

  test "rejects bad input without changing anything" do
    assert_no_difference -> { LedgerEntry.count } do
      assert_raises(ArgumentError) { Payments::Something.call(...) }
    end
  end
end
```

Checklist before calling a test done:

- [ ] I saw it fail before the fix (for bugs).
- [ ] It checks the ledger balance or entry count, not only the return value.
- [ ] Stripe is faked on every path.
- [ ] It passes when run alone (`bin/rails test path:line`) **and** in the full suite.
- [ ] The test name says what *should* happen.

### What isn't tested yet

These areas from the original testing plan still need tests:

- endpoint tests for 401/403/404 and customer-vs-admin access;
- webhook signature failures, duplicate and out-of-order events;
- reconciliation (matching, discrepancies, retries, counters);
- ledger immutability (bug H12).

Each of these is a good exercise, and the remaining items in `docs/BUGS.md`
each start with writing the failing test.
