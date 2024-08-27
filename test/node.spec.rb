require 'minitest/autorun'
require 'logger'

require_relative '../lib/node'

describe 'Node' do
  before do
    @logger = Logger.new(STDOUT)
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
    sorted_nodes = node_manager.vaidate_nodes
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
    sorted_nodes = node_manager.vaidate_nodes
    assert(sorted_nodes.nil?)
  end
end
