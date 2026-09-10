class CreateWebhookEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :webhook_events do |t|
      t.string :provider, null: false
      t.string :event_id, null: false
      t.string :event_type, null: false
      t.text :payload, null: false
      t.string :status, null: false, default: 'pending'
      t.datetime :processed_at

      t.timestamps
    end

    add_index :webhook_events, [ :provider, :event_id ], unique: true
  end
end
