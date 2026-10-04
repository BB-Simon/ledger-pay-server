class CreateAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :audit_logs do |t|
      t.references :user, null: true, foreign_key: true
      t.string :auditable_type
      t.bigint :auditable_id
      t.string :action
      t.jsonb :metadata
      t.string :ip_address
      t.string :request_id

      t.timestamps
    end
  end
end
