# A user has one KYC profile (User has_one :kyc_profile), so enforce it in
# the database (BUGS.md M18). Fails if duplicates already exist; remove them
# first.
class MakeKycProfilesUserIdUnique < ActiveRecord::Migration[8.1]
  def change
    remove_index :kyc_profiles, :user_id, name: "index_kyc_profiles_on_user_id"
    add_index :kyc_profiles, :user_id, unique: true, name: "index_kyc_profiles_on_user_id"
  end
end
