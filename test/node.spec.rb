require 'minitest/autorun'
require 'logger'
require 'stringio'

require_relative '../lib/node'

describe 'Node' do
  before do
    @logger = Logger.new(nil)
  end

  it 'should validate nodes successfully' do
    node0 = Node.new({ host: 'host0' })
    node1 = Node.new({ host: 'host1' })
    node2 = Node.new({ host: 'host2' })
    node3 = Node.new({ host: 'host3' })
    node0.then(node1).then(node2)
    node1.then(node3)
    nodes = [node0, node1, node2, node3].reverse

    node_manager = NodeManager.new(@logger, nodes)
    sorted_nodes = node_manager.validate_nodes
    assert(!sorted_nodes.nil?)

    ranks = %w[host0 host1 host2 host3].map { |host| sorted_nodes.find_index { |node| node.host == host } }

    assert(ranks[0] < ranks[1])
    assert(ranks[0] < ranks[2])
    assert(ranks[0] < ranks[3])
    assert(ranks[1] < ranks[2])
    assert(ranks[1] < ranks[3])
  end

  it 'should validate nodes with cycle' do
    node0 = Node.new({ host: 'host0' })
    node1 = Node.new({ host: 'host1' })
    node2 = Node.new({ host: 'host2' })
    node3 = Node.new({ host: 'host3' })
    node0.then(node1).then(node2)
    node1.then(node3)
    node3.then(node0)
    nodes = [node0, node1, node2, node3].reverse

    node_manager = NodeManager.new(@logger, nodes)
    sorted_nodes = node_manager.validate_nodes
    assert(sorted_nodes.nil?)
  end

  it 'should validate nodes with duplicate host' do
    node0 = Node.new({ host: 'host0' })
    node1 = Node.new({ host: 'host1' })
    node2 = Node.new({ host: 'host0' })
    node3 = Node.new({ host: 'host3' })
    node0.then(node1).then(node2)
    node1.then(node3)
    nodes = [node0, node1, node2, node3].reverse

    node_manager = NodeManager.new(@logger, nodes)
    sorted_nodes = node_manager.validate_nodes
    assert(sorted_nodes.nil?)
  end

  it 'should solve invalidated nodes' do
    node0 = Node.new({ host: 'host0' })
    node1 = Node.new({ host: 'host1' })
    node2 = Node.new({ host: 'host2' })
    node3 = Node.new({ host: 'host3' })
    node0.then(node1).then(node2)
    node1.then(node3)
    nodes = [node0, node1, node2, node3].reverse

    node_manager = NodeManager.new(@logger, nodes)
    sorted_nodes = node_manager.validate_nodes
    assert(!sorted_nodes.nil?)

    invalidated_hosts = ['host1']
    invalidated_nodes = node_manager.solve_invalidated_nodes(invalidated_hosts)
    assert(invalidated_nodes.length == 3)
    assert(invalidated_nodes.map(&:host).include?('host0') == false)
  end

  it 'should report a node connected by `then` but not registered' do
    log = StringIO.new
    node0 = Node.new({ host: 'host0' })
    node1 = Node.new({ host: 'host1' })
    node0.then(node1)

    node_manager = NodeManager.new(Logger.new(log), [node0])
    assert_nil(node_manager.validate_nodes)
    assert_includes(log.string, 'Node is not registered: host1 (connected with host0)')
    refute_includes(log.string, 'Cycle detected')
  end

  it 'should report a registered node connected from a node not registered' do
    log = StringIO.new
    node0 = Node.new({ host: 'host0' })
    node1 = Node.new({ host: 'host1' })
    node0.then(node1)

    node_manager = NodeManager.new(Logger.new(log), [node1])
    assert_nil(node_manager.validate_nodes)
    assert_includes(log.string, 'Node is not registered: host0 (connected with host1)')
  end
end
