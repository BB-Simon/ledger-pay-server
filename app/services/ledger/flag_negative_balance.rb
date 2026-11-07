module Ledger
  # Settlement services post money that has already left at Stripe, so they
  # can't refuse to post. If that takes an account below zero, record it in
  # the audit log so someone can follow up.
  class FlagNegativeBalance
    def self.call(account:, reference:, user:)
      balance = account.balance
      return if balance >= 0

      AuditLogs::Record.call(
        action: "account.negative_balance",
        auditable: account,
        user: user,
        metadata: {
          balance: balance,
          currency: account.currency.code,
          reference: reference
        }
      )
    end
  end
end
