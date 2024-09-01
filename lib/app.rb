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

    def launch_blocking
      @pid = @platform.start_child_process_ssh(@host)
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

      @platform.kill_child_process(@pid)
      @pid = nil
    end

    def wait_connection
      @check_tcps.each do |check_tcp|
        tcp_host = check_tcp[:host]
        tcp_port = check_tcp[:port]
        try_count = 10
        unless @platform.wait_tcp_port_is_open(tcp_host, tcp_port, @pid, try_count)
          @logger.error("Failed to connect to #{tcp_host}:#{tcp_port}")
          return false
        end
      end
      true
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
  end

  def start(ssh_config_dir, node_manager)
    ssh_config_filepath = File.join(ssh_config_dir, 'config')

    sorted_nodes = node_manager.vaidate_nodes
    unless sorted_nodes
      @logger.error('Failed to validate nodes')
      return false
    end

    failed = false
    observers = []
    sorted_nodes.each do |node|
      observer = NodeProcessObserver.new(@logger, @platform, node.host, node.info[:check_tcps])

      observers.push(observer)

      unless observer.launch_blocking
        failed = true
        break
      end
    end

    if failed
      observers.each(&:terminate)
      return false
    end

    true
  end

  private

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
