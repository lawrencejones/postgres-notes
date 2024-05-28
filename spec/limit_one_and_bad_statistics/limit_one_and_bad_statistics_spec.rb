# frozen_string_literal: true

# TODO- This is not even half done yet!

RSpec.describe "table joins" do
  subject(:plan) do
    JSON.parse(conn.exec("explain (format json) #{query};").values[0][0])
  end

  let(:conn) { create_connection }
  let(:no_of_payments) { 1000 }
  let(:no_of_payouts) { 50 }
  let(:no_of_payment_transitions) { 5000 }

  before { create_connection.exec(<<~SQL) }
  drop table if exists payments cascade;
  create table if not exists payments (
    id serial primary key
  );

  insert into payments (id) (
    select generate_series(
      nextval('payments_id_seq'),
      nextval('payments_id_seq') + #{no_of_payments}
    ) limit #{no_of_payments}
  );

  drop table if exists payment_transitions;
  create table if not exists payment_transitions (
    id serial primary key,
    payment_id serial references payments(id),
    payout_id serial
  );

  insert into payment_transitions (id, payment_id, payout_id) (
    select generate_series(
             nextval('payment_transitions_id_seq'),
             nextval('payment_transitions_id_seq') + #{no_of_payment_transitions}
           )
         , 1 + trunc(#{no_of_payments} * random())::int
         , 1 + trunc(#{no_of_payouts} * random())::int
     limit #{no_of_payment_transitions}
  );

  drop index if exists index_payment_transitions_on_payout_id;
  create index index_payment_transitions_on_payout_id
      on payment_transitions
   using btree (payout_id);
  SQL

  let(:query) do
    <<~SQL
    select *
      from payment_transitions
     inner join payments on payment_transitions.payment_id=payments.id
     where payment_transitions.payout_id = 0
     order by payment_transitions.id asc #{limit}
    SQL
  end

  describe "without limit" do
    let(:limit) { "" }

    pending "plans" do
      puts(plan)
    end
  end
end
