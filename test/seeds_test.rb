require "test_helper"

# M7: a fresh install must have the currency and clearing accounts that
# payments, refunds and withdrawals look up by code.
class SeedsTest < ActiveSupport::TestCase
  def load_seeds
    load Rails.root.join("db/seeds.rb")
  end

  test "creates the currency and clearing accounts on an empty database" do
    Account.delete_all
    Wallet.delete_all
    Currency.delete_all

    load_seeds

    usd = Currency.find_by!(code: "USD")
    assert_equal 2, usd.decimal_places
    assert Account.find_by!(code: "STRIPE_CLEARING_USD").asset?
    assert Account.find_by!(code: "WITHDRAWAL_CLEARING_USD").asset?
  end

  test "running the seeds again changes nothing" do
    load_seeds

    assert_no_difference [ -> { Currency.count }, -> { Account.count } ] do
      load_seeds
    end
  end
end
