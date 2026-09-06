class ApplicationController < ActionController::API
  private

  def current_user
    @current_user if defined?(@current_user)

    token = request.headers["Authorization"]&.delete_prefix("Bearer ")

    return @current_user = nil if token.blank?

    digest = Digest::SHA256.hexdigest(token)

    auth_token = AuthToken.includes(:user).find_by(token_digest: digest)

    return @current_user = nil unless auth_token
    return @current_user = nil if auth_token.expires_at < Time.current

    @current_user = auth_token.user
  end

  def authenticate_user!
    return if current_user

    render json: {
      error: "Authentication required"
    }, status: :unauthorized
  end
end
