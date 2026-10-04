class AddIndexesToAuditLogs < ActiveRecord::Migration[8.1]
  def change
    add_index :audit_logs, [ :auditable_type, :auditable_id ]

    add_index :audit_logs, :action

    add_index :audit_logs, :request_id

    add_index :audit_logs, [ :user_id, :created_at ]
  end
end
