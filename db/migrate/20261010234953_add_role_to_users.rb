class AddRoleToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :role, :string, null: false, default: "customer"

    add_check_constraint :users,
      "role IN ('customer', 'admin', 'compliance_officer', 'finance_officer', 'support_agent', 'system')",
      name: "users_role_check"
  end
end
