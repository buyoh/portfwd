require 'socket'
require 'timeout'

class PlatformImpl
  def initialize(logger)
    @logger = logger
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
