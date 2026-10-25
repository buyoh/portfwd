require 'socket'
require 'timeout'

class PlatformImpl
  def initialize(logger, ssh_command: ['ssh'], kill_timeout_sec: 5)
    @logger = logger
    @ssh_command = ssh_command
    @kill_timeout_sec = kill_timeout_sec
    # pids spawned by this instance and not yet reaped
    @children = {}
    @children_mutex = Mutex.new
  end

  def terminate
    pids = @children_mutex.synchronize { @children.keys }
    pids.each { |pid| kill_child_process(pid) }
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
    pid = spawn(*@ssh_command, '-N', '-F', ssh_config_filepath, host, pgroup: true)
    @children_mutex.synchronize { @children[pid] = true }
    pid
  rescue SystemCallError => e
    @logger.error("Failed to start ssh host=#{host}: #{e}")
    nil
  end

  def is_alive_child_process(pid)
    return false unless child?(pid)

    return true if Process.waitpid2(pid, Process::WNOHANG).nil?

    forget_child(pid)
    false
  rescue Errno::ECHILD
    forget_child(pid)
    false
  rescue SystemCallError => e
    @logger.error("Failed to check pid=#{pid}: #{e}")
    false
  end

  def kill_child_process(pid)
    return unless child?(pid)

    signal_process_group('TERM', pid)
    unless wait_child_exit(pid, @kill_timeout_sec)
      @logger.info("pid=#{pid} did not exit by TERM. Send KILL")
      signal_process_group('KILL', pid)
      Process.waitpid(pid)
    end
    forget_child(pid)
  rescue Errno::ECHILD
    # already reaped
    forget_child(pid)
  rescue SystemCallError => e
    # keep pid as a child so that `terminate` can retry
    @logger.error("Failed to kill pid=#{pid}: #{e}")
  end

  def check_pid_and_tcp_port_is_open(ip, port, pid)
    @logger.debug("check_pid_and_tcp_port_is_open ip=#{ip}, port=#{port}")
    # process is dead. Checked outside of Timeout not to be interrupted between reaping and forgetting the pid
    return false if pid && !is_alive_child_process(pid)

    begin
      Timeout.timeout(1) do
        s = TCPSocket.new(ip, port)
        s.close
        return true
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
        return false
      end
    rescue Timeout::Error
    rescue SystemCallError
    end
    false
  end

  private

  def child?(pid)
    @children_mutex.synchronize { @children.key?(pid) }
  end

  def forget_child(pid)
    @children_mutex.synchronize { @children.delete(pid) }
  end

  # Send a signal to the process group led by pid.
  # Falls back to pid itself when the group does not exist yet (e.g. right after spawn).
  def signal_process_group(signal, pid)
    Process.kill(signal, -pid)
  rescue Errno::ESRCH
    begin
      Process.kill(signal, pid)
    rescue Errno::ESRCH
      # already exited; it will be reaped by the caller
    end
  end

  # Returns true if the child exited and was reaped within timeout_sec.
  def wait_child_exit(pid, timeout_sec)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_sec
    loop do
      return true if Process.waitpid(pid, Process::WNOHANG)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.1
    end
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
