require 'logger'

require_relative 'app'
require_relative 'platform'
require_relative 'node'
require_relative 'node_config'

logger = Logger.new(STDOUT)
logger.level = Logger::INFO # TODO: argument

# TODO: need?
# nochdir: true, noclose: true
# Process.daemon(true, true)

ssh_config_dir = ARGV[0]

if ssh_config_dir.nil?
  puts 'Usage: ruby main.rb ssh_config_dir'
  exit 2
end

# config.rb is not evaluated at runtime. config.yml is generated from it at setup time
config_path = File.join(ssh_config_dir, 'config.yml')
begin
  nodes = NodeConfig.parse_file(config_path)
rescue NodeConfig::Error => e
  logger.error(e.message)
  if !File.exist?(config_path) && File.exist?(File.join(ssh_config_dir, 'config.rb'))
    logger.error('config.rb is no longer read at runtime. ' \
                 'Generate config.yml with tools/generate_config.rb (install.sh does it)')
  end
  exit 1
end

platform = PlatformImpl.new(logger)
node_manager = NodeManager.new(logger, nodes)

app = App.new(logger, platform)

begin
  unless app.start(ssh_config_dir, node_manager)
    logger.error('Failed app')
    exit 1
  end

  begin
    sleep 5 while app.running?
  rescue SignalException => e
    logger.info("Signal: #{e}")
  end
ensure
  app.terminate
  platform.terminate
end

if app.failed?
  logger.error('App failed')
  exit 1
end

logger.info('Quit')
