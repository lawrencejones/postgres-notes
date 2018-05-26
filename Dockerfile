FROM ubuntu:16.04
RUN set -x \
      && apt-get update -y \
      && apt-get install -y \
          build-essential \
          curl \
          vim \
          gcc \
          gdb \
          valgrind \
          autoconf \
          libreadline-dev \
          zlib1g-dev \
          sudo \
			&& useradd -r -s /bin/bash -u 500 -U -m \
					-d /var/lib/postgresql --comment "Postgres system user" postgres

ENV PATH="/usr/local/pgsql/bin:${PATH}"
ENV POSTGRES_RELEASE=REL9_4_18
RUN set -x \
      && curl -L "https://github.com/postgres/postgres/archive/${POSTGRES_RELEASE}.tar.gz" | tar xfvz - \
      && mv "postgres-${POSTGRES_RELEASE}" /postgres

WORKDIR /postgres

RUN apt-get install -y flex bison
RUN set -x \
      && ./configure --enable-cassert --enable-debug CFLAGS="-ggdb -Og -g3 -fno-omit-frame-pointer" \
      && make install \
      && sudo -u postgres /usr/local/pgsql/bin/initdb /var/lib/postgresql/main

RUN echo "host all all all trust" >/var/lib/postgresql/main/pg_hba.conf
RUN sed -r "s/.+listen_addresses.+/listen_addresses = '\*'/" -i /var/lib/postgresql/main/postgresql.conf

EXPOSE 5432
CMD ["sudo", "-u", "postgres", "/usr/local/pgsql/bin/postgres", "-D", "/var/lib/postgresql/main"]
