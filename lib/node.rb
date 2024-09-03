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

    ok, err = check_unique_host
    if err
      @logger.error(err)
      return nil
    end

    sorted_nodes, err = calc_topological_sort
    if err
      @logger.error(err)
      return nil
    end

    @sorted_nodes = sorted_nodes
  end

  def solve_invalidated_nodes(invalidated_hosts)
    invalidated_nodes = invalidated_hosts.map { |h| @nodes.find { |n| n.host == h } }
    calc_invalidated_nodes(invalidated_nodes)
  end

  private

  def check_unique_host
    @nodes.map { |n| n.host }.tally.each do |host, count|
      return [false, "Duplicate host: #{host}"] if count > 1
    end
    [true, nil]
  end

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

  def calc_invalidated_nodes(invalidated_nodes)
    all_invalidated_nodes = invalidated_nodes.clone

    que = invalidated_nodes
    until que.empty?
      node = que.pop
      node.after_nodes.each do |after_node|
        all_invalidated_nodes.push(after_node)
        que.push(after_node)
      end
    end

    all_invalidated_nodes
  end
end
