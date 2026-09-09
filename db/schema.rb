# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_09_223840) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "accounts", force: :cascade do |t|
    t.string "account_type", null: false
    t.string "code"
    t.datetime "created_at", null: false
    t.bigint "currency_id", null: false
    t.string "name"
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.bigint "wallet_id"
    t.index ["code"], name: "index_accounts_on_code", unique: true
    t.index ["currency_id"], name: "index_accounts_on_currency_id"
    t.index ["wallet_id"], name: "index_accounts_on_wallet_id", unique: true
  end

  create_table "auth_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["token_digest"], name: "index_auth_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_auth_tokens_on_user_id"
  end

  create_table "currencies", force: :cascade do |t|
    t.string "code", null: false
    t.datetime "created_at", null: false
    t.integer "decimal_places", default: 2, null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["code"], name: "index_currencies_on_code", unique: true
  end

  create_table "idempotency_keys", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.bigint "ledger_transaction_id"
    t.string "request_hash", null: false
    t.string "status", default: "processing", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["ledger_transaction_id"], name: "index_idempotency_keys_on_ledger_transaction_id"
    t.index ["user_id", "key"], name: "index_idempotency_keys_on_user_id_and_key", unique: true
    t.index ["user_id"], name: "index_idempotency_keys_on_user_id"
  end

  create_table "kyc_profiles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "verification_level"
    t.datetime "verified_at"
    t.index ["user_id"], name: "index_kyc_profiles_on_user_id"
  end

  create_table "ledger_entries", force: :cascade do |t|
    t.bigint "account_id", null: false
    t.bigint "amount", null: false
    t.datetime "created_at", null: false
    t.string "entry_type", null: false
    t.bigint "ledger_transaction_id", null: false
    t.datetime "updated_at", null: false
    t.index ["account_id"], name: "index_ledger_entries_on_account_id"
    t.index ["entry_type"], name: "index_ledger_entries_on_entry_type"
    t.index ["ledger_transaction_id"], name: "index_ledger_entries_on_ledger_transaction_id"
  end

  create_table "payments", force: :cascade do |t|
    t.bigint "amount", null: false
    t.datetime "created_at", null: false
    t.bigint "currency_id", null: false
    t.string "provider", null: false
    t.string "provider_payment_id"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "wallet_id", null: false
    t.index ["currency_id"], name: "index_payments_on_currency_id"
    t.index ["provider", "provider_payment_id"], name: "index_payments_on_provider_and_provider_payment_id", unique: true
    t.index ["user_id"], name: "index_payments_on_user_id"
    t.index ["wallet_id"], name: "index_payments_on_wallet_id"
  end

  create_table "transactions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "currency_id", null: false
    t.string "reference", null: false
    t.string "status", default: "posted", null: false
    t.string "transaction_type", null: false
    t.datetime "updated_at", null: false
    t.index ["currency_id"], name: "index_transactions_on_currency_id"
    t.index ["reference"], name: "index_transactions_on_reference", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["status"], name: "index_users_on_status"
  end

  create_table "wallets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "currency_id", null: false
    t.string "status"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["currency_id"], name: "index_wallets_on_currency_id"
    t.index ["user_id", "currency_id"], name: "index_wallets_on_user_id_and_currency_id", unique: true
    t.index ["user_id"], name: "index_wallets_on_user_id"
  end

  add_foreign_key "accounts", "currencies"
  add_foreign_key "accounts", "wallets"
  add_foreign_key "auth_tokens", "users"
  add_foreign_key "idempotency_keys", "transactions", column: "ledger_transaction_id"
  add_foreign_key "idempotency_keys", "users"
  add_foreign_key "kyc_profiles", "users"
  add_foreign_key "ledger_entries", "accounts"
  add_foreign_key "ledger_entries", "transactions", column: "ledger_transaction_id"
  add_foreign_key "payments", "currencies"
  add_foreign_key "payments", "users"
  add_foreign_key "payments", "wallets"
  add_foreign_key "transactions", "currencies"
  add_foreign_key "wallets", "currencies"
  add_foreign_key "wallets", "users"
end
