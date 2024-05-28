RSpec.describe "insert locking on index" do
  let!(:conn_a) { create_connection }
  let!(:conn_b) { create_connection }

  before { create_connection.exec(<<~SQL) }
  drop table if exists example_with_unique;
  create table if not exists example_with_unique (
    id serial primary key,
    value text unique
  );

  drop index if exists idx_example_with_unique_value;
  create unique index idx_example_with_unique_value
      on example_with_unique
   using btree (value);
  SQL

  context "when inserted a value while in a transaction" do
    before do
      conn_a.exec("begin;")
      conn_a.exec("insert into example_with_unique (value) values ('foo');")
    end

    context "when another transaction inserts the same value" do
      subject(:insert) do
        # Set lock timeout as we expect we're going to block.
        conn_b.exec("set lock_timeout='1s'")

        # Now try inserting.
        conn_b.exec("begin;")
        conn_b.exec("insert into example_with_unique (value) values ('foo');")
      end

      it "blocks" do
        expect { insert }.to raise_exception(PG::LockNotAvailable)
      end
    end
  end
end
