require 'logger'
require 'socket'
require 'timeout'

require_relative 'app'
require_relative 'platform'
require_relative 'node'

@logger = Logger.new(STDOUT)

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

app = App.new(@logger, platform)

unless app.start(ssh_config_dir, sorted_nodes)
  @logger.error('Failed app')
  exit 1
end

@logger.info('Done')

# Quit
