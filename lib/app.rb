class App
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

    pids = []
    sorted_nodes.each do |node|
      pid = launch_node_blocking(@platform, node.info, ssh_config_filepath)
      next if pid

      @logger.error("Failed to launch node: #{node.host}")
      # kill all
      pids.each do |pid|
        @platform.kill_child_process(pid)
      end
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
