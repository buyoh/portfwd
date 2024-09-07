require 'socket'
require 'timeout'

class PlatformImpl
  def initialize(logger)
    @logger = logger
  end

  def terminate
    # do nothing
  end

  def add_ssh_host_to_tcp_host_for_test(ssh_host, tcp_ip, tcp_port)
    # do nothing
  end

  def wait_tcp_port_is_open(ip, port, pid, trycount = 10)
    @logger.debug("wait_tcp_port_is_open ip=#{ip}, port=#{port}")
    trycount.times do |_i|
      return true if check_pid_and_tcp_port_is_open(ip, port, pid)

      sleep 1
    end
    false
  end

  def start_child_process_ssh(host, ssh_config_filepath)
    @logger.debug("start_child_process_ssh host=#{host}")
    spawn('ssh', '-N', '-F', ssh_config_filepath, host)
  end

  def is_alive_child_process(pid)
    return false unless Process.getpgid(pid) == Process.pid

    ret = Process.waitpid2(pid, Process::WNOHANG)
    ret.nil?
  end

  def kill_child_process(pid)
    return unless Process.getpgid(pid) == Process.pid

    Process.kill('KILL', pid)
  rescue Errno::SystemCallError => e
    @logger.error("Failed to kill pid=#{pid}: #{e}")
  end

  def check_pid_and_tcp_port_is_open(ip, port, pid)
    @logger.debug("check_pid_and_tcp_port_is_open ip=#{ip}, port=#{port}")
    begin
      Timeout.timeout(1) do
        if pid && Process.waitpid2(pid, Process::WNOHANG)
          # process is dead
          return false
        end

        s = TCPSocket.new(ip, port)
        s.close
        return true
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
        return false
      end
    rescue Timeout::Error
    end
    false
  end
end

class PlatformStub
  def initialize(logger)
    @logger = logger

    @map_ssh_host_to_tcp_hosts = {}
    @map_tcp_host_to_ssh_host = {}

    @started_ssh_host_to_pid = {}
    @started_pid_to_ssh_host = {}
    @pid_counter = 10
  end

  def terminate
    # do nothing
  end

  def add_ssh_host_to_tcp_host_for_test(ssh_host, tcp_ip, tcp_port)
    tcp_host = [tcp_ip, tcp_port]
    abort "duplicate tcp_host: #{tcp_host}" if @map_tcp_host_to_ssh_host.key?(tcp_host)
    @map_ssh_host_to_tcp_hosts[ssh_host] ||= []
    @map_ssh_host_to_tcp_hosts[ssh_host] << tcp_host
    @map_tcp_host_to_ssh_host[tcp_host] = ssh_host
  end

  def wait_tcp_port_is_open(ip, port, pid, _trycount = 10)
    check_pid_and_tcp_port_is_open(ip, port, pid)
  end

  def start_child_process_ssh(host, _ssh_config_filepath)
    tcp_hosts = @map_ssh_host_to_tcp_hosts[host]
    return false unless tcp_hosts

    pid = @pid_counter
    @pid_counter += 1
    @started_ssh_host_to_pid[host] = pid
    @started_pid_to_ssh_host[pid] = host

    pid
  end

  def is_alive_child_process(pid)
    @started_pid_to_ssh_host.key?(pid)
  end

  def kill_child_process(pid)
    host = @started_pid_to_ssh_host[pid]
    return unless host

    @started_pid_to_ssh_host.delete(pid)
    @started_ssh_host_to_pid.delete(host)
  end

  def check_pid_and_tcp_port_is_open(ip, port, pid)
    return false unless is_alive_child_process(pid)

    tcp_host = [ip, port]

    ssh_host = @map_tcp_host_to_ssh_host[tcp_host]
    return false unless ssh_host

    return false unless @started_ssh_host_to_pid.key?(ssh_host)

    true
  end
end
