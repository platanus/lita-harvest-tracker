require 'uri'
require 'json'
require 'slack-ruby-client'

module Lita
  module Handlers
    class HarvestTracker < Handler
      HARVEST_CLIENT_ID = ENV.fetch("HARVEST_OAUTH_CLIENT_ID")
      HARVEST_CLIENT_SECRET = ENV.fetch("HARVEST_OAUTH_CLIENT_SECRET")
      PREFIX = "harvest\s"

      route(/#{PREFIX}login/, :login, command: true)
      route(/#{PREFIX}project\slist/, :send_list_of_assignments, command: true)
      route(/#{PREFIX}start\stracking/, :start_tracking, command: true)
      route(/#{PREFIX}status/, :get_status, command: true)

      http.get "/harvest-tracker-authorize", :login_cb

      on :authorized, :send_authorized_message
      on :project_select, :tracking_cb
      on :task_select, :tracking_cb
      on :confirm_start_tracking, :confirm_start_tracking_cb

      def initialize(robot)
        super
        @slack_client = Slack::Web::Client.new
      end

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

      def send_list_of_assignments(response)
        projects = user_project_assignments(response.user.id)
        response.reply(projects.to_json)
      end

      def start_tracking(response)
        delete_user_info(response.user.id, 'selected_project')
        delete_user_info(response.user.id, 'selected_task')
        blocks = assignments_blocks(response.user.id)
        @slack_client.chat_postMessage(
          channel: response.user.id,
          as_user: true,
          blocks: blocks
        )
      end

      def assignments_blocks(user_id)
        selected_project = user_info(user_id, 'selected_project')
        selected_task = user_info(user_id, 'selected_task')
        projects = assignments_options(user_id)
        blocks = [
          text_block("*Empieza a trackear en Harvest!*"),
          divider_block,
          projects_block(projects)
        ]

        if selected_project
          tasks = task_assignments_options(user_id, selected_project)
          blocks.push(tasks_block(tasks))
        end

        if selected_task
          blocks.push(
            "type": "actions",
            "block_id": "start_tracking_button_block",
            "elements": [{
              "type": "button",
              "text": {
                "type": "plain_text",
                "text": "Empezar!"
              },
              "value": "confirm",
              "action_id": "confirm_start_tracking"
            }]
          )
        end

        blocks
      end

      def tracking_cb(payload)
        action = payload["actions"][0]
        case action["block_id"]
        when "project_select_block"
          delete_user_info(payload["user"]["id"], 'selected_task')
          selected_project = action["selected_option"]&.dig("value")
          save_user_info(payload["user"]["id"], 'selected_project', selected_project)
        when "task_select_block"
          selected_task = action["selected_option"]&.dig("value")
          save_user_info(payload["user"]["id"], 'selected_task', selected_task)
        end

        response_url = payload["response_url"]
        blocks = assignments_blocks(payload["user"]["id"])

        http.post(
          response_url,
          { blocks: blocks }.to_json
        )
      end

      def confirm_start_tracking_cb(payload)
        project_id = user_info(payload["user"]["id"], 'selected_project')
        task_id = user_info(payload["user"]["id"], 'selected_task')
        time_entry = create_time_entry(payload["user"]["id"], project_id, task_id)

        message = "Has empezado a trackear exitosamente en: "\
                  "*#{time_entry['project']['name']} (#{time_entry['task']['name']})* 👍"
        response_url = payload["response_url"]

        http.post(
          response_url,
          { blocks: [text_block(message)] }.to_json
        )
      end

      def send_authorized_message(payload)
        send_message_to_user_by_id(payload[:user_id], user_info(payload[:user_id], "auth"))
      end

      def get_status(response)
        loading_msg = send_message_to_user_by_id(response.user.id, "Obteniendo la información... ⏳")
        time_entries = time_entries(response.user.id, true)
        message = !time_entries.empty? ? time_entries.to_s : "No estás trackeando nada en estos momentos"

        @slack_client.chat_update(
          channel: loading_msg["channel"],
          ts: loading_msg["ts"],
          as_user: true,
          text: message
        )
      end

      private

      def divider_block
        {
          "type": "divider"
        }
      end

      def text_block(message)
        {
          "type": "section",
          "text": {
            "type": "mrkdwn",
            "text": message
          }
        }
      end

      def projects_block(projects)
        block = {
          "type": "section",
          "block_id": "project_select_block",
          "text": {
            "type": "mrkdwn",
            "text": "¿En qué proyecto estás trabajando?"
          },
          "accessory": {
            "type": "static_select",
            "placeholder": {
              "type": "plain_text",
              "text": "Selecciona un proyecto"
            },
            "action_id": "project_select",
            "option_groups": projects
          }
        }

        block
      end

      def tasks_block(tasks)
        block = {
          "type": "section",
          "block_id": "task_select_block",
          "text": {
            "type": "mrkdwn",
            "text": "¿Qué tipo de tarea?"
          },
          "accessory": {
            "type": "static_select",
            "placeholder": {
              "type": "plain_text",
              "text": "Selecciona una tarea"
            },
            "action_id": "task_select",
            "options": tasks
          }
        }

        block
      end

      def assignments_options(user_id)
        assignments = user_project_assignments(user_id)
        clients = {}
        assignments.each do |assignment|
          client = assignment["client"]["name"]
          clients[client] = clients[client] || []
          clients[client].push(
            "text": {
              "type": "plain_text",
              "text": assignment["project"]["name"],
              "emoji": true
            },
            "value": assignment["project"]["id"].to_s
          )
        end

        dropdown = clients.map do |client, project_options|
          {
            label: {
              type: "plain_text",
              text: client
            },
            options: project_options
          }
        end

        dropdown
      end

      def task_assignments_options(user_id, project_id)
        task_assignments = project_task_assignments(user_id, project_id)

        options = task_assignments.map do |assignment|
          {
            "text": {
              "type": "plain_text",
              "text": assignment["task"]["name"]
            },
            "value": assignment["task"]["id"].to_s
          }
        end

        options
      end

      def project_task_assignments(user_id, project_id)
        project_assignments = JSON.parse(user_info(user_id, "project_assignments_cache"))
        project = project_assignments.select do |assignment|
          assignment["project"]["id"] == project_id.to_i
        end
        if !project.empty?
          delete_user_info(user_id, "project_assignments_cache")
          project[0]["task_assignments"]
        else
          []
        end
      end

      def user_project_assignments(user_id)
        response = api_get("https://api.harvestapp.com/v2/users/me/project_assignments", user_id)
        save_user_info(user_id, "project_assignments_cache", response["project_assignments"].to_json)
        response["project_assignments"]
      end

      def create_time_entry(user_id, project_id, task_id)
        payload = {
          project_id: project_id,
          task_id: task_id,
          spent_date: Time.current.iso8601,
        }

        response = api_post("https://api.harvestapp.com/v2/time_entries", user_id, payload)
        save_user_info(user_id, "last_time_entry_cache", response.to_json)

        response
      end

      def time_entries(user_id, running = true)
        is_running_param = running ? "?is_running=#{running}" : ""
        response = api_get("https://api.harvestapp.com/v2/time_entries#{is_running_param}", user_id)
        response["time_entries"]
      end

      def send_message_to_user_by_id(user_id, message)
        user = Lita::User.find_by_id(user_id)
        robot.send_message(Source.new(user: user), message) if user
      end

      def reset_user(user_id)
        keys = redis.keys(user_id)
        redis.del(*keys)
      end

      def delete_user_info(user_id, key)
        redis.del("#{user_id}:#{key}")
      end

      def save_user_info(user_id, key, data)
        redis.set("#{user_id}:#{key}", data)
      end

      def user_info(user_id, key)
        redis.get("#{user_id}:#{key}")
      end

      def api_get(url, user_id)
        response = http.get(url) do |req|
          req.headers = http_headers(user_id)
        end

        JSON.parse(response.body)
      rescue StandardError
        send_message_to_user_by_id(user_id, "Hubo un error al obtener la información")
      end

      def api_post(url, user_id, data)
        response = http.post(url, data) do |req|
          req.headers = http_headers(user_id)
        end

        JSON.parse(response.body)
      rescue StandardError
        send_message_to_user_by_id(user_id, "Hubo un error al enviar la información")
      end

      def http_headers(user_id)
        auth = JSON.parse(user_info(user_id, "auth"))
        harvest_account_id = user_info(user_id, "scope").delete_prefix("harvest:")
        http_headers = {
          "Authorization": "Bearer #{auth['access_token']}",
          "Harvest-Account-Id": harvest_account_id,
          "User-Agent": "Harvest Ham (guillermo@platan.us)"
        }

        http_headers
      end
    end

    Lita.register_handler(HarvestTracker)
  end
end
