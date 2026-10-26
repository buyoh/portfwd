class App
  class NodeProcessObserver
    # tries (a few seconds each at most) until a port of check_tcps is connected to
    CONNECTION_TRY_COUNT = 10

    def initialize(logger, platform, host, check_tcps)
      @logger = logger
      @platform = platform
      @host = host
      @check_tcps = check_tcps
      @pid = nil
    end

    attr_reader :host

    def initialized?
      !@pid.nil?
    end

    def launch_blocking(ssh_config_filepath)
      @pid = @platform.start_child_process_ssh(@host, ssh_config_filepath)
      unless @pid
        @logger.error("Failed to launch node: #{@host}")
        return false
      end

      check_tcp = failed_check_tcp
      if check_tcp
        @logger.error("Failed to connect to #{check_tcp[:host]}:#{check_tcp[:port]} of #{@host}")
        @platform.kill_child_process(@pid)
        @pid = nil
        return false
      end

      true
    end

    def terminate
      return unless @pid

      @platform.kill_child_process(@pid) if @platform.child_process_alive?(@pid)
    ensure
      @pid = nil
    end

    # Returns the first check_tcp which cannot be connected to, or nil if all of them can
    def failed_check_tcp
      @check_tcps.find do |check_tcp|
        !@platform.wait_tcp_port_is_open(check_tcp[:host], check_tcp[:port], @pid, CONNECTION_TRY_COUNT)
      end
    end

    def alive?
      return false unless @pid

      @platform.child_process_alive?(@pid)
    end
  end

  Config = Struct.new(:check_connection_interval_sec, :terminate_sleep_sec, keyword_init: true) do
    # Build a validated Config from any object which responds to the attributes.
    # Raises ArgumentError for missing or invalid values.
    def self.from(config)
      values = members.to_h do |name|
        raise ArgumentError, "config must respond to #{name}" unless config.respond_to?(name)

        [name, config.public_send(name)]
      end
      new(**values).tap(&:validate!)
    end

    def validate!
      unless finite_number?(check_connection_interval_sec) && check_connection_interval_sec.positive?
        raise ArgumentError, "check_connection_interval_sec must be a positive number: #{check_connection_interval_sec.inspect}"
      end
      unless finite_number?(terminate_sleep_sec) && !terminate_sleep_sec.negative?
        raise ArgumentError, "terminate_sleep_sec must be a non-negative number: #{terminate_sleep_sec.inspect}"
      end

      self
    end

    private

    def finite_number?(value)
      value.is_a?(Numeric) && value.finite?
    end
  end

  DEFAULT_CONFIG = Config.new(check_connection_interval_sec: 30, terminate_sleep_sec: 10).freeze

  def initialize(logger, platform)
    @logger = logger
    @platform = platform
    @running = false
    @failed = false
    @app_thread = nil
    @config = DEFAULT_CONFIG
  end

  attr_reader :config

  # Raises ArgumentError if the config is invalid. The current config is kept in that case.
  def update_config(config)
    @config = Config.from(config).freeze
  end

  def running?
    @running
  end

  def failed?
    @failed
  end

  def start(ssh_config_dir, node_manager)
    if @running
      @logger.error('Already running')
      return false
    end

    @running = true
    @failed = false

    ssh_config_filepath = File.join(ssh_config_dir, 'config')

    sorted_nodes = node_manager.validate_nodes
    unless sorted_nodes
      @logger.error('Failed to validate nodes')

      @running = false
      return false
    end

    @app_thread = start_app_thread(sorted_nodes, ssh_config_filepath)

    @logger.info('App thread started')

    true
  end

  def terminate
    @running = false
    return unless @app_thread

    @logger.info('Terminating app thread')
    begin
      @app_thread.wakeup if @app_thread.alive?
      @app_thread.join
    rescue ThreadError => e
      # dead thread?
      @logger.error("Failed to terminate app thread: #{e}")
    end
    @app_thread = nil
  end

  private

  def start_app_thread(sorted_nodes, ssh_config_filepath)
    Thread.new do
      observers = nil
      completed = false
      begin
        while @running
          @logger.info('Start launching nodes')

          # TODO: 部分的に再起動するようにする
          observers = launch_all_nodes_blocking(sorted_nodes, ssh_config_filepath)
          unless observers
            @logger.error('Failed to launch nodes')
            @failed = true
            break
          end

          @logger.info('Launched all nodes')

          while @running
            sleep @config.check_connection_interval_sec

            unless all_nodes_alive?(observers)
              @logger.info('Detected a node is down')
              break
            end
          end

          @logger.info('Restarting nodes')
          terminate_observers(observers)
          observers = nil

          sleep @config.terminate_sleep_sec if @running
        end
        completed = true
      rescue StandardError => e
        @logger.error("App thread crashed: #{e.class}: #{e.message}")
        @logger.error(e.backtrace.join("\n")) if e.backtrace
      ensure
        @running = false
        # also treat termination by non-StandardError (e.g. Thread#kill) as failure
        @failed = true unless completed
        terminate_observers(observers) if observers
        @logger.info('Terminated')
      end
    end
  end

  def terminate_observers(observers)
    observers.each do |observer|
      observer.terminate
    rescue StandardError => e
      @logger.error("Failed to terminate observer: #{e.class}: #{e.message}")
    end
  end

  def launch_all_nodes_blocking(sorted_nodes, ssh_config_filepath)
    failed = false
    observers = []
    begin
      sorted_nodes.each do |node|
        observer = NodeProcessObserver.new(@logger, @platform, node.host, node.info[:check_tcps])

        observers.push(observer)

        unless observer.launch_blocking(ssh_config_filepath)
          failed = true
          break
        end
      end
    rescue StandardError
      terminate_observers(observers)
      raise
    end

    if failed
      terminate_observers(observers)
      return nil
    end
    observers
  end

  def all_nodes_alive?(observers)
    observers.all? do |observer|
      unless observer.alive?
        @logger.info("Process of #{observer.host} is not alive")
        next false
      end

      check_tcp = observer.failed_check_tcp
      if check_tcp
        @logger.info("Failed to connect to #{check_tcp[:host]}:#{check_tcp[:port]} of #{observer.host}")
        next false
      end
      true
    end
  end
end
