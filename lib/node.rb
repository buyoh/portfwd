class Node
  # info{host: 'host', check_tcps: [{host: 'host', port: 22}] }
  def initialize(info)
    @info = info
    @before_nodes = []
    @after_nodes = []
  end

  attr_reader :before_nodes, :after_nodes, :info

  def host
    @info[:host]
  end

  # The given node will be solved after this node.
  def then(node)
    @after_nodes.push(node)
    node.before_nodes.push(self)
    node
  end
end

# TODO
# class Group < Node
#   def initialize(*nodes)
#     @nodes = nodes
#   end
# end

class NodeManager
  def initialize(logger, nodes = [])
    @logger = logger
    @nodes = nodes
  end

  attr_accessor :nodes

  # Validate the nodes and return the sorted nodes
  # - Check if there is a start node
  # - Check if no cycle
  # - Return the sorted nodes (topological sort) if no error
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
    until stack.empty?
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
end
