require 'minitest/autorun'
require 'logger'

require_relative '../lib/node'
require_relative '../lib/platform'
require_relative '../lib/app'

Platform = PlatformStub

def spy_on(object, method_symbol, &observer_block)
  original_method = object.method(method_symbol)
  object.define_singleton_method(method_symbol) do |*args|
    observer_block.call(original_method, args)
  end
end

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

    @dic_check_tcps = {
      ['tcp0', 8000] => 'host0',
      ['tcp1', 8010] => 'host0',
      ['tcp4', 8000] => 'host4'
    }

    @ssh_config_dir = 'fixtures/ssh_config'

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
    node0 = Node.new({ host: 'host0', check_tcps: [{ host: 'tcp0', port: 8000 }, { host: 'tcp1', port: 8010 }] })
    node1 = Node.new({ host: 'host4', check_tcps: [{ host: 'tcp4', port: 8000 }] })
    node0.then(node1)
    node1.then(node0)
    node_manager = NodeManager.new(@logger, [node0, node1])

    assert(!@app.start(@ssh_config_dir, node_manager))
    sleep 0.05
    assert(!@app.running?)

    @app.terminate
  end

  it 'should stop due to broken connection' do
    node0 = Node.new({ host: 'host0', check_tcps: [{ host: 'tcp0', port: 8000 }, { host: 'tcp999', port: 8010 }] })
    node1 = Node.new({ host: 'host4', check_tcps: [{ host: 'tcp4', port: 8000 }] })
    node0.then(node1)
    node_manager = NodeManager.new(@logger, [node0, node1])

    # Application starts successfully, but it will stop due to broken connection
    assert(@app.start(@ssh_config_dir, node_manager))
    sleep 0.05
    assert(!@app.running?)

    @app.terminate
  end

  it 'should call `kill_child_process`' do
    pids = []
    knwon_pids = []
    unknown_pids = []
    spy_on(@platform, :start_child_process_ssh) do |original, args|
      pid = original.call(*args)
      pids << pid
      knwon_pids << pid
      pid
    end

    spy_on(@platform, :kill_child_process) do |original, args|
      pid = args[0]
      # kill_child_process can be called multiple times
      unknown_pids << pid unless knwon_pids.include?(pid)
      pids.delete(pid)
      original.call(pid)
    end

    assert(@app.start(@ssh_config_dir, @node_manager))
    sleep 0.05
    assert(@app.running?)
    assert(pids.size == 2)
    assert(pids.size == pids.sort.uniq.size)

    @app.terminate
    sleep 0.05

    assert(pids.empty?)
    assert(unknown_pids.empty?)
  end

  it 'should call `check_connection` and `is_alive_child_process`' do
    host_to_pid = {}
    spy_on(@platform, :start_child_process_ssh) do |original, args|
      host, _ssh_config_filepath = args
      pid = original.call(*args)
      host_to_pid[host] = pid
      pid
    end

    called_is_alive_child_process = Hash.new(0)
    spy_on(@platform, :is_alive_child_process) do |original, args|
      pid = args[0]
      called_is_alive_child_process[pid] += 1
      original.call(*args)
    end

    called_check_connection = Hash.new(0)
    unknown_pids = false
    unknown_ssh_hosts = false
    spy_on(@platform, :check_pid_and_tcp_port_is_open) do |original, args|
      ip, port, _pid = args
      ssh_host = @dic_check_tcps[[ip, port]]
      if ssh_host
        pid = host_to_pid[ssh_host]
        if pid
          called_check_connection[pid] += 1
        else
          unknown_pids = true
        end
      else
        unknown_ssh_hosts = true
      end
      original.call(*args)
    end

    assert(@app.start(@ssh_config_dir, @node_manager))
    sleep 0.05
    assert(@app.running?)
    assert(host_to_pid.size.positive?)

    host_to_pid.each do |_host, pid|
      assert(called_is_alive_child_process[pid] > 0)
      assert(called_check_connection[pid] > 0)
    end

    @app.terminate
    sleep 0.05

    assert(!unknown_pids)
    assert(!unknown_ssh_hosts)
  end

  it 'should restart nodes when `check_connection` return false' do
    pids = []
    spy_on(@platform, :start_child_process_ssh) do |original, args|
      pid = original.call(*args)
      pids << pid
      pid
    end

    kill_count = 0
    spy_on(@platform, :kill_child_process) do |original, args|
      pid = args[0]
      kill_count += 1 if pids.include?(pid)
      pids.delete(pid)
      original.call(pid)
    end

    assert(@app.start(@ssh_config_dir, @node_manager))
    sleep 0.05
    assert(@app.running?)
    assert(pids.size.positive?)
    assert(kill_count == 0)
    before_pids = pids.dup

    @platform.kill_child_process(pids[0])
    sleep 0.05
    assert(@app.running?)
    assert(pids.size.positive?)
    assert(kill_count == before_pids.size)
    after_pids = pids.dup

    @app.terminate
    sleep 0.05
    assert(!@app.running?)

    assert((before_pids.sort & after_pids.sort).empty?)
  end
end
