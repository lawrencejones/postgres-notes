# frozen_string_literal: true

RSpec.describe "alter table locks references" do
  before { create_connection.exec(<<~SQL) }
  drop table if exists flows;
  create table if not exists flows (
    id serial
  );

  drop table if exists other_flows;
  create table if not exists other_flows (
    id serial
  );
  SQL

  let!(:conn_one) { create_connection }
  let!(:conn_two) { create_connection }

  let!(:conn_one_pid) { backend_pid(conn_one) }
  let!(:conn_two_pid) { backend_pid(conn_two) }

  context "when transactions have AccessShare locks on flows" do
    before do
      conn_one.exec("begin;")
      conn_one.exec("select * from flows;") # cause AccessShare lock to be taken
    end

    context "adding non-reference column to other_flows" do
      subject(:add_column) do
        conn_two.exec("set lock_timeout='1s'")
        conn_two.exec(<<-SQL)
        alter table other_flows add column value text;
        SQL
      end

      it "succeeds, as we only take an AccessExclusive lock on our own table" do
        expect { add_column }.not_to raise_exception
      end
    end

    context "adding a reference column to other_flows" do
      subject(:add_column) do
        conn_two.exec("set lock_timeout='10s'")
        conn_two.exec(<<-SQL)
        alter table other_flows add column flow_id serial references flows(id);
        SQL
      end

      let!(:add_column_thread) do
        Thread.new { add_column rescue PG::AdminShutdown }
      end

      it "takes AccessExclusive lock on references flows relation" do
        Timeout.timeout(3) do
          check_conn = create_connection

          loop do
            blocked_access_exclusive_locks = check_conn.exec(<<~SQL).values
            select * from pg_locks
             where pid=#{conn_two_pid}
               and mode='AccessExclusiveLock'
               and granted='f';
            SQL

            break if blocked_access_exclusive_locks.any?
          end
        end
      rescue Timeout::Error
        create_connection.exec("select pg_terminate_backend(#{conn_two_pid});")
        fail("could not find expected AccessExclusive lock on flows")
      end
    end
  end
end
