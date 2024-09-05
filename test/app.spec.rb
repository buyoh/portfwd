require 'minitest/autorun'
require 'logger'

require_relative '../lib/node'
require_relative '../lib/platform'
require_relative '../lib/app'

Platform = PlatformStub

describe 'App' do
  before do
    @logger ||= Logger.new(nil)
    @platform = Platform.new(@logger)
    @platform.add_ssh_host_to_tcp_host_for_test('host0', 'tcp0', 8000)
    @platform.add_ssh_host_to_tcp_host_for_test('host0', 'tcp1', 8010)
    @platform.add_ssh_host_to_tcp_host_for_test('host4', 'tcp4', 8000)

    node0 = Node.new({ host: 'host0', check_tcps: [{ host: 'tcp0', port: 8000 }, { host: 'tcp1', port: 8010 }] })
    node1 = Node.new({ host: 'host4', check_tcps: [{ host: 'tcp4', port: 8000 }] })
    node0.then(node1)

    @node_manager = NodeManager.new(@logger, [node0, node1])
    @app = App.new(@logger, @platform)
    @app.update_config(
      Struct.new(
        :check_connection_interval_sec,
        :terminate_sleep_sec
      ).new(0.01, 0.01)
    )
  end

  after do
    @app.terminate
  end

  it 'should fail `start` due to cycle' do
    ssh_config_dir = 'fixtures/ssh_config'

    node0 = Node.new({ host: 'host0', check_tcps: [{ host: 'tcp0', port: 8000 }, { host: 'tcp1', port: 8010 }] })
    node1 = Node.new({ host: 'host4', check_tcps: [{ host: 'tcp4', port: 8000 }] })
    node0.then(node1)
    node1.then(node0)
    node_manager = NodeManager.new(@logger, [node0, node1])

    assert(!@app.start(ssh_config_dir, node_manager))
    sleep 0.05
    assert(!@app.running?)

    @app.terminate
  end

  it 'should stop due to broken connection' do
    ssh_config_dir = 'fixtures/ssh_config'

    node0 = Node.new({ host: 'host0', check_tcps: [{ host: 'tcp0', port: 8000 }, { host: 'tcp999', port: 8010 }] })
    node1 = Node.new({ host: 'host4', check_tcps: [{ host: 'tcp4', port: 8000 }] })
    node0.then(node1)
    node_manager = NodeManager.new(@logger, [node0, node1])

    # Application starts successfully, but it will stop due to broken connection
    assert(@app.start(ssh_config_dir, node_manager))
    sleep 0.05
    assert(!@app.running?)

    @app.terminate
  end

  it 'should call `kill_child_process`' do
    # TODO
  end

  it 'should call `check_connection` and `is_alive_child_process`' do
    # TODO
  end

  it 'should restart nodes when `check_connection` return false' do
    # TODO
  end
end
