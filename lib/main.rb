require 'logger'
require 'socket'
require 'timeout'

require_relative 'platform'
require_relative 'node'

@logger = Logger.new(STDOUT)

# -------------------------------------

def launch_node_blocking(platform, info, ssh_config_filepath)
  host = info[:host]
  pid = platform.start_child_process_ssh(host, ssh_config_filepath)

  if info[:check_tcps].any? { |check_tcp| !platform.wait_tcp_port_is_open(check_tcp[:host], check_tcp[:port], pid) }
    # failed
    platform.kill_child_process(pid)
    return nil
  end
  pid
end

def start_evaluate(platform, ssh_config_dir, sorted_nodes)
  ssh_config_filepath = File.join(ssh_config_dir, 'config')

  pids = []
  sorted_nodes.each do |node|
    pid = launch_node_blocking(platform, node.info, ssh_config_filepath)
    next if pid

    @logger.error("Failed to launch node: #{node.host}")
    # kill all
    pids.each do |pid|
      platform.kill_child_process(pid)
    end
    return false
  end

  true
end

# -------------------------------------

@nodes = []

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
  puts 'Usage: ruby main.rb ssh_config_dir'
  exit 2
end

config_path = File.join(ssh_config_dir, 'config.rb')
load config_path

platform = PlatformImpl.new(@logger)
node_manager = NodeManager.new(@logger, @nodes)

sorted_nodes = node_manager.vaidate_nodes
unless sorted_nodes
  @logger.error('Failed to validate nodes')
  exit 1
end

unless start_evaluate(platform, ssh_config_dir, sorted_nodes)
  @logger.error('Failed to start')
  exit 1
end

@logger.info('Started')

# Quit
