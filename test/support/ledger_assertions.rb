# Double-entry checks over the whole ledger, for tests that move money.
module LedgerAssertions
  # Every transaction has at least two entries and its debits equal its
  # credits, and the trial balance holds: debit-normal accounts (assets,
  # expenses) total the same as credit-normal ones (liabilities, equity,
  # revenue).
  def assert_ledger_balanced
    Transaction.includes(:ledger_entries).find_each do |transaction|
      entries = transaction.ledger_entries
      debits = entries.select(&:debit?).sum(&:amount)
      credits = entries.select(&:credit?).sum(&:amount)

      assert_operator entries.size, :>=, 2, "#{transaction.reference} has fewer than two entries"
      assert_equal debits, credits, "#{transaction.reference} is unbalanced: #{debits} debits, #{credits} credits"
    end

    totals = LedgerEntry.group(:entry_type).sum(:amount)
    assert_equal totals.fetch("debit", 0), totals.fetch("credit", 0), "ledger debits and credits differ"

    debit_normal = Account.where(account_type: %w[asset expense]).sum(&:balance)
    credit_normal = Account.where(account_type: %w[liability equity revenue]).sum(&:balance)
    assert_equal debit_normal, credit_normal, "trial balance doesn't hold"
  end

  def balance_of(account_fixture)
    accounts(account_fixture).reload.balance
  end
end
