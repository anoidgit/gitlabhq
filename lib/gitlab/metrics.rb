require 'prometheus/client'

module Gitlab
  module Metrics
    extend Gitlab::CurrentSettings

    RAILS_ROOT   = Rails.root.to_s
    METRICS_ROOT = Rails.root.join('lib', 'gitlab', 'metrics').to_s
    PATH_REGEX   = /^#{RAILS_ROOT}\/?/

    def self.settings
      @settings ||= {
        enabled:                    current_application_settings[:metrics_enabled],
        prometheus_metrics_enabled: current_application_settings[:prometheus_metrics_enabled],
        pool_size:                  current_application_settings[:metrics_pool_size],
        timeout:                    current_application_settings[:metrics_timeout],
        method_call_threshold:      current_application_settings[:metrics_method_call_threshold],
        host:                       current_application_settings[:metrics_host],
        port:                       current_application_settings[:metrics_port],
        sample_interval:            current_application_settings[:metrics_sample_interval] || 15,
        packet_size:                current_application_settings[:metrics_packet_size] || 1
      }
    end

    def self.prometheus_metrics_enabled?
      settings[:prometheus_metrics_enabled] || false
    end

    def self.influx_metrics_enabled?
      settings[:enabled] || false
    end

    def self.enabled?
      influx_metrics_enabled? || prometheus_metrics_enabled?
    end

    def self.mri?
      RUBY_ENGINE == 'ruby'
    end

    def self.method_call_threshold
      # This is memoized since this method is called for every instrumented
      # method. Loading data from an external cache on every method call slows
      # things down too much.
      @method_call_threshold ||= settings[:method_call_threshold]
    end

    def self.pool
      @pool
    end

    def self.registry
      @registry ||= ::Prometheus::Client.registry
    end

    def self.counter(name, docstring, base_labels = {})
      provide_metric(name) || registry.counter(name, docstring, base_labels)
    end

    def self.summary(name, docstring, base_labels = {})
      provide_metric(name) || registry.summary(name, docstring, base_labels)
    end

    def self.gauge(name, docstring, base_labels = {})
      provide_metric(name) || registry.gauge(name, docstring, base_labels)
    end

    def self.histogram(name, docstring, base_labels = {}, buckets = ::Prometheus::Client::Histogram::DEFAULT_BUCKETS)
      provide_metric(name) || registry.histogram(name, docstring, base_labels, buckets)
    end

    def self.provide_metric(name)
      if prometheus_metrics_enabled?
        registry.get(name)
      else
        DummyMetric.new
      end
    end

    def self.submit_metrics(metrics)
      prepared = prepare_metrics(metrics)

      pool&.with do |connection|
        prepared.each_slice(settings[:packet_size]) do |slice|
          begin
            connection.write_points(slice)
          rescue StandardError
          end
        end
      end
    rescue Errno::EADDRNOTAVAIL, SocketError => ex
      Gitlab::EnvironmentLogger.error('Cannot resolve InfluxDB address. GitLab Performance Monitoring will not work.')
      Gitlab::EnvironmentLogger.error(ex)
    end

    def self.prepare_metrics(metrics)
      metrics.map do |hash|
        new_hash = hash.symbolize_keys

        new_hash[:tags].each do |key, value|
          if value.blank?
            new_hash[:tags].delete(key)
          else
            new_hash[:tags][key] = escape_value(value)
          end
        end

        new_hash
      end
    end

    def self.escape_value(value)
      value.to_s.gsub('=', '\\=')
    end

    # Measures the execution time of a block.
    #
    # Example:
    #
    #     Gitlab::Metrics.measure(:find_by_username_duration) do
    #       User.find_by_username(some_username)
    #     end
    #
    # name - The name of the field to store the execution time in.
    #
    # Returns the value yielded by the supplied block.
    def self.measure(name)
      trans = current_transaction

      return yield unless trans

      real_start = Time.now.to_f
      cpu_start = System.cpu_time

      retval = yield

      cpu_stop = System.cpu_time
      real_stop = Time.now.to_f

      real_time = (real_stop - real_start) * 1000.0
      cpu_time = cpu_stop - cpu_start

      trans.increment("#{name}_real_time", real_time)
      trans.increment("#{name}_cpu_time", cpu_time)
      trans.increment("#{name}_call_count", 1)

      retval
    end

    # Adds a tag to the current transaction (if any)
    #
    # name - The name of the tag to add.
    # value - The value of the tag.
    def self.tag_transaction(name, value)
      trans = current_transaction

      trans&.add_tag(name, value)
    end

    # Sets the action of the current transaction (if any)
    #
    # action - The name of the action.
    def self.action=(action)
      trans = current_transaction

      trans&.action = action
    end

    # Tracks an event.
    #
    # See `Gitlab::Metrics::Transaction#add_event` for more details.
    def self.add_event(*args)
      trans = current_transaction

      trans&.add_event(*args)
    end

    # Returns the prefix to use for the name of a series.
    def self.series_prefix
      @series_prefix ||= Sidekiq.server? ? 'sidekiq_' : 'rails_'
    end

    # Allow access from other metrics related middlewares
    def self.current_transaction
      Transaction.current
    end

    # When enabled this should be set before being used as the usual pattern
    # "@foo ||= bar" is _not_ thread-safe.
    if influx_metrics_enabled?
      @pool = ConnectionPool.new(size: settings[:pool_size], timeout: settings[:timeout]) do
        host = settings[:host]
        port = settings[:port]

        InfluxDB::Client.
          new(udp: { host: host, port: port })
      end
    end
  end
end
