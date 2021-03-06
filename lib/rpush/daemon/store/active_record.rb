require 'active_record'

require 'rpush/daemon/store/active_record/reconnectable'

module Rpush
  module Daemon
    module Store
      class ActiveRecord
        include Reconnectable

        DEFAULT_MARK_OPTIONS = { persist: true }

        def app(id)
          Rpush::Client::ActiveRecord::App.find(id)
        end

        def all_apps
          Rpush::Client::ActiveRecord::App.all
        end

        def deliverable_notifications(limit)
          with_database_reconnect_and_retry do
            relation = ready_for_delivery
            relation = relation.limit(limit) unless Rpush.config.push
            relation.to_a
          end
        end

        def mark_retryable(notification, deliver_after, opts = {})
          opts = DEFAULT_MARK_OPTIONS.dup.merge(opts)
          notification.retries += 1
          notification.deliver_after = deliver_after

          return unless opts[:persist]

          with_database_reconnect_and_retry do
            notification.save!(validate: false)
          end
        end

        def mark_batch_retryable(notifications, deliver_after)
          ids = []
          notifications.each do |n|
            mark_retryable(n, deliver_after, persist: false)
            ids << n.id
          end
          mark_ids_retryable(ids, deliver_after)
        end

        def mark_ids_retryable(ids, deliver_after)
          with_database_reconnect_and_retry do
            Rpush::Client::ActiveRecord::Notification.where(id: ids).update_all(['delivered = ?, delivered_at = ?, failed = ?, failed_at = ?, retries = retries + 1, deliver_after = ?', false, nil, false, nil, deliver_after])
          end
        end

        def mark_delivered(notification, time, opts = {})
          opts = DEFAULT_MARK_OPTIONS.dup.merge(opts)
          notification.delivered = true
          notification.delivered_at = time

          return unless opts[:persist]

          with_database_reconnect_and_retry do
            notification.save!(validate: false)
          end
        end

        def mark_batch_delivered(notifications)
          now = Time.now
          ids = []
          notifications.each do |n|
            mark_delivered(n, now, persist: false)
            ids << n.id
          end
          with_database_reconnect_and_retry do
            Rpush::Client::ActiveRecord::Notification.where(id: ids).update_all(['delivered = ?, delivered_at = ?', true, now])
          end
        end

        def mark_failed(notification, code, description, time, opts = {})
          opts = DEFAULT_MARK_OPTIONS.dup.merge(opts)
          notification.delivered = false
          notification.delivered_at = nil
          notification.failed = true
          notification.failed_at = time
          notification.error_code = code
          notification.error_description = description

          return unless opts[:persist]

          with_database_reconnect_and_retry do
            notification.save!(validate: false)
          end
        end

        def mark_batch_failed(notifications, code, description)
          now = Time.now
          ids = []
          notifications.each do |n|
            mark_failed(n, code, description, now, persist: false)
            ids << n.id
          end
          mark_ids_failed(ids, code, description, now)
        end

        def mark_ids_failed(ids, code, description, time)
          with_database_reconnect_and_retry do
            Rpush::Client::ActiveRecord::Notification.where(id: ids).update_all(['delivered = ?, delivered_at = NULL, failed = ?, failed_at = ?, error_code = ?, error_description = ?', false, true, time, code, description])
          end
        end

        def create_apns_feedback(failed_at, device_token, app)
          with_database_reconnect_and_retry do
            Rpush::Client::ActiveRecord::Apns::Feedback.create!(failed_at: failed_at,
                                                                device_token: device_token, app: app)
          end
        end

        def create_gcm_notification(attrs, data, registration_ids, deliver_after, app)
          notification = Rpush::Client::ActiveRecord::Gcm::Notification.new
          create_gcm_like_notification(notification, attrs, data, registration_ids, deliver_after, app)
        end

        def create_adm_notification(attrs, data, registration_ids, deliver_after, app)
          notification = Rpush::Client::ActiveRecord::Adm::Notification.new
          create_gcm_like_notification(notification, attrs, data, registration_ids, deliver_after, app)
        end

        def update_app(app)
          with_database_reconnect_and_retry do
            app.save!
          end
        end

        def update_notification(notification)
          with_database_reconnect_and_retry do
            notification.save!
          end
        end

        def release_connection
          ::ActiveRecord::Base.connection_pool.release_connection
        rescue StandardError => e
          Rpush.logger.error(e)
        end

        private

        def create_gcm_like_notification(notification, attrs, data, registration_ids, deliver_after, app) # rubocop:disable ParameterLists
          with_database_reconnect_and_retry do
            notification.assign_attributes(attrs)
            notification.data = data
            notification.registration_ids = registration_ids
            notification.deliver_after = deliver_after
            notification.app = app
            notification.save!
            notification
          end
        end

        def ready_for_delivery
          Rpush::Client::ActiveRecord::Notification.where('delivered = ? AND failed = ? AND (deliver_after IS NULL OR deliver_after < ?)', false, false, Time.now)
        end
      end
    end
  end
end

Rpush::Daemon::Store::Interface.check(Rpush::Daemon::Store::ActiveRecord)
