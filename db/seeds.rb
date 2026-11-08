# Records every environment needs (BUGS.md M7). Idempotent: safe to run on
# every deploy (bin/rails db:seed) and run automatically by db:prepare when it
# creates a database.
#
# Payments, refunds and withdrawals look up the clearing accounts by code
# (STRIPE_CLEARING_<CUR>, WITHDRAWAL_CLEARING_<CUR>) and fail without them.
# Wallets and their accounts are opened per user by Wallets::Open.

currencies = [
  { code: "USD", name: "US Dollar", decimal_places: 2 }
]

currencies.each do |attrs|
  currency = Currency.find_or_create_by!(code: attrs[:code]) do |new_currency|
    new_currency.name = attrs[:name]
    new_currency.decimal_places = attrs[:decimal_places]
  end

  {
    "STRIPE_CLEARING" => "Stripe clearing",
    "WITHDRAWAL_CLEARING" => "Withdrawal clearing"
  }.each do |prefix, name|
    Account.find_or_create_by!(code: "#{prefix}_#{currency.code}") do |account|
      account.currency = currency
      account.account_type = :asset
      account.name = "#{name} #{currency.code}"
      account.status = "active"
    end
  end
end
