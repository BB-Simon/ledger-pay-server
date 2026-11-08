# Lets an idempotency key point at the record it created (a Withdrawal or
# Refund), not only at a ledger Transaction (BUGS.md M14).
class AddResourceToIdempotencyKeys < ActiveRecord::Migration[8.1]
  def change
    add_reference :idempotency_keys, :resource, polymorphic: true, null: true, index: true
  end
end
