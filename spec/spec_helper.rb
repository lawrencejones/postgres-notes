# frozen_string_literal: true

require "pg"
require "rspec"
require "pry"

def create_connection
  PG.connect(host: ENV["PGHOST"], port: ENV["PGPORT"], dbname: "postgres", user: "postgres")
end

RSpec.configure do |config|
  config.disable_monkey_patching!
end
