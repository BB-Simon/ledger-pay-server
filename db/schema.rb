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

ActiveRecord::Schema[8.1].define(version: 2026_10_04_221839) do
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

  create_table "audit_logs", force: :cascade do |t|
    t.string "action"
    t.bigint "auditable_id"
    t.string "auditable_type"
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.jsonb "metadata"
    t.string "request_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["action"], name: "index_audit_logs_on_action"
    t.index ["auditable_type", "auditable_id"], name: "index_audit_logs_on_auditable_type_and_auditable_id"
    t.index ["request_id"], name: "index_audit_logs_on_request_id"
    t.index ["user_id", "created_at"], name: "index_audit_logs_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_audit_logs_on_user_id"
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
    t.string "failure_code"
    t.text "failure_message"
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

  create_table "reconciliation_records", force: :cascade do |t|
    t.bigint "actual_amount"
    t.datetime "created_at", null: false
    t.string "currency"
    t.jsonb "details"
    t.string "discrepancy_type"
    t.bigint "expected_amount"
    t.bigint "internal_id"
    t.string "internal_type"
    t.string "provider"
    t.string "provider_reference"
    t.string "record_type"
    t.string "status"
    t.datetime "updated_at", null: false
    t.index ["discrepancy_type"], name: "index_reconciliation_records_on_discrepancy_type"
    t.index ["internal_type", "internal_id"], name: "index_reconciliation_records_on_internal_type_and_internal_id"
    t.index ["provider", "provider_reference"], name: "idx_on_provider_provider_reference_78d0571d5c", unique: true
    t.index ["status"], name: "index_reconciliation_records_on_status"
  end

  create_table "refunds", force: :cascade do |t|
    t.bigint "amount", null: false
    t.datetime "created_at", null: false
    t.bigint "payment_id", null: false
    t.string "provider", null: false
    t.string "provider_refund_id"
    t.string "reason"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["payment_id"], name: "index_refunds_on_payment_id"
    t.index ["provider", "provider_refund_id"], name: "index_refunds_on_provider_and_provider_refund_id", unique: true
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

  create_table "webhook_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "event_id", null: false
    t.string "event_type", null: false
    t.text "payload", null: false
    t.datetime "processed_at"
    t.string "provider", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "event_id"], name: "index_webhook_events_on_provider_and_event_id", unique: true
  end

  create_table "withdrawals", force: :cascade do |t|
    t.bigint "amount", null: false
    t.datetime "created_at", null: false
    t.bigint "currency_id", null: false
    t.string "failure_code"
    t.text "failure_message"
    t.string "provider", null: false
    t.string "provider_withdrawal_id"
    t.string "reversal_reference"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "wallet_id", null: false
    t.index ["currency_id"], name: "index_withdrawals_on_currency_id"
    t.index ["provider", "provider_withdrawal_id"], name: "index_withdrawals_on_provider_and_provider_withdrawal_id", unique: true
    t.index ["user_id"], name: "index_withdrawals_on_user_id"
    t.index ["wallet_id"], name: "index_withdrawals_on_wallet_id"
  end

  add_foreign_key "accounts", "currencies"
  add_foreign_key "accounts", "wallets"
  add_foreign_key "audit_logs", "users"
  add_foreign_key "auth_tokens", "users"
  add_foreign_key "idempotency_keys", "transactions", column: "ledger_transaction_id"
  add_foreign_key "idempotency_keys", "users"
  add_foreign_key "kyc_profiles", "users"
  add_foreign_key "ledger_entries", "accounts"
  add_foreign_key "ledger_entries", "transactions", column: "ledger_transaction_id"
  add_foreign_key "payments", "currencies"
  add_foreign_key "payments", "users"
  add_foreign_key "payments", "wallets"
  add_foreign_key "refunds", "payments"
  add_foreign_key "transactions", "currencies"
  add_foreign_key "wallets", "currencies"
  add_foreign_key "wallets", "users"
  add_foreign_key "withdrawals", "currencies"
  add_foreign_key "withdrawals", "users"
  add_foreign_key "withdrawals", "wallets"
end
