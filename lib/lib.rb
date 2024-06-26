require 'logger'

require 'socket'
require 'timeout'

@logger = Logger.new(STDOUT)

def check_pid_and_tcp_port_is_open(ip, port, pid)
  @logger.debug("check_pid_and_tcp_port_is_open ip=#{ip}, port=#{port}")
  begin
    Timeout::timeout(1) do
      begin
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
    end
  rescue Timeout::Error
  end
  return false
end

def wait_tcp_port_is_open(ip, port, pid, trycount=10)
  @logger.debug("wait_tcp_port_is_open ip=#{ip}, port=#{port}")
  trycount.times do |i|
    if check_pid_and_tcp_port_is_open(ip, port, pid)
      return true
    end
    sleep 1
  end
  return false
end

def start_child_process_ssh(host, ssh_config_filepath)
  @logger.debug("start_child_process_ssh host=#{host}")
  pid = spawn('ssh', '-N', '-F', ssh_config_filepath, host)
  return pid
end

# -------------------------------------

@nodes = []

class Node
  # info{host: 'host', check_tcps: [{host: 'host', port: 22}] }
  def initialize(info)
    @info = info
    @before_nodes = []
    @after_nodes = []
  end
  def then(node)
    @after_nodes.push(node)
    node.before_nodes.push(self)
    node
  end

  def before_nodes
    @before_nodes
  end

  def after_nodes
    @after_nodes
  end

  def info
    @info
  end
  def host
    @info[:host]
  end
end

# TODO
# class Group < Node
#   def initialize(*nodes)
#     @nodes = nodes
#   end
# end

# -------------------------------------

# TODO: Use systemd targets?
def vaidate_nodes
  stack = @nodes.select { |node| node.before_nodes.empty? }
  if stack.empty?
    @logger.error('No start node')
    return false
  end

  sorted_nodes = []
  # detect cycle
  reached = {}
  stack.each do |node|
    reached[node] = 0
  end
  while !stack.empty?
    node = stack.pop
    sorted_nodes.push(node)
    node.after_nodes.each do |after_node|
      reached[after_node] ||= 0
      reached[after_node] += 1
      stack.push(after_node) if after_node.before_nodes.size == reached[after_node]
    end
  end
  
  if sorted_nodes.size != @nodes.size
    @logger.error('Cycle detected')
    return nil
  end

  sorted_nodes
end

# -------------------------------------

def launch_node_blocking(info, ssh_config_filepath)
  host = info[:host]
  pid = start_child_process_ssh(host, ssh_config_filepath)

  if info[:check_tcps].any? {|check_tcp| !wait_tcp_port_is_open(check_tcp[:host], check_tcp[:port], pid) }
    # failed
    Process.kill('KILL', pid)
    return nil
  end
  pid
end

def start_evaluate(ssh_config_dir)
  sorted_nodes = vaidate_nodes
  return false unless sorted_nodes

  ssh_config_filepath = File.join(ssh_config_dir, 'config')

  pids = []
  sorted_nodes.each do |node|
    pid = launch_node_blocking(node.info, ssh_config_filepath)
    unless pid
      @logger.error("Failed to launch node: #{node.host}")
      # kill all
      pids.each do |pid|
        Process.kill('KILL', pid)
      end
      return false
    end 
  end

  true
end

# -------------------------------------

def p_conn(info)
  node = Node.new(info)
  @nodes.push(node)
  node
end

# TODO: need?
# nochdir: true, noclose: true
# Process.daemon(true, true)

ssh_config_dir = ARGV[0]

if ssh_config_dir.nil?
  puts 'Usage: ruby lib.rb ssh_config_dir'
  exit 2
end

config_path = File.join(ssh_config_dir, 'config.rb')
load config_path

unless start_evaluate(ssh_config_dir)
  @logger.error('Failed to start')
  exit 1
end

@logger.info('Started')

# Quit
