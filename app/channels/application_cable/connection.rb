# frozen_string_literal: true

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :app

    def connect
      self.current_user = find_resource
    end

    # finds agent or app user
    def find_resource
      params = request.query_parameters
      # TODO: decide either pick auth0 or doorkeeper strategy
      self.app = App.find_by(key: params[:app]) if params[:app]

      if Chaskiq::Config.get("AUTH0_ENABLED") == "true"
        return AuthIdentity.find_agent_from_token(params[:token]) if params[:token]
      elsif params[:token]
        return find_verified_agent
      end

      get_session_data
    end

    def find_verified_agent
      user = Agent.find_by(id: access_token.resource_owner_id) if access_token
      return user if user

      raise "invalid user"
    end

    def access_token
      params = request.query_parameters
      @access_token ||= Doorkeeper::AccessToken.by_token(params[:token])
    end

    def get_session_data
      params = request.query_parameters

      if app.present?
        OriginValidator.new(
          app: app.domain_url,
          host: env["HTTP_ORIGIN"]
        ).is_valid?

        find_user(get_user_data)
      end
    end

    rescue_from StandardError, with: :report_error

    private

    def report_error(e)
      Bugsnag.notify(e) do |report|
        report.add_tab(
          :context,
          {
            app: app&.key,
            env: env["HTTP_ORIGIN"],
            params: request.query_parameters,
            current_user: current_user&.key
          }
        )
      end
    end

    def get_user_data
      # check cookie session
      session_value = request.query_parameters[:session_value]

      if session_value.present? && (u = SessionFinder.get_by_cookie_session(session_value)) && u.present? && u[:email].present?
        return u
      end

      if app.encryption_enabled?
        authorize_by_identifier_params || authorize_by_encrypted_params
      else
        get_user_from_unencrypted
      end
    end

    def authorize_by_identifier_params
      params = request.query_parameters
      data = begin
        JSON.parse(Base64.decode64(params[:user_data]))
      rescue StandardError
        nil
      end
      return nil unless data.is_a?(Hash)
      return data&.with_indifferent_access if app.compare_user_identifier(data)
    end

    def authorize_by_encrypted_params
      params = request.query_parameters
      app.decrypt(params[:enc])
    end

    def find_user(user_data)
      params = request.query_parameters
      if user_data.blank?
        app.get_non_users_by_session(params[:session_id])
      elsif user_data[:email]
        app.get_app_user_by_email(user_data[:email])
      end
    end
  end
end
