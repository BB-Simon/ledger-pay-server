class AddReversalReferenceToWithdrawals < ActiveRecord::Migration[8.1]
  def change
    add_column :withdrawals, :reversal_reference, :string
  end
end
