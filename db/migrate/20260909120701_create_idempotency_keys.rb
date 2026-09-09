class CreateIdempotencyKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :idempotency_keys do |t|
      t.string :key, null: false
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: "processing"
      t.references :transaction, foreign_key: true
      t.string :request_hash, null: false

      t.timestamps
    end

    add_index :idempotency_keys, [ :user_id, :key ], unique: true
  end
end
