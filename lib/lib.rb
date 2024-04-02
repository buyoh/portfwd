require 'logger'

require 'socket'
require 'timeout'

@logger = Logger.new(STDOUT)

def check_pid_and_tcp_port_is_open(ip, port, pid)
  @logger.debug("check_tcp_port_is_open ip=#{ip}, port=#{port}")
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

def wait_tcp_port_is_open(ip, port, trycount=10)
  @logger.debug("wait_tcp_port_is_open ip=#{ip}, port=#{port}")
  trycount.times do |i|
    if check_tcp_port_is_open(ip, port)
      return true
    end
    sleep 1
  end
  return false
end

def start_child_process_ssh(host)
  @logger.debug("start_child_process_ssh host=#{host}")
  config_filepath = '~/.ssh/config'  # TODO:
  pid = spawn('ssh', '-N', '-F', config_filepath, host)
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

def launch_node_blocking(info)
  host = info[:host]
  pid = start_child_process_ssh(host)

  if info[:check_tcps].any? {|check_tcp| !wait_tcp_port_is_open(check_tcp[:host], check_tcp[:port]) }
    # failed
    Process.kill('KILL', pid)
    return nil
  end
  pid
end

def start_evaluate
  sorted_nodes = vaidate_nodes
  return false unless sorted_nodes

  return true
  # TODO:

  pids = []
  sorted_nodes.each do |node|
    pid = start_child_process_ssh(node.host)
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

config_path = ARGV[0]

if config_path.nil?
  puts 'Usage: ruby lib.rb config_path'
  exit 2
end

load config_path

p start_evaluate  # TODO:
