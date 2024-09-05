class App
  class NodeProcessObserver
    def initialize(logger, platform, host, check_tcps)
      @logger = logger
      @platform = platform
      @host = host
      @check_tcps = check_tcps
      @pid = nil
    end

    def initialized?
      !@pid.nil?
    end

    def launch_blocking(ssh_config_filepath)
      @pid = @platform.start_child_process_ssh(@host, ssh_config_filepath)
      unless @pid
        @logger.error("Failed to launch node: #{@host}")
        return false
      end

      wait_ok, check_tcp = wait_connection
      unless wait_ok
        @logger.error("Failed to connect to #{check_tcp[:host]}:#{check_tcp[:port]}")
        @platform.kill_child_process(@pid)
        @pid = nil
        return false
      end

      true
    end

    def terminate
      return unless @pid

      unless @platform.is_alive_child_process(@pid)
        @pid = nil
        return
      end

      @platform.kill_child_process(@pid)
      @pid = nil
    end

    def wait_connection
      @check_tcps.each do |check_tcp|
        tcp_host = check_tcp[:host]
        tcp_port = check_tcp[:port]
        try_count = 10
        return [false, check_tcp] unless @platform.wait_tcp_port_is_open(tcp_host, tcp_port, @pid, try_count)
      end
      [true, nil]
    end

    def check_connection
      @check_tcps.each do |check_tcp|
        tcp_host = check_tcp[:host]
        tcp_port = check_tcp[:port]
        return [false, check_tcp] unless @platform.wait_tcp_port_is_open(tcp_host, tcp_port, @pid)
      end
      [true, nil]
    end

    def is_alive_child_process
      return false unless @pid

      @platform.is_alive_child_process(@pid)
    end
  end

  def initialize(logger, platform)
    @logger = logger
    @platform = platform
    @running = false
    @app_thread = nil
    @config = Struct.new(
      :check_connection_interval_sec,
      :terminate_sleep_sec
    ).new(30, 10)
  end

  def update_config(config)
    @config = config
  end

  def running?
    @running
  end

  def start(ssh_config_dir, node_manager)
    if @running
      @logger.error('Already running')
      return false
    end

    @running = true

    ssh_config_filepath = File.join(ssh_config_dir, 'config')

    sorted_nodes = node_manager.vaidate_nodes
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
      @app_thread.run
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
      while @running
        @logger.info('Start launching nodes')

        # TODO: 部分的に再起動するようにする
        observers = launch_all_nodes_blocking(sorted_nodes, ssh_config_filepath)
        unless observers
          @logger.error('Failed to launch nodes')
          break
        end

        @logger.info('Launched all nodes')

        while @running
          sleep @config.check_connection_interval_sec

          unless are_all_nodes_connection_alive?(observers)
            @logger.info('Detected a node is down')
            break
          end
        end

        @logger.info('Restarting nodes')
        observers.each(&:terminate)

        sleep @config.terminate_sleep_sec if @running
      end
      @running = false
      @logger.info('Terminated')
    end
  end

  def launch_all_nodes_blocking(sorted_nodes, ssh_config_filepath)
    failed = false
    observers = []
    sorted_nodes.each do |node|
      observer = NodeProcessObserver.new(@logger, @platform, node.host, node.info[:check_tcps])

      observers.push(observer)

      unless observer.launch_blocking(ssh_config_filepath)
        failed = true
        break
      end
    end

    if failed
      observers.each(&:terminate)
      return nil
    end
    observers
  end

  def are_all_nodes_connection_alive?(observers)
    observers.all? { |observer| observer.is_alive_child_process && observer.check_connection }
  end

  def launch_node_blocking(info, ssh_config_filepath)
    host = info[:host]
    pid = @platform.start_child_process_ssh(host, ssh_config_filepath)

    if info[:check_tcps].any? { |check_tcp| !@platform.wait_tcp_port_is_open(check_tcp[:host], check_tcp[:port], pid) }
      # failed
      @platform.kill_child_process(pid)
      return nil
    end
    pid
  end
end
