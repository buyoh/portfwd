#!/usr/bin/env ruby

require 'fileutils'

# colorize the output
require 'minitest/pride'

Dir.chdir(File.dirname(__FILE__))

# start all test
Dir.glob('test/*.spec.rb').each do |file|
  load file
end
