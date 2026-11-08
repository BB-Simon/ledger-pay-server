require "test_helper"

# M18: one KYC profile per user, in the model and in the database.
class KycProfileTest < ActiveSupport::TestCase
  setup do
    KycProfile.create!(user: users(:alice), status: "pending")
  end

  test "a second profile for the same user is invalid" do
    assert_raises(ActiveRecord::RecordInvalid) do
      KycProfile.create!(user: users(:alice), status: "pending")
    end
  end

  test "the database rejects a second profile even when validations are skipped" do
    now = Time.current

    assert_raises(ActiveRecord::RecordNotUnique) do
      KycProfile.insert!({ user_id: users(:alice).id, status: "pending", created_at: now, updated_at: now })
    end
  end
end
