require 'logger'

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

app = App.new(@logger, platform)

unless app.start(ssh_config_dir, node_manager)
  @logger.error('Failed app')
  exit 1
end

begin
  sleep 5 while app.running?
rescue SignalException => e
  @logger.info("Signal: #{e}")
  app.terminate
  sleep 0.5
end

@logger.info('Quit')
