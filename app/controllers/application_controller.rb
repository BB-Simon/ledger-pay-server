class ApplicationController < ActionController::API
  private

  def current_user
    return @current_user if defined?(@current_user)

    token = request.headers["Authorization"]&.delete_prefix("Bearer ")

    return @current_user = nil if token.blank?

    digest = Digest::SHA256.hexdigest(token)

    auth_token = AuthToken.includes(:user).find_by(token_digest: digest)

    return @current_user = nil unless auth_token
    return @current_user = nil if auth_token.expires_at < Time.current
    # Suspended or closed accounts can't keep using tokens issued earlier.
    return @current_user = nil unless auth_token.user.status == "active"

    @current_user = auth_token.user
  end

  def authenticate_user!
    return if current_user

    render json: {
      error: "Authentication required"
    }, status: :unauthorized
  end

  def require_admin!
    return if current_user&.admin?

    render json: {
      error: "Admin access required"
    }, status: :forbidden
  end

  # Amounts are whole numbers of cents. Returns nil for anything else
  # ("10.99", "1e3", "abc", 10.99) instead of truncating it like to_i, so
  # the service rejects it with "Amount must be a positive integer".
  def amount_param(key = :amount)
    value = params[key]

    case value
    when Integer then value
    when String then value.match?(/\A\d+\z/) ? value.to_i : nil
    end
  end

  def render_rate_limited
    render json: { error: "Too many requests, try again later" }, status: :too_many_requests
  end

  def idempotency_key_header
    request.headers["Idempotency-Key"].to_s.strip.presence
  end
end
