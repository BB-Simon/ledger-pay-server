---
name: verify
description: Run the project's definition-of-done checks (affected tests, rubocop, brakeman, bundler-audit) and report results. Use before saying a change is finished, before a commit/PR, or when asked to check or verify the code.
---

# Verify a change

This is the "Done" check from AGENTS.md. Run every step, even if an earlier one fails, and report all of the results.

## 1. Work out the scope
```sh
git status --short
git diff --stat main...HEAD   # plus uncommitted changes
```
Map each changed file to its tests:
- `app/models/x.rb` → `test/models/x_test.rb`
- `app/services/<domain>/x.rb` → `test/services/<domain>/x_test.rb`
- `app/controllers/api/v1/<path>_controller.rb` → `test/controllers/api/v1/<path>_controller_test.rb`
- `app/jobs/<domain>/x.rb` → `test/jobs/<domain>/x_test.rb`
- `app/services/ledger/*`, `app/services/payments/process_stripe_webhook.rb`, migrations, `config/routes.rb`, `test/fixtures/*`, `test/test_helper.rb` → run the **full** suite.

If a changed behavior has no test, say so. Behavior changes need tests (see the `write-tests` skill).

## 2. Run the checks
```sh
bin/rails test <mapped test files>        # or: bin/rails test
bin/rubocop -a <changed .rb files>        # autocorrect, then re-run without -a to confirm clean
bin/rubocop
bin/brakeman --no-pager --quiet
bin/bundler-audit                         # only needed if Gemfile/Gemfile.lock changed, but cheap
```
If migrations changed, also run `bin/rails db:migrate` and `bin/rails db:rollback && bin/rails db:migrate` to prove they can be rolled back. Then confirm `db/schema.rb` changed only as expected.

Notes:
- This runs on Windows. If a `bin/*` script fails to start, retry with `ruby bin/<script>` or `bundle exec <tool>`.
- Tests need Postgres running plus `DATABASE_PASSWORD` and `STRIPE_SECRET_KEY` set. If they're missing, report that; don't read `.env`.
- Never "fix" a failure by deleting or skipping tests, loosening assertions, or adding rubocop disables unless the user agrees.

## 3. Self-review the diff for this app's invariants
Scan `git diff` and flag any of:
- Ledger rows written outside `Ledger::PostTransaction`, or `update`/`destroy` on `LedgerEntry`/`Transaction`
- floats/decimals for money; amounts not converted with `to_i`
- state changes without a lock plus a status re-check; locks taken in the wrong order
- lookups not scoped to `current_user`; missing `authenticate_user!`/`require_admin!`
- `render json: model`, or digests, tokens or payloads exposed
- Stripe called before the local record exists; ledger posted outside a verified webhook
- jobs enqueued inside a DB transaction; unbounded index queries
- enum spelling mismatches (`canceled` vs `cancelled`); method called with the wrong number of arguments

## 4. Report
```
Verification
- Tests: bin/rails test <files> → 42 runs, 0 failures, 0 errors
- RuboCop: clean (autocorrected 3 offenses in x.rb)
- Brakeman: 0 warnings
- bundler-audit: no vulnerabilities
- Not covered: <behavior without tests, or checks that could not run and why>
- Invariant concerns: <none | list>
```
Report failures with the relevant output. Don't claim the change is done if anything failed or was skipped.
