require 'uri'
require 'json'

module Lita
  module Handlers
    class HarvestTracker < Handler
      HARVEST_CLIENT_ID = ENV.fetch("HARVEST_OAUTH_CLIENT_ID")
      HARVEST_CLIENT_SECRET = ENV.fetch("HARVEST_OAUTH_CLIENT_SECRET")
      PREFIX = "harvest\s"

      route(/#{PREFIX}login/, :login, command: true)
      http.get "/harvest-tracker-authorize", :login_cb
      on :authorized, :send_authorized_message

      def login(response)
        state = {
          uuid: SecureRandom.uuid
        }
        redis.set(state[:uuid], response.user.id)
        response.reply(
          "https://id.getharvest.com/oauth2/authorize?client_id=#{HARVEST_CLIENT_ID}&response_type=code&state=#{state.to_json}"
        )
      end

      def login_cb(request, response)
        state = JSON.parse(request.params["state"])
        user_id = redis.get(state["uuid"])
        redis.del(state["uuid"])
        save_user_info(user_id, "scope", request.params["scope"])
        refresh_access_token(user_id, request.params["code"])
        response.body << "Autenticacion realizada."
      rescue StandardError
        response.body << "Hubo un error con la autenticacion, intentalo nuevamente"
      end

      def refresh_access_token(user_id, code)
        body = "code=#{code}&"\
                "client_id=#{HARVEST_CLIENT_ID}&"\
                "client_secret=#{HARVEST_CLIENT_SECRET}&"\
                "grant_type=authorization_code"
        response = http.post("https://id.getharvest.com/api/v2/oauth2/token", body)
        json = JSON.parse(response.body)
        if json["error"]
          reset_user(user_id)
          raise "Auth Error: #{json['error']}"
        else
          save_user_info(user_id, "auth", response.body)
          robot.trigger(:authorized, user_id: user_id)
        end
      end

      def send_authorized_message
        send_message_to_user_by_id(payload[:user_id], user_info(user_id, "auth"))
      def send_authorized_message(payload)
        send_message_to_user_by_id(payload[:user_id], user_info(payload[:user_id], "auth"))
      end

      private

      def send_message_to_user_by_id(user_id, message)
        user = Lita::User.find_by_id(user_id)
        robot.send_message(Source.new(user: user), message) if user
      end

      def reset_user(user_id)
        keys = redis.keys(user_id)
        redis.del(*keys)
      end

      def save_user_info(user_id, key, data)
        redis.set("#{user_id}:#{key}", data)
      end

      def user_info(user_id, key)
        redis.get("#{user_id}:#{key}")
      end
    end

    Lita.register_handler(HarvestTracker)
  end
end
