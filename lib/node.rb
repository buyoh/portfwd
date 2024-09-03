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
    @sorted_nodes = nil
  end

  attr_reader :nodes

  # Validate the nodes and return the sorted nodes
  # - Check if there is a start node
  # - Check if no cycle
  # - Return the sorted nodes (topological sort) if no error
  def vaidate_nodes
    return @sorted_nodes if @sorted_nodes

    sorted_nodes, err = calc_topological_sort

    if err
      @logger.error(err)
      return nil
    end

    @sorted_nodes = sorted_nodes
  end

  private

  def calc_topological_sort
    stack = @nodes.select { |node| node.before_nodes.empty? }
    return [nil, 'No start node'] if stack.empty?

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

    return [nil, 'Cycle detected'] if sorted_nodes.size != @nodes.size

    [sorted_nodes, nil]
  end
end
