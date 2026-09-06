class CreateKycProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :kyc_profiles do |t|
      t.references :user, null: false, foreign_key: true
      t.string :status, null: false, default: "pending"
      t.string :verification_level
      t.datetime :verified_at

      t.timestamps
    end
  end
end
