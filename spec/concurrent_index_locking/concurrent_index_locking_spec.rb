# frozen_string_literal: true

require "timeout"

RSpec.describe "concurrent index locking" do
  before { create_connection.exec(<<~SQL) }
  drop table if exists flows;
  create table if not exists flows (
    id serial,
    value text not null
  );

  drop table if exists other_flows;
  create table if not exists other_flows (
    id serial,
    value text not null
  );
  SQL

  let!(:conn_one) { create_connection }
  let!(:conn_two) { create_connection }

  let!(:conn_one_pid) { backend_pid(conn_one) }
  let!(:conn_two_pid) { backend_pid(conn_two) }

  after do
    create_connection.exec(<<~SQL)
    select pg_terminate_backend(pid) from pg_stat_activity where pid != pg_backend_pid();
    SQL
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

  describe "when creating index concurrently" do
    subject(:create_index) do
      conn_two.exec("set lock_timeout='1s'")
      conn_two.exec(<<-SQL)
      create unique index concurrently
        index_other_flows_value
      on other_flows using btree (id, value);
      SQL
    end

    context "when other transactions have AccessShare locks" do
      before do
        conn_one.exec("begin;")
        conn_one.exec("select * from flows;") # cause AccessShare lock to be taken
      end

      it "completes, as only takes ShareUpdateExclusive, not AccessExclusive" do
        expect { create_index }.not_to raise_exception
      end
    end

    context "when transaction exists with an xmin preceding index snapshot" do
      subject!(:create_index_thread) do
        Thread.new { create_index rescue PG::AdminShutdown }
      end

      # Create transaction that precedes index creation. Use repeatable read to ensure we
      # set the xmin on the transaction: the default read committed isolation level will
      # reset transaction xmins to 0 in between statements.
      before do
        conn_one.exec("begin;")
        conn_one.exec("set transaction isolation level repeatable read;")
        conn_one.exec("select * from flows;") # cause xmin to be set
      end

      it "takes ShareLock on virtualxid of in-progress transaction" do
        Timeout.timeout(3) do
          loop do
            blocked_share_locks = create_connection.exec(<<~SQL).values
            select * from pg_locks
             where pid=#{conn_two_pid}
               and virtualxid='#{virtualxid(conn_one)}'
               and mode='ShareLock'
               and granted='f';
            SQL

            break if blocked_share_locks.any?
          end
        end
      rescue Timeout::Error
        create_connection.exec("select pg_terminate_backend(#{conn_two_pid});")
        fail("could not find expected ShareLock on the virtualxid of old transaction")
      end
    end
  end
end
