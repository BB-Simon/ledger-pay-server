# Logs a user in the way the API does: only the SHA-256 digest of the token
# is stored, and the raw token goes in the Authorization header.
module AuthHelpers
  def bearer_for(user)
    raw_token = SecureRandom.hex(32)
    AuthToken.create!(user: user, token_digest: Digest::SHA256.hexdigest(raw_token), expires_at: 1.day.from_now)
    "Bearer #{raw_token}"
  end
end
