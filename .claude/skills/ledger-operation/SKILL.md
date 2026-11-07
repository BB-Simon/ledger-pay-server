---
name: ledger-operation
description: Add or change a money movement in the double-entry ledger (deposit, transfer, withdrawal, refund, fee, reversal, or a new type). Use whenever code needs to post ledger entries or change balances.
---

# Add a ledger operation

Ledger mistakes lose money, so follow every step. Reference implementations: `app/services/ledger/transfer.rb`, `withdraw.rb`, `reverse_withdrawal.rb`, `idempotent_transfer.rb`.

## 0. Design it first (write this into your plan and get approval)
1. **Which accounts?** A user's wallet account (`wallet.account`) and/or a system account looked up by code (`STRIPE_CLEARING_<CUR>`, `WITHDRAWAL_CLEARING_<CUR>`). A new system account (e.g. `FEE_REVENUE_<CUR>`) needs a migration or seed plus approval.
2. **Debit or credit?** `Account#balance` grows with **debits** for `asset`/`expense` accounts and with **credits** for `liability`/`equity`/`revenue`. User wallet accounts are liabilities, so money *into* a wallet is a **credit** to the wallet and a debit to the counter-account.
3. **`transaction_type`**: one of `deposit withdrawal transfer refund fee reversal` (`Transaction` enum). A new type needs a new enum value with string backing, plus a check-constraint migration if one exists.
4. **Reference**: a fixed reference for anything tied to an external object (`"<TYPE>-#{record.id}"`). `Transaction.reference` is unique, so a retry fails instead of posting twice. Use `SecureRandom.uuid` only for user-initiated operations that are protected by an `IdempotencyKey`.
5. **What triggers it?** For Stripe-backed money, only a verified webhook (see the `stripe-webhook-event` skill), never the API request.

## 1. Service skeleton (`app/services/ledger/<name>.rb`)
```ruby
module Ledger
  class ChargeFee
    def self.call(wallet:, amount:, reference:)
      new(wallet:, amount:, reference:).call
    end

    def initialize(wallet:, amount:, reference:)
      @wallet, @amount, @reference = wallet, amount, reference
    end

    def call
      validate!

      Account.transaction do
        lock_accounts!            # ascending account id order
        validate_balance!         # AFTER locking, never before

        Ledger::PostTransaction.call(
          reference: @reference,
          transaction_type: :fee,
          currency: @wallet.currency,
          entries: [
            { account: @wallet.account, entry_type: :debit,  amount: @amount },
            { account: fee_account,     entry_type: :credit, amount: @amount }
          ]
        )
      end
    end

    private

    def validate!
      raise ArgumentError, "Amount must be a positive integer" unless @amount.is_a?(Integer) && @amount.positive?
      raise ArgumentError, "Wallet must be active" unless @wallet.status == "active"
      raise ArgumentError, "Wallet account is required" unless @wallet.account
    end

    def lock_accounts!
      [ @wallet.account, fee_account ].sort_by(&:id).each(&:lock!)
    end

    def validate_balance!
      raise ArgumentError, "Insufficient balance" if @wallet.account.balance < @amount
    end

    def fee_account
      @fee_account ||= Account.find_by!(code: "FEE_REVENUE_#{@wallet.currency.code.upcase}")
    end
  end
end
```

## 2. Invariants (never break these)
- Write entries **only** via `Ledger::PostTransaction`. It checks for at least 2 entries, positive integer amounts, active accounts, a single currency, and debits == credits.
- Amounts are integer minor units. No floats, decimals or `to_f`.
- Never update or delete a `LedgerEntry` or `Transaction`. To undo, post a new `:reversal` transaction with the debits and credits swapped (see `ReverseWithdrawal`) and record the reversal reference on the source record.
- If the operation also changes a record's status (payment, withdrawal, refund), do it in the same DB transaction: lock the record (`Model.lock.find(id)`), re-check the status guard, update the status, then post. If the status is already terminal, return early.
- Spending checks use `wallet.available_balance` (which subtracts pending withdrawals) when the money leaves later, and `account.balance` once the money has actually left.
- Write an audit log after posting: `AuditLogs::Record.call(action: "<resource>.<event>", auditable:, user:, metadata: { amount:, currency: })`. Pass a real user (`record.user`), not an unset ivar.
- Watch the casing of system account codes: `Deposit` upcases the currency code but `Withdraw`/`Refund` don't. Match whatever the existing rows use.

## 3. Tests (required; see the `write-tests` skill)
In `test/services/ledger/<name>_test.rb`, assert:
- Each affected account's balance changes by the exact expected amount (`assert_difference -> { account.reload.balance }, -500`).
- Exactly one `Transaction` and N `LedgerEntry` rows are created, and the debit total equals the credit total.
- Calling twice with the same reference raises (`ActiveRecord::RecordNotUnique` / `RecordInvalid`) and doesn't post twice.
- Each validation raises `ArgumentError` and creates no rows (`assert_no_difference "LedgerEntry.count"`).
- Insufficient balance is rejected.

Finish with the `verify` skill.
