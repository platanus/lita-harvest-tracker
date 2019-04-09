require 'uri'
require 'json'
require 'slack-ruby-client'
require 'time'
require 'ostruct'
require 'active_support/all'

module Lita
  module Handlers
    class HarvestTracker < Handler
      HARVEST_CLIENT_ID = ENV.fetch("HARVEST_OAUTH_CLIENT_ID")
      HARVEST_CLIENT_SECRET = ENV.fetch("HARVEST_OAUTH_CLIENT_SECRET")
      PREFIX = "harvest\s"

      route(/#{PREFIX}setup/, :setup, command: true)
      route(/#{PREFIX}logout/, :logout, command: true)
      route(/#{PREFIX}project\slist/, :send_list_of_assignments, command: true)
      route(/#{PREFIX}start\stracking/, :start_tracking, command: true)
      route(/#{PREFIX}status/, :get_status, command: true)

      http.get "/harvest-tracker-authorize", :login_cb

      on :authorized, :authorized_cb
      on :start_tracking, :start_tracking
      on :project_select, :tracking_cb
      on :task_select, :tracking_cb
      on :confirm_start_tracking, :confirm_start_tracking_cb
      on :time_entry_stop, :time_entry_stop_cb
      on :start_setup_dialog, :start_setup_dialog_cb
      on :setup_dialog, :setup_dialog_cb
      on :time_entry_continue_button, :time_entry_continue_button_cb
      on :loaded, :setup_timers

      def initialize(robot)
        super
        @slack_client = Slack::Web::Client.new
      end

      def setup_timers(_payload)
        redis.keys('*:reminder_minutes').each do |key|
          user_id = key.split(':').first
          minutes = user_info(user_id, "reminder_minutes") || "0"
          reminder_id = user_info(user_id, "reminder_id")
          create_timer(user_id, minutes.to_i, reminder_id)
        end

        redis.keys('*:auth').each do |key|
          user_id = key.split(':').first
          check_login(user_id) if !user_id.empty?
        end
      end

      def create_timer(user_id, minutes, reminder_id)
        return if minutes == "0"

        reminder_if_tracking = user_info(user_id, "reminder_if_tracking") == "si"
        reminder_start = user_info(user_id, "reminder_start")
        reminder_end = user_info(user_id, "reminder_end")
        minutes = minutes.to_i < 5 ? 5 : minutes.to_i

        time_zone = ActiveSupport::TimeZone.new(slack_timezone(user_id))

        every(minutes * 60) do |timer|
          if user_info(user_id, "reminder_id") != reminder_id || !user_info(user_id, "auth")
            timer.stop
          end
          next if !reminder_if_tracking && tracking?(user_id)
          next if time_zone.now.saturday? || time_zone.now.sunday?

          time_start = time_zone.parse(time_zone.now.strftime('%Y-%m-%d ' + reminder_start))
          time_end = time_zone.parse(time_zone.now.strftime('%Y-%m-%d ' + reminder_end))

          status(user_id) if time_start.past? && time_end.future?
        end
      end

      def check_login(user_id)
        auth = JSON.parse(user_info(user_id, "auth"))
        logged_in_date = Time.parse(user_info(user_id, "logged_in_date"))
        future = logged_in_date + auth["expires_in"]

        every(6 * 60 * 60) do
          if (Time.current - future) < 3 * 60 * 60 * 24
            refresh_access_token(user_id, auth["refresh_token"])
          end
        end
      end

      def setup(response)
        init_harvest(response.user.id)
      end

      def init_harvest(user_id)
        if user_info(user_id, "auth")
          send_setup_button(user_id)
        else
          send_login_button(user_id)
        end
      end

      def logout(response)
        reset_user(response.user.id)
        send_message_to_user_by_id(response.user.id, "Se ha cerrado tu sesión.")
      end

      def send_login_button(user_id)
        state = {
          uuid: SecureRandom.uuid
        }
        redis.set(state[:uuid], user_id)
        url = "https://id.getharvest.com/oauth2/authorize?client_id=#{HARVEST_CLIENT_ID}&response_type=code&state=#{state.to_json}"

        response = @slack_client.chat_postMessage(
          channel: user_id,
          as_user: true,
          blocks: [
            {
              "type": "actions",
              "elements": [
                {
                  "type": "button",
                  "text": {
                    "type": "plain_text",
                    "text": "Iniciar Sesión con Harvest"
                  },
                  "url": url
                }
              ]
            }
          ]
        )

        save_user_info(user_id, "login_button_message_id", response["message"]["ts"])
      end

      def update_message_by_id(user_id, msg_id, message)
        im = @slack_client.im_open(
          user: user_id
        )

        @slack_client.chat_update(
          text: message,
          channel: im["channel"]["id"],
          as_user: true,
          ts: msg_id,
          blocks: []
        )
      end

      def login_cb(request, response)
        state = JSON.parse(request.params["state"])
        user_id = redis.get(state["uuid"])
        redis.del(state["uuid"])
        save_user_info(user_id, "scope", request.params["scope"])
        get_access_token(user_id, request.params["code"])
        response.body << "Autenticacion realizada."
      rescue StandardError
        response.body << "Hubo un error con la autenticacion, intentalo nuevamente"
      end

      def get_access_token(user_id, code)
        body = "code=#{code}&"\
                "client_id=#{HARVEST_CLIENT_ID}&"\
                "client_secret=#{HARVEST_CLIENT_SECRET}&"\
                "grant_type=authorization_code"
        response = http.post("https://id.getharvest.com/api/v2/oauth2/token", body)
        json = JSON.parse(response.body)
        if json["error"]
          update_login_button(user_id, "Error al hacer login, inténtalo de nuevo")
          reset_user(user_id)
          raise "Auth Error: #{json['error']}"
        else
          save_user_info(user_id, "auth", response.body)
          save_user_info(user_id, "logged_in_date", Time.current)
          robot.trigger(:authorized, user_id: user_id)
        end
      end

      def refresh_access_token(user_id, refresh_token)
        body = "client_id=#{HARVEST_CLIENT_ID}&"\
        "client_secret=#{HARVEST_CLIENT_SECRET}&"\
        "refresh_token=#{refresh_token}&"\
        "grant_type=refresh_token"

        response = http.post("https://id.getharvest.com/api/v2/oauth2/token", body)
        json = JSON.parse(response.body)

        if json["error"]
          send_message_to_user_by_id(
            user_id,
            "Error al refrescar tu token, por favor ingresa de nuevo"
          )
          reset_user(user_id)
        end
      end

      def authorized_cb(payload)
        user_id = payload[:user_id]
        update_message_by_id(
          user_id,
          user_info(user_id, "login_button_message_id"),
          "Sesión iniciada ✅"
        )
        delete_user_info(user_id, 'login_button_message_id')

        init_harvest(user_id)
      end

      def send_setup_button(user_id)
        response = @slack_client.chat_postMessage(
          channel: user_id,
          as_user: true,
          blocks: [
            {
              "type": "actions",
              "elements": [
                {
                  "type": "button",
                  "text": {
                    "type": "plain_text",
                    "text": "Configurar Harvest"
                  },
                  "value": "true",
                  "action_id": "start_setup_dialog"
                }
              ]
            }
          ]
        )

        save_user_info(user_id, "setup_button_message_id", response["message"]["ts"])
      end

      def start_setup_dialog_cb(payload)
        user_id = payload["user"]["id"]
        reminder_minutes = user_info(user_id, "reminder_minutes") || 60
        reminder_start = user_info(user_id, "reminder_start") || '09:00'
        reminder_end = user_info(user_id, "reminder_end") || '18:00'
        reminder_if_tracking = user_info(user_id, "reminder_if_tracking") || 'no'

        time_zone = ActiveSupport::TimeZone.new(slack_timezone(user_id))
        local_time = time_zone

        @slack_client.dialog_open(
          trigger_id: payload["trigger_id"],
          dialog: {
            callback_id: "setup_dialog",
            title: "Configuración",
            submit_label: "Enviar",
            elements: [
              {
                type: "text",
                label: "¿Cada cuántos minutos te debería recordar?",
                subtype: "number",
                name: "reminder_minutes",
                value: reminder_minutes,
                hint: "Usa 0 para desactivar el recordatorio. 5 minutos como mínimo."
              },
              {
                type: "text",
                label: "¿Desde qué hora te debería empezar a recordar?",
                value: reminder_start,
                name: "reminder_start",
                hint: "Zona horaria: #{time_zone.name} (#{time_zone.now.strftime('%H:%M')}). "\
                      "Puedes cambiarla en la configuración de Slack"
              },
              {
                type: "text",
                label: "¿A qué hora te debería dejar de recordar?",
                value: reminder_end,
                name: "reminder_end",
                hint: "Zona horaria: #{time_zone.name} (#{time_zone.now.strftime('%H:%M')}). "\
                      "Puedes cambiarla en la configuración de Slack"
              },
              {
                type: "select",
                label: "¿Te debería recordar si ya estás trackeando?",
                name: "reminder_if_tracking",
                value: reminder_if_tracking,
                options: [
                  {
                    "label": "Si",
                    "value": "si"
                  },
                  {
                    "label": "No",
                    "value": "no"
                  }
                ]
              }
            ]
          }
        )
      end

      def setup_dialog_cb(payload)
        user_id = payload["user"]["id"]
        submission = payload["submission"]
        reminder_id = SecureRandom.uuid
        if submission["reminder_start"].to_i > submission["reminder_end"].to_i
          send_message_to_user_by_id(
            user_id,
            "La hora de inicio no puede ser menor que la hora de termino. Inténtalo de nuevo."
          )

          return
        end

        save_user_info(user_id, "reminder_minutes", submission["reminder_minutes"])
        save_user_info(user_id, "reminder_start", submission["reminder_start"])
        save_user_info(user_id, "reminder_end", submission["reminder_end"])
        save_user_info(user_id, "reminder_if_tracking", submission["reminder_if_tracking"])
        save_user_info(user_id, "reminder_id", reminder_id)
        update_message_by_id(
          user_id,
          user_info(user_id, "setup_button_message_id"),
          "Harvest configurado ✅"
        )

        create_timer(user_id, submission["reminder_minutes"].to_i, reminder_id)

        delete_user_info(user_id, 'setup_button_message_id')
      end

      def send_list_of_assignments(response)
        projects = user_project_assignments(response.user.id)
        response.reply(projects.to_json)
      end

      def start_tracking(response)
        payload = OpenStruct.new(response)
        user_id = payload["user"]["id"]

        start_tracking_cb(user_id)
      end

      def start_tracking_cb(user_id)
        delete_user_info(user_id, 'selected_project')
        delete_user_info(user_id, 'selected_task')
        blocks = assignments_blocks(user_id)
        @slack_client.chat_postMessage(
          channel: user_id,
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
            "block_id": "confirm_start_tracking_block",
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
                  "*#{time_entry['client']['name']} - #{time_entry['project']['name']} "\
                  "(#{time_entry['task']['name']})* 👍"
        response_url = payload["response_url"]

        http.post(
          response_url,
          { blocks: [text_block(message)] }.to_json
        )
      end

      def time_entry_stop_cb(payload)
        action = payload["actions"][0]
        stop_time_entry(payload["user"]["id"], action["value"])

        status(payload["user"]["id"], "ts": payload["message"]["ts"], "channel": payload["channel"]["id"])
      end

      def get_status(response)
        status(response.user.id)
      end

      def status(user_id, msg = nil)
        loading_msg = send_message_to_user_by_id(user_id, "Obteniendo la información... ⏳") unless msg
        time_entries = time_entries(user_id)
        blocks = []

        if time_entries.empty?
          last_time_entries = time_entries(user_id, false)
          blocks.push(
            text_block("*No estás trackeando nada en este momento...*"),
            start_tracking_button_block,
            *time_entries_blocks(last_time_entries)
          )
        else
          blocks.push(text_block("*Estás trackeando...*"), *time_entries_blocks(time_entries))
        end

        @slack_client.chat_update(
          channel: msg&.dig(:channel) || loading_msg["channel"],
          ts: msg&.dig(:ts) || loading_msg["ts"],
          as_user: true,
          blocks: blocks
        )
      end

      def time_entry_continue_button_cb(payload)
        value = JSON.parse(payload["actions"][0]["value"])
        task_id = value["task_id"]
        project_id = value["project_id"]

        time_entry = create_time_entry(payload["user"]["id"], project_id, task_id)

        message = "Has empezado a trackear exitosamente en: "\
                  "*#{time_entry['client']['name']} - #{time_entry['project']['name']} "\
                  "(#{time_entry['task']['name']})* 👍"
        response_url = payload["response_url"]

        http.post(
          response_url,
          { blocks: [text_block(message)] }.to_json
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

      def time_entries_blocks(time_entries, limit = 5)
        time_entries.first(limit).map do |time_entry|
          accessory = if time_entry["is_running"]
                        {
                          "type": "button",
                          "text": {
                            "type": "plain_text",
                            "text": "Detener"
                          },
                          "action_id": "time_entry_stop",
                          "value": time_entry["id"].to_s
                        }
                      else
                        {
                          "type": "button",
                          "text": {
                            "type": "plain_text",
                            "text": "Continuar"
                          },
                          "action_id": "time_entry_continue_button",
                          "value": {
                            task_id: time_entry["task"]["id"].to_s,
                            project_id: time_entry["project"]["id"].to_s
                          }.to_json
                        }
                      end

          {
            "type": "section",
            "text": {
              "type": "mrkdwn",
              "text": "#{time_entry['client']['name']} - #{time_entry['project']['name']} " \
              "(#{time_entry['task']['name']}) - #{time_entry['hours']} Horas"
            },
            "accessory": accessory
          }
        end
      end

      def start_tracking_button_block
        {
          "type": "actions",
          "block_id": "start_tracking_button_block",
          "elements": [{
            "type": "button",
            "text": {
              "type": "plain_text",
              "text": "Empezar a trackear"
            },
            "value": "confirm",
            "action_id": "start_tracking"
          }]
        }
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
          spent_date: Time.current.iso8601
        }

        response = api_post("https://api.harvestapp.com/v2/time_entries", user_id, payload)
        save_user_info(user_id, "last_time_entry_cache", response.to_json)

        response
      end

      def stop_time_entry(user_id, time_entry_id)
        api_patch("https://api.harvestapp.com/v2/time_entries/#{time_entry_id}/stop", user_id)
      end

      def time_entries(user_id, running = true, per_page = 5)
        params = running ? "?is_running=#{running}&per_page=#{per_page}" : "?per_page=#{per_page}"
        response = api_get("https://api.harvestapp.com/v2/time_entries#{params}", user_id)
        response["time_entries"]
      end

      def tracking?(user_id)
        !time_entries(user_id).empty?
      end

      def send_message_to_user_by_id(user_id, message)
        user = Lita::User.find_by_id(user_id)
        robot.send_message(Source.new(user: user), message) if user
      end

      def reset_user(user_id)
        keys = redis.keys(user_id + '*')
        redis.del(*keys) unless keys.empty?
      end

      def delete_user_info(user_id, key)
        redis.del("#{user_id}:#{key}") if user_id
      end

      def save_user_info(user_id, key, data)
        redis.set("#{user_id}:#{key}", data) if user_id
      end

      def user_info(user_id, key)
        redis.get("#{user_id}:#{key}") if user_id
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

      def api_patch(url, user_id)
        response = http.patch(url) do |req|
          req.headers = http_headers(user_id)
        end

        JSON.parse(response.body)
      rescue StandardError
        send_message_to_user_by_id(user_id, "Hubo un error al obtener la información")
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

      def slack_timezone(user_id)
        response = @slack_client.users_info(
          user: user_id
        )

        response["user"]["tz"]
      end
    end

    Lita.register_handler(HarvestTracker)
  end
end
