# frozen_string_literal: true

require "pg"
require "rspec"
require "pry"
require "timeout"
require "json"

def create_connection
  PG.connect(
    host: ENV["PGHOST"],
    port: ENV["PGPORT"],
    dbname: ENV["PGDATABASE"] || "notes",
    user: ENV["PGUSER"],
  )
end

def backend_pid(conn)
  conn.exec(<<~SQL).values[0][0]
  select pg_backend_pid();
  SQL
end

def virtualxid(conn)
  conn.exec(<<~SQL).values[0][0]
  select virtualxid from pg_locks where pid = pg_backend_pid() and locktype = 'virtualxid';
  SQL
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.after(:each) do
    create_connection.exec(<<~SQL)
    select pg_terminate_backend(pid) from pg_stat_activity where pid != pg_backend_pid();
    SQL
  end
end
