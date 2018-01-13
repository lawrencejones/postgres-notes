#!/usr/bin/env ruby

require 'pg'
require 'active_record'
require 'docker'
require 'pry'
require 'active_support/core_ext/module/delegation'

class Postgres
  def self.create
    postgres = Docker::Container.get("postgres-vacuum") rescue nil
    postgres ||= begin
      Docker::Container.create(
        "name" => "postgres-vacuum",
        "Image" => "postgres:9.6",
        "HostConfig" => { "PublishAllPorts" => true },
      ).tap(&:start!)
    end

    new(postgres)
  end

  def initialize(postgres)
    @postgres = postgres
    @host = URI.parse(Docker.connection.url).host || "127.0.0.1"
    @port = @postgres.json["NetworkSettings"]["Ports"]["5432/tcp"][0]["HostPort"]
    @conn = PG.connect(host: @host, port: @port, dbname: "postgres", user: "postgres")
  end

  delegate :exec, to: :@conn

  def multixact_offset
    @conn.exec(<<-SQL).first.fetch("next_multi_offset").to_i
    select next_multi_offset from pg_control_checkpoint()
    SQL
  end
end

postgres = Postgres.create
postgres.exec(<<-SQL)
create table if not exists payment_statistics (
  id serial,
  creditor_id text not null,
  count integer not null
);
SQL

puts "done"
